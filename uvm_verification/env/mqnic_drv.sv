// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_drv - the mqnic host driver, as a UVM component (objective G5)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §12.2 (driver model), §1 G5
// Introduced : G5 end-to-end datapath
//
// A TRANSCRIPTION OF UPSTREAM'S OWN DRIVER MODEL, fpga/common/tb/mqnic.py
// (Driver / Interface / Eq / Cq / Txq / Rxq / Port / SchedulerBlock), which is
// what Corundum's cocotb end-to-end test runs against this very DUT. Every
// register sequence below follows that file line for line, with its line
// numbers, so a divergence is a bug in this transcription and not a second
// opinion about how the hardware should be driven.
//
// TWO SERVICE MODES. mqnic.py services event queues from its MSI-X handler
// (Driver.interrupt_handler: process_eq, then arm). With use_irq set this
// driver does the same: it programs the MSI-X table, and each message the hard
// IP delivers (us_msix_hip) runs the handler for the event queues on that
// vector. With use_irq clear - MSI-X disabled, so pcie_msix parks interrupts
// in its pending-bit array (pcie_msix.v:363-370) - the service loop POLLS the
// event queues in host memory instead. Everything downstream of the interrupt
// is mqnic.py's in both modes.
//
// Register windows. Offsets read from an interface-level block are relative
// to that interface's base, exactly as mqnic.py's Window objects make them.
// -----------------------------------------------------------------------------

`ifndef MQNIC_DRV_SV
`define MQNIC_DRV_SV

// One queue of any kind: EQ, CQ, TXQ or RXQ.
class mqnic_drv_q;
    string       kind;
    int unsigned index;
    bit [63:0]   hw;            // absolute BAR address of its register window
    bit [63:0]   base;          // ring base in host memory
    int unsigned log_size, size, mask, stride;
    int unsigned log_desc_block, desc_block, full_size;
    int unsigned prod, cons;    // free-running; the DUT sees the low 16 bits
    mqnic_drv_q  cq;            // ring -> its completion queue
    mqnic_drv_q  ring;          // cq   -> the ring it completes
    mqnic_drv_q  eq;            // cq   -> its event queue
    bit          is_tx;
    bit [63:0]   buf_addr [];   // ring slot -> packet buffer
    bit          in_use   [];
    int unsigned n_done;
endclass


`uvm_analysis_imp_decl(_drv_msix)

class mqnic_drv extends uvm_component;

    `uvm_component_utils(mqnic_drv)

    // MSI-X table and PBA in BAR 0: pcie_msix is slot 1 of mqnic_core's CSR
    // crossbar, a 64 KB window (mqnic_core.v:1097-1106), with address bit 15
    // selecting table or PBA (pcie_msix.v:486). The same offsets upstream's
    // cocotb test gives the hard IP (pf0_msix_table_offset/pba_offset).
    localparam bit [63:0] MSIX_TABLE = 64'h0001_0000;
    localparam bit [63:0] MSIX_PBA   = 64'h0001_8000;

    // ---- register block IDs and offsets (mqnic.py:22-345) ------------------
    localparam bit [31:0] RB_FW_ID        = 32'hFFFFFFFF;
    localparam bit [31:0] RB_IF           = 32'h0000C000;
    localparam bit [31:0] RB_IF_CTRL      = 32'h0000C001;
    localparam bit [31:0] RB_PORT         = 32'h0000C002;
    localparam bit [31:0] RB_PORT_CTRL    = 32'h0000C003;
    localparam bit [31:0] RB_SCHED_BLOCK  = 32'h0000C004;
    localparam bit [31:0] RB_EQM          = 32'h0000C010;
    localparam bit [31:0] RB_CQM          = 32'h0000C020;
    localparam bit [31:0] RB_TX_QM        = 32'h0000C030;
    localparam bit [31:0] RB_RX_QM        = 32'h0000C031;
    localparam bit [31:0] RB_SCHED_RR     = 32'h0000C040;
    localparam bit [31:0] RB_RX_QUEUE_MAP = 32'h0000C090;

    localparam bit [31:0] IF_FEATURE_RSS     = 32'h1;
    localparam bit [31:0] IF_FEATURE_TX_CSUM = 32'h100;
    localparam bit [31:0] IF_FEATURE_RX_CSUM = 32'h200;
    localparam bit [31:0] IF_FEATURE_RX_HASH = 32'h400;

    localparam bit [31:0] Q_CMD_SET_SIZE      = 32'h80020000;
    localparam bit [31:0] Q_CMD_SET_CQN       = 32'hC0000000;   // also EQN / IRQN
    localparam bit [31:0] Q_CMD_SET_PROD_PTR  = 32'h80800000;
    localparam bit [31:0] Q_CMD_SET_CONS_PTR  = 32'h80900000;
    localparam bit [31:0] Q_CMD_SET_ENABLE    = 32'h40000100;
    localparam bit [31:0] Q_CMD_SET_ARM       = 32'h40000200;

    localparam int DESC_SIZE  = 16;
    localparam int CPL_SIZE   = 32;
    localparam int EVENT_SIZE = 32;

    typedef struct {
        bit [31:0] typ;
        bit [31:0] ver;
        bit [63:0] off;          // relative to the window it was enumerated in
    } rb_t;

    // ---- connections ---------------------------------------------------------
    us_host host;
    sb_e2e  sb;                  // optional: told about queue-map writes
    sb_msix msb;                 // optional: told about MSI-X table writes

    uvm_analysis_imp_drv_msix #(msix_msg, mqnic_drv) msix_imp;

    uvm_analysis_port #(mqnic_e2e_pkt) tx_ap;   // every frame handed to the NIC
    uvm_analysis_port #(mqnic_e2e_pkt) rx_ap;   // every frame read back out

    // ---- configuration -------------------------------------------------------
    int unsigned ring_log_size  = 8;     // mqnic.py uses 1024; 256 keeps sims short
    int unsigned desc_block     = 4;     // mqnic.py:1427/1436
    int unsigned eq_log_size    = 8;
    int unsigned pkt_buf_size   = 16384; // mqnic.py:1658
    int unsigned tx_buf_offset  = 10;    // mqnic.py:1508 puts data at +10
    bit          random_tx_offset = 1'b0;
    int unsigned poll_cycles    = 16;
    bit          use_irq        = 1'b0;  // service from MSI-X, not by polling
    int unsigned n_eq           = 1;     // event queues; EQ k raises vector k

    // ---- discovered ----------------------------------------------------------
    rb_t         blocks [$];
    rb_t         if_blocks [$];
    bit [63:0]   if_base;
    bit [31:0]   if_count, if_stride, if_csr_offset;
    bit [31:0]   fw_id, fw_ver, board_id;
    bit [31:0]   if_features, port_count, sched_count, max_tx_mtu, max_rx_mtu;
    bit [63:0]   eq_win, cq_win, txq_win, rxq_win;
    bit [31:0]   eq_count, cq_count, txq_count, rxq_count;
    bit [31:0]   eq_stride, cq_stride, txq_stride, rxq_stride;
    bit [63:0]   rxqm_rb, port_ctrl_rb, sched_rr_rb, sched_rr_regs, indir_tbl;

    mqnic_drv_q  eqs [$];
    mqnic_drv_q  cqs [$];
    mqnic_drv_q  txqs [$];
    mqnic_drv_q  rxqs [$];
    protected mqnic_drv_q m_cq_by_index [int unsigned];
    protected int unsigned m_next_cqn;

    // ---- runtime -------------------------------------------------------------
    bit          port_up;
    mqnic_e2e_pkt rx_queue [$];
    event        rx_event;
    event        tx_clean_event;
    int unsigned n_tx_sent, n_tx_completed, n_rx_received, n_events, n_cpl_errors;
    int unsigned n_irqs;
    protected int unsigned m_irq_q [$];
    protected event        m_irq_ev;
    protected semaphore m_service_lock;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        tx_ap    = new("tx_ap", this);
        rx_ap    = new("rx_ap", this);
        msix_imp = new("msix_imp", this);
        m_service_lock = new(1);
    endfunction

    // =========================================================================
    // Register and memory access
    // =========================================================================
    protected task rd(bit [63:0] addr, output bit [31:0] d);
        host.read32(addr, d);
    endtask

    protected task wr(bit [63:0] addr, bit [31:0] d);
        host.write32(addr, d);
    endtask

    // A read anywhere flushes every posted write before it (mqnic.py's
    // "wait for all writes to complete").
    task flush_writes();
        bit [31:0] d;
        rd(64'h0, d);
    endtask

    protected function bit [31:0] mem_u32(bit [63:0] a);
        return {host.mem.read_byte(a + 3), host.mem.read_byte(a + 2),
                host.mem.read_byte(a + 1), host.mem.read_byte(a)};
    endfunction

    protected function bit [15:0] mem_u16(bit [63:0] a);
        return {host.mem.read_byte(a + 1), host.mem.read_byte(a)};
    endfunction

    protected function void put_le(ref byte unsigned b[], input int off,
                                   input bit [63:0] v, input int n);
        for (int i = 0; i < n; i++) b[off + i] = v[i*8 +: 8];
    endfunction

    // =========================================================================
    // Register-block discovery (mqnic.py:391-405)
    // =========================================================================
    protected task enumerate(bit [63:0] win, bit [63:0] start, ref rb_t list[$]);
        bit [63:0] off = start;
        bit [31:0] t, v, nxt;
        rb_t       rb;
        list.delete();
        for (int n = 0; n < 64; n++) begin
            rd(win + off + 0, t);
            rd(win + off + 4, v);
            rd(win + off + 8, nxt);
            rb.typ = t; rb.ver = v; rb.off = off;
            list.push_back(rb);
            `uvm_info(get_type_name(),
                $sformatf("block type 0x%08h version 0x%08h at 0x%0h", t, v, win + off), UVM_MEDIUM)
            if (nxt == 0) return;
            if (nxt[1:0] != 0)
                `uvm_error(get_type_name(), $sformatf("register block at 0x%0h not aligned", nxt))
            foreach (list[i])
                if (list[i].off == 64'(nxt)) begin
                    `uvm_error(get_type_name(), "register blocks form a loop")
                    return;
                end
            off = 64'(nxt);
        end
        `uvm_error(get_type_name(), "register block list did not terminate in 64 blocks")
    endtask

    protected function bit find(const ref rb_t list[$], input bit [31:0] typ,
                                input int index, output rb_t rb);
        foreach (list[i])
            if (list[i].typ == typ) begin
                if (index == 0) begin rb = list[i]; return 1'b1; end
                index--;
            end
        return 1'b0;
    endfunction

    protected function void need(bit found, string what);
        if (!found) `uvm_fatal(get_type_name(), $sformatf("no %s register block", what))
    endfunction

    // =========================================================================
    // Driver init (mqnic.py:1701-1759) and interface init (:1275-1422)
    // =========================================================================
    virtual task init();
        rb_t       rb, prb, srb;
        rb_t       port_blocks [$];
        rb_t       sched_blocks [$];
        bit [31:0] d, mtu;

        enumerate(64'h0, 64'h0, blocks);

        need(find(blocks, RB_FW_ID, 0, rb), "FW ID");
        rd(rb.off + 'h0C, d);
        rd(rb.off + 'h10, fw_id);
        rd(rb.off + 'h14, fw_ver);
        rd(rb.off + 'h18, board_id);
        `uvm_info(get_type_name(),
            $sformatf("FW ID 0x%08h version 0x%08h board 0x%08h", fw_id, fw_ver, board_id), UVM_LOW)

        need(find(blocks, RB_IF, 0, rb), "interface");
        rd(rb.off + 'h0C, d);  if_base = 64'(d);
        rd(rb.off + 'h10, if_count);
        rd(rb.off + 'h14, if_stride);
        rd(rb.off + 'h18, if_csr_offset);
        `uvm_info(get_type_name(),
            $sformatf("interfaces: %0d at 0x%0h stride 0x%0h, CSR offset 0x%0h",
                      if_count, if_base, if_stride, if_csr_offset), UVM_LOW)
        if (if_count == 0) `uvm_fatal(get_type_name(), "the device reports no interfaces")

        // Interface 0. All offsets below are relative to if_base.
        enumerate(if_base, 64'(if_csr_offset), if_blocks);

        need(find(if_blocks, RB_IF_CTRL, 0, rb), "IF control");
        rd(if_base + rb.off + 'h0C, if_features);
        rd(if_base + rb.off + 'h10, port_count);
        rd(if_base + rb.off + 'h14, sched_count);
        rd(if_base + rb.off + 'h20, max_tx_mtu);
        rd(if_base + rb.off + 'h24, max_rx_mtu);
        `uvm_info(get_type_name(),
            $sformatf("IF features 0x%08h ports %0d schedulers %0d max MTU tx %0d rx %0d",
                      if_features, port_count, sched_count, max_tx_mtu, max_rx_mtu), UVM_LOW)
        mtu = max_tx_mtu;
        if (max_rx_mtu < mtu) mtu = max_rx_mtu;
        if (mtu > 9214) mtu = 9214;
        wr(if_base + rb.off + 'h28, mtu);
        wr(if_base + rb.off + 'h2C, mtu);
        if (sb != null) begin
            sb.rx_csum_feature = (if_features & IF_FEATURE_RX_CSUM) != 0;
            sb.rx_hash_feature = (if_features & IF_FEATURE_RX_HASH) != 0;
        end

        get_qm(RB_EQM,   "EQ manager",  eq_win,  eq_count,  eq_stride);
        get_qm(RB_CQM,   "CQ manager",  cq_win,  cq_count,  cq_stride);
        get_qm(RB_TX_QM, "TXQ manager", txq_win, txq_count, txq_stride);
        get_qm(RB_RX_QM, "RXQ manager", rxq_win, rxq_count, rxq_stride);

        need(find(if_blocks, RB_RX_QUEUE_MAP, 0, rb), "RX queue map");
        rxqm_rb = if_base + rb.off;
        rd(rxqm_rb + 'h10, d);                 // port 0 indirection table
        indir_tbl = if_base + 64'(d);
        set_rss_mask(0);
        wr(rxqm_rb + 'h18, 0);                 // app mask
        set_indir(0, 0);

        // Ensure every queue we may use starts disabled (mqnic.py:1384-1394).
        for (int k = 0; k < 32 && k < int'(eq_count); k++)
            wr(eq_win + k * eq_stride + 'h08, Q_CMD_SET_ENABLE | 0);
        for (int k = 0; k < 64 && k < int'(cq_count); k++)
            wr(cq_win + k * cq_stride + 'h08, Q_CMD_SET_ENABLE | 0);
        for (int k = 0; k < 32 && k < int'(txq_count); k++)
            wr(txq_win + k * txq_stride + 'h08, Q_CMD_SET_ENABLE | 0);
        for (int k = 0; k < 8 && k < int'(rxq_count); k++)
            wr(rxq_win + k * rxq_stride + 'h08, Q_CMD_SET_ENABLE | 0);

        // Port 0 (mqnic.py:1175-1195).
        need(find(if_blocks, RB_PORT, 0, prb), "port");
        rd(if_base + prb.off + 'h0C, d);
        enumerate(if_base, 64'(d), port_blocks);
        need(find(port_blocks, RB_PORT_CTRL, 0, rb), "port control");
        port_ctrl_rb = if_base + rb.off;
        wr(port_ctrl_rb + 'h10, 0);            // TX ctrl
        wr(port_ctrl_rb + 'h14, 0);            // RX ctrl
        wr(port_ctrl_rb + 'h1C, 0);            // LFC
        for (int k = 0; k < 8; k++)
            wr(port_ctrl_rb + 'h20 + 4 * k, 0);    // PFC 0-7

        // Scheduler block 0 (mqnic.py:1133-1157).
        need(find(if_blocks, RB_SCHED_BLOCK, 0, srb), "scheduler block");
        rd(if_base + srb.off + 'h0C, d);
        enumerate(if_base, 64'(d), sched_blocks);
        need(find(sched_blocks, RB_SCHED_RR, 0, rb), "round-robin scheduler");
        sched_rr_rb = if_base + rb.off;
        rd(sched_rr_rb + 'h0C, d);
        sched_rr_regs = if_base + 64'(d);

        // Event queues (mqnic.py:1408-1414 opens one, on the interface's IRQ):
        // n_eq of them, EQ k on MSI-X vector k, each armed.
        if (n_eq > eq_count) `uvm_fatal(get_type_name(), $sformatf("%0d EQs asked, %0d exist", n_eq, eq_count))
        for (int k = 0; k < int'(n_eq); k++) begin
            mqnic_drv_q eq = new();
            eq.kind     = "EQ";
            eq.index    = k;
            eq.hw       = eq_win + k * eq_stride;
            eq.log_size = eq_log_size;
            eq_open(eq, k);
            eqs.push_back(eq);
            arm(eq);
        end
        flush_writes();
    endtask

    protected task get_qm(bit [31:0] typ, string what, output bit [63:0] win,
                          output bit [31:0] count, output bit [31:0] stride);
        rb_t       rb;
        bit [31:0] d;
        need(find(if_blocks, typ, 0, rb), what);
        rd(if_base + rb.off + 'h0C, d);
        win = if_base + 64'(d);
        rd(if_base + rb.off + 'h10, count);
        rd(if_base + rb.off + 'h14, stride);
        `uvm_info(get_type_name(),
            $sformatf("%s: %0d queue(s) at 0x%0h stride 0x%0h", what, count, win, stride), UVM_LOW)
    endtask

    // =========================================================================
    // Queue open (mqnic.py:476-514 EQ, 610-647 CQ, 713-751 TXQ, 893-933 RXQ)
    // =========================================================================
    protected task eq_open(mqnic_drv_q eq, int unsigned irq);
        eq.size   = 1 << eq.log_size;
        eq.mask   = eq.size - 1;
        eq.stride = EVENT_SIZE;
        eq.base   = host.mem.alloc_region(eq.size * eq.stride);
        eq.prod   = 0;
        eq.cons   = 0;
        wr(eq.hw + 'h08, Q_CMD_SET_ENABLE | 0);
        wr(eq.hw + 'h00, eq.base[31:0] & 32'hFFFFF000);
        wr(eq.hw + 'h04, eq.base[63:32]);
        wr(eq.hw + 'h08, Q_CMD_SET_SIZE | eq.log_size);
        wr(eq.hw + 'h08, Q_CMD_SET_CQN | irq);           // SET_IRQN
        wr(eq.hw + 'h08, Q_CMD_SET_PROD_PTR | 0);
        wr(eq.hw + 'h08, Q_CMD_SET_CONS_PTR | 0);
        wr(eq.hw + 'h08, Q_CMD_SET_ENABLE | 1);
    endtask

    protected task cq_open(mqnic_drv_q cq, mqnic_drv_q eq, int unsigned log_size);
        cq.kind     = "CQ";
        cq.index    = m_next_cqn++;
        cq.hw       = cq_win + cq.index * cq_stride;
        cq.log_size = log_size;
        cq.size     = 1 << log_size;
        cq.mask     = cq.size - 1;
        cq.stride   = CPL_SIZE;
        cq.base     = host.mem.alloc_region(cq.size * cq.stride);
        cq.prod     = 0;
        cq.cons     = 0;
        cq.eq       = eq;
        m_cq_by_index[cq.index] = cq;
        wr(cq.hw + 'h08, Q_CMD_SET_ENABLE | 0);
        wr(cq.hw + 'h00, cq.base[31:0] & 32'hFFFFF000);
        wr(cq.hw + 'h04, cq.base[63:32]);
        wr(cq.hw + 'h08, Q_CMD_SET_SIZE | log_size);
        wr(cq.hw + 'h08, Q_CMD_SET_CQN | eq.index);      // SET_EQN
        wr(cq.hw + 'h08, Q_CMD_SET_PROD_PTR | 0);
        wr(cq.hw + 'h08, Q_CMD_SET_CONS_PTR | 0);
        wr(cq.hw + 'h08, Q_CMD_SET_ENABLE | 1);
    endtask

    protected task ring_open(mqnic_drv_q q, mqnic_drv_q cq, bit is_tx, int unsigned index);
        q.kind           = is_tx ? "TXQ" : "RXQ";
        q.is_tx          = is_tx;
        q.index          = index;
        q.hw             = is_tx ? txq_win + index * txq_stride : rxq_win + index * rxq_stride;
        q.log_size       = ring_log_size;
        q.size           = 1 << ring_log_size;
        q.mask           = q.size - 1;
        q.full_size      = q.size >> 1;
        q.log_desc_block = $clog2(desc_block);
        q.desc_block     = 1 << q.log_desc_block;
        q.stride         = DESC_SIZE * q.desc_block;
        q.base           = host.mem.alloc_region(q.size * q.stride);
        q.prod           = 0;
        q.cons           = 0;
        q.cq             = cq;
        cq.ring          = q;
        q.buf_addr       = new[q.size];
        q.in_use         = new[q.size];
        foreach (q.buf_addr[i]) q.buf_addr[i] = host.mem.alloc_region(pkt_buf_size);
        wr(q.hw + 'h08, Q_CMD_SET_ENABLE | 0);
        wr(q.hw + 'h00, q.base[31:0] & 32'hFFFFF000);
        wr(q.hw + 'h04, q.base[63:32]);
        wr(q.hw + 'h08, Q_CMD_SET_SIZE | (q.log_desc_block << 8) | q.log_size);
        wr(q.hw + 'h08, Q_CMD_SET_CQN | cq.index);
        wr(q.hw + 'h08, Q_CMD_SET_PROD_PTR | 0);
        wr(q.hw + 'h08, Q_CMD_SET_CONS_PTR | 0);
    endtask

    protected task arm(mqnic_drv_q q);
        wr(q.hw + 'h08, Q_CMD_SET_ARM | 1);
    endtask

    protected task enable(mqnic_drv_q q, bit en);
        wr(q.hw + 'h08, Q_CMD_SET_ENABLE | 32'(en));
    endtask

    // Interface open (mqnic.py:1424-1449) plus the test's scheduler enable
    // (test_mqnic_core_pcie_us.py:397-400).
    virtual task open(int unsigned n_txq = 1, int unsigned n_rxq = 1);
        if (n_txq > txq_count || n_rxq > rxq_count)
            `uvm_fatal(get_type_name(),
                $sformatf("asked for %0d TXQ / %0d RXQ, device has %0d / %0d",
                          n_txq, n_rxq, txq_count, rxq_count))
        for (int k = 0; k < int'(n_rxq); k++) begin
            mqnic_drv_q cq = new();
            mqnic_drv_q q  = new();
            cq_open(cq, eqs[k % eqs.size()], ring_log_size);
            arm(cq);
            ring_open(q, cq, 1'b0, k);
            refill(q);
            enable(q, 1'b1);
            cqs.push_back(cq);
            rxqs.push_back(q);
        end
        for (int k = 0; k < int'(n_txq); k++) begin
            mqnic_drv_q cq = new();
            mqnic_drv_q q  = new();
            cq_open(cq, eqs[(n_rxq + k) % eqs.size()], ring_log_size);
            arm(cq);
            ring_open(q, cq, 1'b1, k);
            enable(q, 1'b1);
            cqs.push_back(cq);
            txqs.push_back(q);
        end
        flush_writes();

        wr(port_ctrl_rb + 'h10, 32'h1);        // MQNIC_PORT_TX_CTRL_EN
        wr(port_ctrl_rb + 'h14, 32'h1);        // MQNIC_PORT_RX_CTRL_EN

        wr(sched_rr_rb + 'h18, 32'h1);         // MQNIC_RB_SCHED_RR_REG_CTRL
        for (int k = 0; k < int'(n_txq); k++)
            wr(sched_rr_regs + 4 * k, 32'h3);
        flush_writes();
        port_up = 1'b1;
        `uvm_info(get_type_name(),
            $sformatf("interface up: %0d TXQ, %0d RXQ, rings of %0d, descriptor block %0d",
                      n_txq, n_rxq, 1 << ring_log_size, desc_block), UVM_LOW)
    endtask

    // =========================================================================
    // Queue map (mqnic.py:1549-1565)
    // =========================================================================
    virtual task set_rss_mask(bit [31:0] mask);
        wr(rxqm_rb + 'h14, mask);
        if (sb != null) sb.rss_mask = mask;
    endtask

    virtual task set_indir(int unsigned index, int unsigned queue);
        wr(indir_tbl + 4 * index, queue);
        if (sb != null) sb.set_indir(index, queue);
    endtask

    // =========================================================================
    // MSI-X table (PCIe base spec 7.7.2: address lo/hi, data, vector control)
    // =========================================================================
    // Each vector gets a distinct address and data, so a message identifies its
    // vector unambiguously (a host would point them all at its interrupt
    // controller; distinct values lose nothing and make the check exact).
    function bit [63:0] msix_addr(int unsigned v);
        return 64'h0000_0000_FEE0_0000 + 64'(v) * 64'h10;
    endfunction

    function bit [31:0] msix_data(int unsigned v);
        return 32'h4D58_0000 | 32'(v);
    endfunction

    virtual task msix_write_entry(int unsigned v, bit masked);
        bit [63:0] e = MSIX_TABLE + 64'(v) * 16;
        bit [63:0] a = msix_addr(v);
        wr(e + 'h0, a[31:0]);
        wr(e + 'h4, a[63:32]);
        wr(e + 'h8, msix_data(v));
        wr(e + 'hC, 32'(masked));
        if (msb != null) msb.set_entry(v, msix_addr(v), msix_data(v), masked);
    endtask

    // Program vectors 0..n-1, unmasked.
    virtual task msix_setup(int unsigned n_vectors);
        for (int unsigned v = 0; v < n_vectors; v++) msix_write_entry(v, 1'b0);
        flush_writes();
    endtask

    virtual task msix_mask(int unsigned v, bit masked);
        bit [63:0] e = MSIX_TABLE + 64'(v) * 16;
        if (msb != null) msb.set_entry(v, msix_addr(v), msix_data(v), masked);
        wr(e + 'hC, 32'(masked));
    endtask

    virtual task msix_read_pba(output bit [31:0] pba);
        rd(MSIX_PBA, pba);
    endtask

    // A message the hard IP delivered: queue its vector for the handler.
    virtual function void write_drv_msix(msix_msg m);
        if (m.failed) return;                  // never reached the host
        if ((m.data & 32'hFFFF_0000) != 32'h4D58_0000) begin
            `uvm_error(get_type_name(), $sformatf("interrupt with unknown data: %s", m.convert2string()))
            return;
        end
        m_irq_q.push_back(m.data[15:0]);
        ->m_irq_ev;
    endfunction

    // Driver.interrupt_handler (mqnic.py:1771-1778): every EQ on this vector
    // is processed and re-armed, whether or not it held events.
    protected task handle_irq(int unsigned v);
        n_irqs++;
        m_service_lock.get();
        foreach (eqs[i])
            if (eqs[i].index == v) begin
                process_eq(eqs[i]);
                arm(eqs[i]);
            end
        m_service_lock.put();
    endtask

    // Run the interrupt handler for every event queue - what a driver's
    // watchdog does after an interrupt was lost (e.g. the hard IP answered
    // _fail): process anything pending and re-arm, so interrupts flow again.
    virtual task rearm_all();
        foreach (eqs[i]) handle_irq(eqs[i].index);
    endtask

    // =========================================================================
    // RX buffers (mqnic.py:994-1019)
    // =========================================================================
    protected task refill(mqnic_drv_q q);
        int unsigned missing = q.size - (q.prod - q.cons);
        if (missing < 8) return;
        repeat (missing) begin
            int unsigned  idx = q.prod & q.mask;
            byte unsigned d [];
            int unsigned  off = 0, seg;
            d = new[q.stride];
            for (int k = 0; k < int'(q.desc_block); k++) begin
                if (k < int'(q.desc_block) - 1)
                    seg = (pkt_buf_size - off > 4096) ? 4096 : pkt_buf_size - off;
                else
                    seg = pkt_buf_size - off;
                put_le(d, k * DESC_SIZE + 0, 0, 4);
                put_le(d, k * DESC_SIZE + 4, seg, 4);
                put_le(d, k * DESC_SIZE + 8, (seg != 0) ? q.buf_addr[idx] + off : 64'd0, 8);
                off += seg;
            end
            host.mem.write_bytes(q.base + idx * q.stride, d);
            q.in_use[idx] = 1'b1;
            q.prod++;
        end
        wr(q.hw + 'h08, Q_CMD_SET_PROD_PTR | (q.prod & 32'hFFFF));
    endtask

    // =========================================================================
    // Transmit (mqnic.py:1482-1539)
    // =========================================================================
    virtual task xmit(byte unsigned data[], int unsigned txq = 0,
                      bit csum_en = 1'b0, int unsigned csum_start = 0,
                      int unsigned csum_offset = 0);
        mqnic_drv_q   q;
        int unsigned  idx, off, seg, len, boff;
        bit [63:0]    ptr;
        bit [15:0]    csum_cmd;
        byte unsigned d [];
        mqnic_e2e_pkt p;

        if (!port_up) `uvm_fatal(get_type_name(), "xmit before open()")
        if (txq >= txqs.size()) `uvm_fatal(get_type_name(), $sformatf("no TXQ %0d", txq))
        q   = txqs[txq];
        len = data.size();
        if (len >= max_tx_mtu)
            `uvm_fatal(get_type_name(), $sformatf("frame of %0d B exceeds the %0d B MTU", len, max_tx_mtu))

        // Wait for ring space - the completion path frees it.
        while (q.prod - q.cons >= q.full_size) @tx_clean_event;

        idx = q.prod & q.mask;
        if (q.in_use[idx])
            `uvm_fatal(get_type_name(), $sformatf("TXQ %0d slot %0d still in use", txq, idx))
        q.in_use[idx] = 1'b1;

        boff = random_tx_offset ? $urandom_range(0, 63) : tx_buf_offset;
        ptr  = q.buf_addr[idx] + boff;
        host.mem.write_bytes(ptr, data);

        csum_cmd = csum_en ? (16'h8000 | 16'(csum_offset << 8) | 16'(csum_start)) : 16'h0;

        d   = new[q.stride];
        off = 0;
        seg = (q.desc_block > 1) ? ((len - off > 42) ? 42 : len - off) : len - off;
        put_le(d, 0, 0, 2);
        put_le(d, 2, csum_cmd, 2);
        put_le(d, 4, seg, 4);
        put_le(d, 8, (seg != 0) ? ptr + off : 64'd0, 8);
        off += seg;
        for (int k = 1; k < int'(q.desc_block); k++) begin
            if (k < int'(q.desc_block) - 1)
                seg = (len - off > 4096) ? 4096 : len - off;
            else
                seg = len - off;
            put_le(d, k * DESC_SIZE + 0, 0, 4);
            put_le(d, k * DESC_SIZE + 4, seg, 4);
            put_le(d, k * DESC_SIZE + 8, (seg != 0) ? ptr + off : 64'd0, 8);
            off += seg;
        end
        host.mem.write_bytes(q.base + idx * q.stride, d);

        p = mqnic_e2e_pkt::type_id::create("tx");
        p.data        = data;
        p.queue       = int'(txq);
        p.csum_enable = csum_en;
        p.csum_start  = csum_start;
        p.csum_offset = csum_offset;
        tx_ap.write(p);

        q.prod++;
        n_tx_sent++;
        wr(q.hw + 'h08, Q_CMD_SET_PROD_PTR | (q.prod & 32'hFFFF));
    endtask

    // =========================================================================
    // Receive
    // =========================================================================
    virtual task recv(output mqnic_e2e_pkt p, input int unsigned timeout_cycles = 200000);
        int unsigned waited = 0;
        while (rx_queue.size() == 0 && waited < timeout_cycles) begin
            @(posedge host.rst_vif.clk);
            waited++;
        end
        p = (rx_queue.size() > 0) ? rx_queue.pop_front() : null;
    endtask

    // =========================================================================
    // Event and completion service (mqnic.py:552-581, 813-861, 1021-1085)
    // =========================================================================
    virtual task run_phase(uvm_phase phase);
        fork
            forever begin
                repeat (poll_cycles) @(posedge host.rst_vif.clk);
                if (port_up && !use_irq) service();
            end
            forever begin
                while (m_irq_q.size() == 0) @m_irq_ev;
                handle_irq(m_irq_q.pop_front());
            end
        join
    endtask

    virtual task service();
        m_service_lock.get();
        foreach (eqs[i]) process_eq(eqs[i]);
        m_service_lock.put();
    endtask

    // The DUT flips the phase bit (bit 31 of the entry's last DWORD) on every
    // lap of the ring; an entry is new when its phase differs from the lap
    // parity of the consumer pointer (mqnic.py:563).
    protected function bit entry_valid(mqnic_drv_q q, bit [63:0] entry);
        bit [31:0] last_dw = mem_u32(entry + 28);
        return last_dw[31] != ((q.cons & q.size) != 0);
    endfunction

    protected task process_eq(mqnic_drv_q eq);
        bit [63:0]   e;
        bit [15:0]   typ, src;
        int unsigned n = 0;
        forever begin
            e = eq.base + (eq.cons & eq.mask) * eq.stride;
            if (!entry_valid(eq, e)) break;
            typ = mem_u16(e + 0);
            src = mem_u16(e + 2);
            n_events++;
            if (typ != 16'h0000)
                `uvm_error(get_type_name(), $sformatf("EQ %0d: event type 0x%04h is not a completion", eq.index, typ))
            else if (!m_cq_by_index.exists(src))
                `uvm_error(get_type_name(), $sformatf("EQ %0d: completion event for CQ %0d, which was never opened", eq.index, src))
            else begin
                process_cq(m_cq_by_index[src]);
                arm(m_cq_by_index[src]);
            end
            eq.cons++;
            n++;
        end
        if (n > 0) begin
            wr(eq.hw + 'h08, Q_CMD_SET_CONS_PTR | (eq.cons & 32'hFFFF));
            arm(eq);
        end
    endtask

    protected task process_cq(mqnic_drv_q cq);
        mqnic_drv_q  q = cq.ring;
        bit [63:0]   e;
        bit [15:0]   cpl_q, cpl_idx, cpl_len;
        int unsigned slot;
        forever begin
            e = cq.base + (cq.cons & cq.mask) * cq.stride;
            if (!entry_valid(cq, e)) break;
            cpl_q   = mem_u16(e + 0);
            cpl_idx = mem_u16(e + 2);
            cpl_len = mem_u16(e + 4);
            slot    = cpl_idx & q.mask;

            if (cpl_q != q.index) begin
                `uvm_error(get_type_name(),
                    $sformatf("%s %0d: completion names queue %0d", q.kind, q.index, cpl_q))
                n_cpl_errors++;
            end
            if (!q.in_use[slot]) begin
                `uvm_error(get_type_name(),
                    $sformatf("%s %0d: completion for slot %0d, which holds no posted descriptor",
                              q.kind, q.index, slot))
                n_cpl_errors++;
            end
            else if (q.is_tx) begin
                n_tx_completed++;
            end
            else begin
                mqnic_e2e_pkt p = mqnic_e2e_pkt::type_id::create("rx");
                byte unsigned d [];
                if (cpl_len > pkt_buf_size)
                    `uvm_error(get_type_name(),
                        $sformatf("RXQ %0d: completion length %0d exceeds the %0d B buffer",
                                  q.index, cpl_len, pkt_buf_size))
                host.mem.read_bytes(q.buf_addr[slot], cpl_len, d);
                p.data         = d;
                p.queue        = int'(q.index);
                p.ts_ns        = mem_u32(e + 8);
                p.ts_s         = mem_u16(e + 12);
                p.rx_csum      = mem_u16(e + 14);
                p.rx_hash      = mem_u32(e + 16);
                p.rx_hash_type = host.mem.read_byte(e + 20);
                rx_queue.push_back(p);
                n_rx_received++;
                rx_ap.write(p);
                ->rx_event;
            end
            q.in_use[slot] = 1'b0;
            q.n_done++;
            cq.cons++;
        end
        wr(cq.hw + 'h08, Q_CMD_SET_CONS_PTR | (cq.cons & 32'hFFFF));

        // Advance the ring over every slot the completions freed.
        while (q.cons != q.prod && !q.in_use[q.cons & q.mask]) q.cons++;
        if (q.is_tx) ->tx_clean_event;
        else         refill(q);
    endtask

    // Every posted TX descriptor completed and nothing waiting to be read.
    virtual function bit tx_idle();
        foreach (txqs[i]) if (txqs[i].cons != txqs[i].prod) return 1'b0;
        return 1'b1;
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("sent %0d, TX completions %0d, received %0d, events %0d, interrupts %0d, completion errors %0d",
                      n_tx_sent, n_tx_completed, n_rx_received, n_events, n_irqs, n_cpl_errors), UVM_LOW)
        if (port_up && n_tx_completed != n_tx_sent)
            `uvm_error(get_type_name(),
                $sformatf("%0d frame(s) sent but only %0d TX completion(s) arrived",
                          n_tx_sent, n_tx_completed))
    endfunction

endclass : mqnic_drv

`endif // MQNIC_DRV_SV
