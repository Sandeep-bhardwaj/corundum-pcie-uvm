// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_vrf_pkg
// -----------------------------------------------------------------------------
// Common verification types, DUT data structures, register-map constants and
// utility functions shared by every UVC, model, environment and test.
//
// Implements : VERIFICATION_STRATEGY.md  §12.3 (data structures),
//                                        §8.2/§8.3 (register constants),
//                                        §17.1 (naming)
// Introduced : Step 0 (infrastructure)
//
// Sources of truth for the constants below:
//   modules/mqnic/mqnic_hw.h              - register map, descriptor layout
//   fpga/lib/pcie/rtl/dma_if_pcie_rd.v    - PCIE_ERROR_* / DMA_ERROR_* encodings
//
// This package contains NO UVM component classes - only types, constants and
// pure functions, and deliberately does NOT import uvm_pkg. Keeping it
// dependency-free lets every later package import it without creating cycles,
// and lets it be statically checked without UVM sources present.
//
// A timescale is declared explicitly here. The Corundum RTL issues `resetall
// followed by `timescale 1ns / 1ps in every file, so any design element that
// omits one is flagged as inconsistent. STRATEGY §16.2.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package mqnic_vrf_pkg;

    // -------------------------------------------------------------------------
    // Generic verification enums
    // -------------------------------------------------------------------------

    // Agent operating mode. Note MODE_ACTIVE_SLAVE: several DUT interfaces have
    // the DUT as master (e.g. m_axil_csr_* on mqnic_core_pcie), so the agent
    // must respond rather than initiate. See STRATEGY §7.1.
    typedef enum {
        MODE_ACTIVE_MASTER,
        MODE_ACTIVE_SLAVE,
        MODE_PASSIVE
    } mqnic_agent_mode_e;

    // Backpressure shaping applied by drivers/responders. STRATEGY §7.2.
    typedef enum {
        BP_NONE,        // never deassert ready
        BP_RANDOM,      // uniformly random ready, ~50% duty
        BP_AGGRESSIVE,  // ready mostly low, ~10% duty
        BP_BURSTY       // long ready / long stall alternating bursts
    } mqnic_bp_profile_e;

    typedef enum bit {
        MQNIC_READ  = 1'b0,
        MQNIC_WRITE = 1'b1
    } mqnic_dir_e;

    // Generic TLP interface channels of mqnic_core_pcie. STRATEGY §7.2.
    typedef enum {
        TLP_CH_RX_REQ,          // host -> BAR request
        TLP_CH_RX_CPL,          // completion for DUT-issued read
        TLP_CH_TX_RD_REQ,       // DUT read request
        TLP_CH_TX_WR_REQ,       // DUT write request
        TLP_CH_TX_CPL,          // DUT completion for a BAR request
        TLP_CH_TX_MSIX_WR_REQ   // MSI-X interrupt write
    } mqnic_tlp_channel_e;

    // Xilinx UltraScale+ PCIe AXI-Stream channels. STRATEGY §7.6.
    typedef enum {
        PCIE_CH_RQ,     // requester request  (DUT -> host)
        PCIE_CH_RC,     // requester completion (host -> DUT)
        PCIE_CH_CQ,     // completer request  (host -> DUT)
        PCIE_CH_CC      // completer completion (DUT -> host)
    } mqnic_us_channel_e;

    // -------------------------------------------------------------------------
    // PCIe / DMA status encodings
    // Source: fpga/lib/pcie/rtl/dma_if_pcie_rd.v:270-288
    // -------------------------------------------------------------------------

    typedef enum bit [3:0] {
        PCIE_ERROR_NONE         = 4'd0,
        PCIE_ERROR_POISONED     = 4'd1,
        PCIE_ERROR_BAD_STATUS   = 4'd2,
        PCIE_ERROR_MISMATCH     = 4'd3,
        PCIE_ERROR_INVALID_LEN  = 4'd4,
        PCIE_ERROR_INVALID_ADDR = 4'd5,
        PCIE_ERROR_INVALID_TAG  = 4'd6,
        PCIE_ERROR_FLR          = 4'd8,
        PCIE_ERROR_TIMEOUT      = 4'd15
    } mqnic_pcie_error_e;

    typedef enum bit [3:0] {
        DMA_ERROR_NONE             = 4'd0,
        DMA_ERROR_TIMEOUT          = 4'd1,
        DMA_ERROR_PARITY           = 4'd2,
        DMA_ERROR_AXI_RD_SLVERR    = 4'd4,
        DMA_ERROR_AXI_RD_DECERR    = 4'd5,
        DMA_ERROR_AXI_WR_SLVERR    = 4'd6,
        DMA_ERROR_AXI_WR_DECERR    = 4'd7,
        DMA_ERROR_PCIE_FLR         = 4'd8,
        DMA_ERROR_PCIE_CPL_POISONED = 4'd9,
        DMA_ERROR_PCIE_CPL_STATUS_UR = 4'd10,
        DMA_ERROR_PCIE_CPL_STATUS_CA = 4'd11
    } mqnic_dma_error_e;

    // PCIe completion status field (spec-defined, not Corundum-specific)
    typedef enum bit [2:0] {
        CPL_STATUS_SC  = 3'b000,   // successful completion
        CPL_STATUS_UR  = 3'b001,   // unsupported request
        CPL_STATUS_CRS = 3'b010,   // configuration request retry
        CPL_STATUS_CA  = 3'b100    // completer abort
    } mqnic_cpl_status_e;

    // -------------------------------------------------------------------------
    // PCIe sizing helpers
    // max_payload_size / max_read_request_size are 3-bit encodings where the
    // byte count is 128 << value.
    // -------------------------------------------------------------------------

    function automatic int unsigned mps_bytes(bit [2:0] enc);
        return 128 << enc;
    endfunction

    function automatic int unsigned mrrs_bytes(bit [2:0] enc);
        return 128 << enc;
    endfunction

    // Read Completion Boundary: rcb_128b=0 -> 64 B, =1 -> 128 B
    function automatic int unsigned rcb_bytes(bit rcb_128b);
        return rcb_128b ? 128 : 64;
    endfunction

    // True if [addr, addr+len) crosses a 4 KB boundary. Any DUT-generated read
    // request for which this returns 1 is a protocol violation (STRATEGY §15.2).
    function automatic bit crosses_4k(bit [63:0] addr, int unsigned len);
        bit [63:0] last_byte;
        if (len == 0) return 1'b0;
        last_byte = addr + 64'(len) - 64'd1;
        return ((addr >> 12) != (last_byte >> 12));
    endfunction

    // -------------------------------------------------------------------------
    // mqnic data structures
    // Source: modules/mqnic/mqnic_hw.h:393-431
    //
    // All fields are little-endian in memory. The structs below are the LOGICAL
    // view; use the pack/unpack functions for the byte-accurate view. Do not
    // bit-cast these structs onto a byte stream - field order would be wrong.
    // -------------------------------------------------------------------------

    localparam int unsigned MQNIC_DESC_SIZE  = 16;
    localparam int unsigned MQNIC_CPL_SIZE   = 32;
    localparam int unsigned MQNIC_EVENT_SIZE = 32;

    localparam bit [15:0] MQNIC_EVENT_TYPE_CPL = 16'h0000;

    typedef struct {
        bit [15:0] rsvd0;
        bit [15:0] tx_csum_cmd;
        bit [31:0] len;
        bit [63:0] addr;
    } mqnic_desc_t;

    typedef struct {
        bit [15:0] queue;
        bit [15:0] index;
        bit [15:0] len;
        bit [15:0] rsvd0;
        bit [31:0] ts_ns;
        bit [15:0] ts_s;
        bit [15:0] rx_csum;
        bit [31:0] rx_hash;
        bit [7:0]  rx_hash_type;
        bit [7:0]  port;
        bit [7:0]  rsvd2;
        bit [7:0]  rsvd3;
        bit [31:0] rsvd4;
        bit [31:0] phase;
    } mqnic_cpl_t;

    typedef struct {
        bit [15:0] ev_type;     // 'type' is a SV keyword
        bit [15:0] source;
        bit [31:0] rsvd0;
        bit [31:0] rsvd1;
        bit [31:0] rsvd2;
        bit [31:0] rsvd3;
        bit [31:0] rsvd4;
        bit [31:0] rsvd5;
        bit [31:0] phase;
    } mqnic_event_t;

    // ---- little-endian primitives -------------------------------------------

    function automatic void put_le16(ref byte unsigned q[], input int unsigned off,
                                     input bit [15:0] v);
        q[off+0] = v[7:0];
        q[off+1] = v[15:8];
    endfunction

    function automatic void put_le32(ref byte unsigned q[], input int unsigned off,
                                     input bit [31:0] v);
        q[off+0] = v[7:0];
        q[off+1] = v[15:8];
        q[off+2] = v[23:16];
        q[off+3] = v[31:24];
    endfunction

    function automatic void put_le64(ref byte unsigned q[], input int unsigned off,
                                     input bit [63:0] v);
        put_le32(q, off,   v[31:0]);
        put_le32(q, off+4, v[63:32]);
    endfunction

    function automatic bit [15:0] get_le16(const ref byte unsigned q[],
                                           input int unsigned off);
        return {q[off+1], q[off+0]};
    endfunction

    function automatic bit [31:0] get_le32(const ref byte unsigned q[],
                                           input int unsigned off);
        return {q[off+3], q[off+2], q[off+1], q[off+0]};
    endfunction

    function automatic bit [63:0] get_le64(const ref byte unsigned q[],
                                           input int unsigned off);
        return {get_le32(q, off+4), get_le32(q, off)};
    endfunction

    // ---- descriptor pack / unpack -------------------------------------------

    function automatic void pack_desc(input mqnic_desc_t d,
                                      output byte unsigned q[]);
        q = new[MQNIC_DESC_SIZE];
        put_le16(q, 0,  d.rsvd0);
        put_le16(q, 2,  d.tx_csum_cmd);
        put_le32(q, 4,  d.len);
        put_le64(q, 8,  d.addr);
    endfunction

    function automatic mqnic_desc_t unpack_desc(const ref byte unsigned q[]);
        mqnic_desc_t d;
        d.rsvd0       = get_le16(q, 0);
        d.tx_csum_cmd = get_le16(q, 2);
        d.len         = get_le32(q, 4);
        d.addr        = get_le64(q, 8);
        return d;
    endfunction

    function automatic void pack_cpl(input mqnic_cpl_t c,
                                     output byte unsigned q[]);
        q = new[MQNIC_CPL_SIZE];
        put_le16(q, 0,  c.queue);
        put_le16(q, 2,  c.index);
        put_le16(q, 4,  c.len);
        put_le16(q, 6,  c.rsvd0);
        put_le32(q, 8,  c.ts_ns);
        put_le16(q, 12, c.ts_s);
        put_le16(q, 14, c.rx_csum);
        put_le32(q, 16, c.rx_hash);
        q[20] = c.rx_hash_type;
        q[21] = c.port;
        q[22] = c.rsvd2;
        q[23] = c.rsvd3;
        put_le32(q, 24, c.rsvd4);
        put_le32(q, 28, c.phase);
    endfunction

    function automatic mqnic_cpl_t unpack_cpl(const ref byte unsigned q[]);
        mqnic_cpl_t c;
        c.queue        = get_le16(q, 0);
        c.index        = get_le16(q, 2);
        c.len          = get_le16(q, 4);
        c.rsvd0        = get_le16(q, 6);
        c.ts_ns        = get_le32(q, 8);
        c.ts_s         = get_le16(q, 12);
        c.rx_csum      = get_le16(q, 14);
        c.rx_hash      = get_le32(q, 16);
        c.rx_hash_type = q[20];
        c.port         = q[21];
        c.rsvd2        = q[22];
        c.rsvd3        = q[23];
        c.rsvd4        = get_le32(q, 24);
        c.phase        = get_le32(q, 28);
        return c;
    endfunction

    function automatic void pack_event(input mqnic_event_t e,
                                       output byte unsigned q[]);
        q = new[MQNIC_EVENT_SIZE];
        put_le16(q, 0,  e.ev_type);
        put_le16(q, 2,  e.source);
        put_le32(q, 4,  e.rsvd0);
        put_le32(q, 8,  e.rsvd1);
        put_le32(q, 12, e.rsvd2);
        put_le32(q, 16, e.rsvd3);
        put_le32(q, 20, e.rsvd4);
        put_le32(q, 24, e.rsvd5);
        put_le32(q, 28, e.phase);
    endfunction

    function automatic mqnic_event_t unpack_event(const ref byte unsigned q[]);
        mqnic_event_t e;
        e.ev_type = get_le16(q, 0);
        e.source  = get_le16(q, 2);
        e.rsvd0   = get_le32(q, 4);
        e.rsvd1   = get_le32(q, 8);
        e.rsvd2   = get_le32(q, 12);
        e.rsvd3   = get_le32(q, 16);
        e.rsvd4   = get_le32(q, 20);
        e.rsvd5   = get_le32(q, 24);
        e.phase   = get_le32(q, 28);
        return e;
    endfunction

    // -------------------------------------------------------------------------
    // Register block map
    // Source: modules/mqnic/mqnic_hw.h:60-95 (and following)
    //
    // Corundum exposes a WALKED LINKED LIST of register blocks, not a flat map.
    // Each block starts with TYPE/VER/NEXT_PTR. NEXT_PTR == 0 terminates the
    // list. See STRATEGY §8.2 - the RAL must model this as discoverable.
    // -------------------------------------------------------------------------

    localparam bit [31:0] MQNIC_RB_REG_TYPE     = 32'h00;
    localparam bit [31:0] MQNIC_RB_REG_VER      = 32'h04;
    localparam bit [31:0] MQNIC_RB_REG_NEXT_PTR = 32'h08;

    // Block type IDs
    localparam bit [31:0] MQNIC_RB_FW_ID_TYPE      = 32'hFFFFFFFF;
    localparam bit [31:0] MQNIC_RB_FW_ID_VER       = 32'h00000100;
    localparam bit [31:0] MQNIC_RB_APP_INFO_TYPE   = 32'h0000C005;
    localparam bit [31:0] MQNIC_RB_PHC_TYPE        = 32'h0000C080;
    localparam bit [31:0] MQNIC_RB_PHC_PEROUT_TYPE = 32'h0000C081;
    localparam bit [31:0] MQNIC_RB_GPIO_TYPE       = 32'h0000C100;
    localparam bit [31:0] MQNIC_RB_I2C_TYPE        = 32'h0000C110;
    localparam bit [31:0] MQNIC_RB_SPI_FLASH_TYPE  = 32'h0000C120;
    localparam bit [31:0] MQNIC_RB_BPI_FLASH_TYPE  = 32'h0000C121;

    // FW ID block registers
    localparam bit [31:0] MQNIC_RB_FW_ID_REG_FPGA_ID    = 32'h0C;
    localparam bit [31:0] MQNIC_RB_FW_ID_REG_FW_ID      = 32'h10;
    localparam bit [31:0] MQNIC_RB_FW_ID_REG_FW_VER     = 32'h14;
    localparam bit [31:0] MQNIC_RB_FW_ID_REG_BOARD_ID   = 32'h18;
    localparam bit [31:0] MQNIC_RB_FW_ID_REG_BOARD_VER  = 32'h1C;
    localparam bit [31:0] MQNIC_RB_FW_ID_REG_BUILD_DATE = 32'h20;
    localparam bit [31:0] MQNIC_RB_FW_ID_REG_GIT_HASH   = 32'h24;
    localparam bit [31:0] MQNIC_RB_FW_ID_REG_REL_INFO   = 32'h28;

    // -------------------------------------------------------------------------
    // Queue / CQ / EQ control interface
    // Source: modules/mqnic/mqnic_hw.h:333-389
    //
    // These are COMMAND registers, not a flat field map: a command opcode is
    // written to CTRL_STATUS and the DUT applies it. A plain uvm_reg mirror
    // cannot express this - model it as a sequence layer (STRATEGY §8.3).
    // -------------------------------------------------------------------------

    // Queue (TXQ / RXQ)
    localparam bit [31:0] MQNIC_QUEUE_BASE_ADDR_VF_REG = 32'h00;
    localparam bit [31:0] MQNIC_QUEUE_CTRL_STATUS_REG  = 32'h08;
    localparam bit [31:0] MQNIC_QUEUE_SIZE_CQN_REG     = 32'h0C;
    localparam bit [31:0] MQNIC_QUEUE_PROD_PTR_REG     = 32'h10;
    localparam bit [31:0] MQNIC_QUEUE_CONS_PTR_REG     = 32'h12;

    localparam bit [31:0] MQNIC_QUEUE_ENABLE_MASK = 32'h00000001;
    localparam bit [31:0] MQNIC_QUEUE_ACTIVE_MASK = 32'h00000008;
    localparam bit [31:0] MQNIC_QUEUE_PTR_MASK    = 32'h0000FFFF;

    localparam bit [31:0] MQNIC_QUEUE_CMD_SET_VF_ID    = 32'h80010000;
    localparam bit [31:0] MQNIC_QUEUE_CMD_SET_SIZE     = 32'h80020000;
    localparam bit [31:0] MQNIC_QUEUE_CMD_SET_CQN      = 32'hC0000000;
    localparam bit [31:0] MQNIC_QUEUE_CMD_SET_PROD_PTR = 32'h80800000;
    localparam bit [31:0] MQNIC_QUEUE_CMD_SET_CONS_PTR = 32'h80900000;
    localparam bit [31:0] MQNIC_QUEUE_CMD_SET_ENABLE   = 32'h40000100;

    // Completion queue
    localparam bit [31:0] MQNIC_CQ_BASE_ADDR_VF_REG = 32'h00;
    localparam bit [31:0] MQNIC_CQ_CTRL_STATUS_REG  = 32'h08;
    localparam bit [31:0] MQNIC_CQ_PROD_PTR_REG     = 32'h0C;
    localparam bit [31:0] MQNIC_CQ_CONS_PTR_REG     = 32'h0E;

    localparam bit [31:0] MQNIC_CQ_ENABLE_MASK = 32'h00010000;
    localparam bit [31:0] MQNIC_CQ_ARM_MASK    = 32'h00020000;
    localparam bit [31:0] MQNIC_CQ_ACTIVE_MASK = 32'h00080000;
    localparam bit [31:0] MQNIC_CQ_PTR_MASK    = 32'h0000FFFF;

    localparam bit [31:0] MQNIC_CQ_CMD_SET_VF_ID        = 32'h80010000;
    localparam bit [31:0] MQNIC_CQ_CMD_SET_SIZE         = 32'h80020000;
    localparam bit [31:0] MQNIC_CQ_CMD_SET_EQN          = 32'hC0000000;
    localparam bit [31:0] MQNIC_CQ_CMD_SET_PROD_PTR     = 32'h80800000;
    localparam bit [31:0] MQNIC_CQ_CMD_SET_CONS_PTR     = 32'h80900000;
    localparam bit [31:0] MQNIC_CQ_CMD_SET_CONS_PTR_ARM = 32'h80910000;
    localparam bit [31:0] MQNIC_CQ_CMD_SET_ENABLE       = 32'h40000100;
    localparam bit [31:0] MQNIC_CQ_CMD_SET_ARM          = 32'h40000200;

    // Event queue
    localparam bit [31:0] MQNIC_EQ_BASE_ADDR_VF_REG = 32'h00;
    localparam bit [31:0] MQNIC_EQ_CTRL_STATUS_REG  = 32'h08;
    localparam bit [31:0] MQNIC_EQ_PROD_PTR_REG     = 32'h0C;
    localparam bit [31:0] MQNIC_EQ_CONS_PTR_REG     = 32'h0E;

    localparam bit [31:0] MQNIC_EQ_ENABLE_MASK = 32'h00010000;
    localparam bit [31:0] MQNIC_EQ_ARM_MASK    = 32'h00020000;
    localparam bit [31:0] MQNIC_EQ_ACTIVE_MASK = 32'h00080000;
    localparam bit [31:0] MQNIC_EQ_PTR_MASK    = 32'h0000FFFF;

    localparam bit [31:0] MQNIC_EQ_CMD_SET_VF_ID        = 32'h80010000;
    localparam bit [31:0] MQNIC_EQ_CMD_SET_SIZE         = 32'h80020000;
    localparam bit [31:0] MQNIC_EQ_CMD_SET_IRQN         = 32'hC0000000;
    localparam bit [31:0] MQNIC_EQ_CMD_SET_PROD_PTR     = 32'h80800000;
    localparam bit [31:0] MQNIC_EQ_CMD_SET_CONS_PTR     = 32'h80900000;
    localparam bit [31:0] MQNIC_EQ_CMD_SET_CONS_PTR_ARM = 32'h80910000;
    localparam bit [31:0] MQNIC_EQ_CMD_SET_ENABLE       = 32'h40000100;
    localparam bit [31:0] MQNIC_EQ_CMD_SET_ARM          = 32'h40000200;


    // -------------------------------------------------------------------------
    // TLP HEADER ENCODE / DECODE
    //
    // Field positions verified against fpga/lib/pcie/rtl/dma_if_pcie_rd.v:
    //   request build  :752-783   completion decode :971-990
    //
    // These are here rather than open-coded at each call site because the layout
    // is NOT the obvious one and getting it wrong is silent: an address decoded
    // from the wrong bits still looks like an address, and the resulting
    // mismatch reads as a DMA bug. In particular
    //   * tag lives at [79:72] on a request  (not [103:96])
    //   * length lives at [105:96]           (not [9:0])
    //   * a 3DW request puts addr[63:2] at [63:34]; a 4DW one at [63:2]
    // -------------------------------------------------------------------------

    localparam bit [2:0] TLP_FMT_3DW      = 3'b000;   // no data
    localparam bit [2:0] TLP_FMT_4DW      = 3'b001;   // no data, 64-bit address
    localparam bit [2:0] TLP_FMT_3DW_DATA = 3'b010;
    localparam bit [2:0] TLP_FMT_4DW_DATA = 3'b011;

    localparam bit [4:0] TLP_TYPE_MEM     = 5'b00000;
    localparam bit [4:0] TLP_TYPE_CPL     = 5'b01010;

    // Memory read request. Uses the 4DW form when the address needs it, exactly
    // as the DUT does (:773).
    function automatic bit [127:0] tlp_hdr_read_req(bit [63:0] addr,
                                                    int unsigned dw_len,
                                                    bit [7:0]  tag,
                                                    bit [15:0] requester_id,
                                                    bit [3:0]  first_be = 4'hF,
                                                    bit [3:0]  last_be  = 4'hF);
        bit [127:0] h;
        bit         need_4dw;

        h = 128'd0;
        need_4dw = ((addr[63:2] >> 30) != 0);

        h[127:125] = need_4dw ? TLP_FMT_4DW : TLP_FMT_3DW;
        h[124:120] = TLP_TYPE_MEM;
        h[105:96]  = 10'(dw_len);
        h[95:80]   = requester_id;
        h[79:72]   = tag;
        h[71:68]   = (dw_len == 1) ? 4'b0000 : last_be;
        h[67:64]   = (dw_len == 1) ? (first_be & last_be) : first_be;

        if (need_4dw) begin
            h[63:2] = addr[63:2];
            h[1:0]  = 2'b00;
        end
        else begin
            h[63:34] = addr[31:2];
            h[33:32] = 2'b00;
            h[31:0]  = 32'd0;
        end
        return h;
    endfunction

    // Completion with data. byte_count counts to the end of the ORIGINAL
    // request, not this completion (:988).
    function automatic bit [127:0] tlp_hdr_completion(bit [15:0] completer_id,
                                                      bit [2:0]  status,
                                                      int unsigned byte_count,
                                                      bit [15:0] requester_id,
                                                      bit [7:0]  tag,
                                                      bit [6:0]  lower_addr,
                                                      int unsigned dw_len,
                                                      bit        poisoned = 1'b0);
        bit [127:0] h;
        h = 128'd0;
        h[127:125] = (dw_len == 0) ? TLP_FMT_3DW : TLP_FMT_3DW_DATA;
        h[124:120] = TLP_TYPE_CPL;
        h[110]     = poisoned;                 // EP
        h[105:96]  = 10'(dw_len);
        h[95:80]   = completer_id;
        h[79:77]   = status;
        h[76]      = 1'b0;                     // BCM
        h[75:64]   = 12'(byte_count);
        h[63:48]   = requester_id;
        h[47:40]   = tag;
        h[38:32]   = lower_addr;
        return h;
    endfunction

    // ---- decode --------------------------------------------------------------
    function automatic int unsigned tlp_hdr_len_dw(bit [127:0] h);
        int unsigned n = int'(h[105:96]);
        return (n == 0) ? 1024 : n;            // 0 encodes 1024 DWORDs
    endfunction

    function automatic bit [63:0] tlp_hdr_req_addr(bit [127:0] h);
        // fmt bit 0 selects 3DW vs 4DW for a request.
        if (h[125])
            return {h[63:2], 2'b00};
        else
            return {32'd0, h[63:34], 2'b00};
    endfunction

    function automatic bit [7:0] tlp_hdr_req_tag(bit [127:0] h);
        return h[79:72];
    endfunction

    function automatic bit [15:0] tlp_hdr_req_requester_id(bit [127:0] h);
        return h[95:80];
    endfunction

    // -------------------------------------------------------------------------
    // BYTE-EXACT request extent.
    //
    // A read request header carries a DWORD-ALIGNED address and a DWORD count.
    // The real byte range is narrower, and the byte enables are what say so:
    // first_be marks which bytes of the first DWORD are wanted, last_be which
    // of the last. Anything that treats the header's address and length as the
    // transfer is wrong by up to 3 bytes at each end.
    //
    // That is not cosmetic. dma_if_pcie_rd reconstructs where completion data
    // belongs in RAM as
    //
    //     offset = ram_end_addr - (byte_count + lower_addr[1:0])
    //             (dma_if_pcie_rd.v:1008)
    //
    // so a completion built from the DWORD-rounded extent lands the whole
    // transfer 0-3 bytes off. See docs/bringup_log.md, bug 9.
    // -------------------------------------------------------------------------
    function automatic bit [3:0] tlp_hdr_req_first_be(bit [127:0] h);
        return h[67:64];
    endfunction

    function automatic bit [3:0] tlp_hdr_req_last_be(bit [127:0] h);
        return h[71:68];
    endfunction

    // Byte offset of the first enabled byte within the first DWORD (0..3).
    function automatic int unsigned tlp_hdr_req_first_off(bit [127:0] h);
        bit [3:0] fbe = tlp_hdr_req_first_be(h);
        if (fbe == 4'b0000) return 0;              // zero-length read
        for (int i = 0; i < 4; i++)
            if (fbe[i]) return i;
        return 0;
    endfunction

    // Address of the first enabled byte. This is what PCIe calls the request
    // address; the header holds it rounded down to a DWORD.
    function automatic bit [63:0] tlp_hdr_req_byte_addr(bit [127:0] h);
        return tlp_hdr_req_addr(h) + 64'(tlp_hdr_req_first_off(h));
    endfunction

    // Number of bytes actually requested.
    function automatic int unsigned tlp_hdr_req_byte_len(bit [127:0] h);
        bit [3:0]    fbe  = tlp_hdr_req_first_be(h);
        bit [3:0]    lbe  = tlp_hdr_req_last_be(h);
        int unsigned dw   = tlp_hdr_len_dw(h);
        int unsigned foff = tlp_hdr_req_first_off(h);
        int unsigned hi   = 0;

        if (fbe == 4'b0000) return 0;              // zero-length read

        // A single-DWORD request carries last_be == 0 and encodes the whole
        // extent in first_be (dma_if_pcie_rd.v:770-771).
        if (lbe == 4'b0000) begin
            for (int i = 0; i < 4; i++) if (fbe[i]) hi = i;
            return hi - foff + 1;
        end

        for (int i = 0; i < 4; i++) if (lbe[i]) hi = i;
        return dw * 4 - foff - (3 - hi);
    endfunction

    function automatic bit [7:0] tlp_hdr_cpl_tag(bit [127:0] h);
        return h[47:40];
    endfunction

    function automatic bit [2:0] tlp_hdr_cpl_status(bit [127:0] h);
        return h[79:77];
    endfunction

    function automatic int unsigned tlp_hdr_cpl_byte_count(bit [127:0] h);
        int unsigned n = int'(h[75:64]);
        return (n == 0) ? 4096 : n;
    endfunction

    function automatic bit [6:0] tlp_hdr_cpl_lower_addr(bit [127:0] h);
        return h[38:32];
    endfunction

    // =========================================================================
    // Xilinx UltraScale+ AXI-Stream `tuser` codec (Tier 4)
    // =========================================================================
    // Implements : VERIFICATION_STRATEGY.md  §7.6, §22 R2
    //
    // §22 R2 calls this "the single most error-prone piece of the whole TB".
    // Every layout below is TRANSCRIBED FROM THE RTL, not from PG213, and the
    // line references are the transcription source:
    //
    //   RC decode  pcie_us_if_rc.v:276-306
    //   CQ decode  pcie_us_if_cq.v:271-306
    //   RQ encode  pcie_us_if_rq.v:759-866
    //   CC encode  pcie_us_if_cc.v:484-520
    //
    // TWO FINDINGS THAT BOUND THE RISK, both from reading the RTL:
    //
    // 1. THE DUTs READ VERY LITTLE OF tuser. RC samples framing bits ONLY -
    //    byte_en[31:0], discontinue and parity are never read. CQ samples the
    //    byte enables and framing. So the TB has far fewer fields to get right
    //    than the 75/85/137/161/183-bit layouts suggest.
    //
    // 2. STRADDLE SLOTS ARE QUANTISED TO 128 BITS. A TLP may begin only at a
    //    128-bit boundary: lanes 0 and 4 at 256-bit data, lanes 0/4/8/12 at
    //    512-bit. That is implicit in the RTL - is_sop_ptr is 2 bits and is
    //    multiplied by 4 (rc:301) - and it is a HARD CONSTRAINT ON THE DRIVER,
    //    not a decode detail. A driver that starts a TLP at lane 1 produces
    //    stimulus the DUT cannot represent.
    //
    // GOLDEN CONFIGURATION (mqnic_core_pcie_us.v:157-167) is 256-bit data:
    //   RC 75 bits, STRADDLING     RQ 62 bits, not straddling
    //   CQ 85 bits, not straddling CC 33 bits, not straddling
    // RC is therefore the ONLY channel that straddles at the width Corundum
    // actually builds, which is where Tier 4's risk is concentrated.
    //
    // Validated against an independent Python transcription over 308 framing
    // cases, 0 divergent. That cross-check caught a real bug in the first
    // version of rc_tuser_encode: at 256-bit the two is_sop bits are addressed
    // BY LANE (bit 32 = lane 0, bit 33 = lane 4), not as a positional list.
    // -------------------------------------------------------------------------

    localparam int US_RC_USER_WIDTH_256 = 75;
    localparam int US_RC_USER_WIDTH_512 = 161;
    localparam int US_RQ_USER_WIDTH_256 = 62;   // mqnic uses 62, not the RTL default 60
    localparam int US_RQ_USER_WIDTH_512 = 137;
    localparam int US_CQ_USER_WIDTH_256 = 85;
    localparam int US_CQ_USER_WIDTH_512 = 183;
    localparam int US_CC_USER_WIDTH_256 = 33;
    localparam int US_CC_USER_WIDTH_512 = 81;

    // Lane granularity of a straddle slot, in 32-bit lanes.
    localparam int US_STRADDLE_LANE_STEP = 4;

    // Maxima for the non-parameterized pcie_us_axis_if (§4.3 rule 1). In the
    // package rather than the interface because the class-based UVC needs them
    // and a class cannot read an interface localparam - the SV-LCM-PND lesson.
    localparam int US_MAX_DATA_WIDTH = 512;
    localparam int US_MAX_KEEP_WIDTH = US_MAX_DATA_WIDTH / 32;   // 16
    localparam int US_MAX_USER_WIDTH = 183;                      // CQ at 512

    // ---- RC: TB drives, DUT decodes (pcie_us_if_rc.v:276-306) ---------------
    //
    // sop_lanes / eop_lanes are bit masks over strobe lanes. Only lanes that
    // are multiples of US_STRADDLE_LANE_STEP may carry a start.
    function automatic bit [183:0] us_rc_tuser_encode(input int unsigned data_width,
                                                      input bit [15:0] sop_lanes,
                                                      input bit [15:0] eop_lanes);
        bit [183:0] u = '0;
        int seg;

        if (data_width == 256) begin
            // Addressed BY LANE, not positionally - see the header note.
            for (int lane = 0; lane < 8; lane += US_STRADDLE_LANE_STEP)
                if (sop_lanes[lane]) u[32 + (lane / US_STRADDLE_LANE_STEP)] = 1'b1;

            seg = 0;
            for (int lane = 0; lane < 8; lane++)
                if (eop_lanes[lane] && seg < 2) begin
                    u[34 + seg*4]        = 1'b1;
                    u[35 + seg*4 +: 3]   = 3'(lane);
                    seg++;
                end
        end
        else begin   // 512
            seg = 0;
            for (int lane = 0; lane < 16; lane += US_STRADDLE_LANE_STEP)
                if (sop_lanes[lane] && seg < 4) begin
                    u[64 + seg]          = 1'b1;
                    u[68 + seg*2 +: 2]   = 2'(lane / US_STRADDLE_LANE_STEP);
                    seg++;
                end

            seg = 0;
            for (int lane = 0; lane < 16; lane++)
                if (eop_lanes[lane] && seg < 4) begin
                    u[76 + seg]          = 1'b1;
                    u[80 + seg*4 +: 4]   = 4'(lane);
                    seg++;
                end
        end
        return u;
    endfunction

    // ---- CQ: TB drives (pcie_us_if_cq.v:271, 304, 306) ----------------------
    //
    // The byte-enable packing differs per width AND per straddle setting, and
    // the straddling form interleaves the two TLPs' enables rather than
    // concatenating them: {last1, first1, last0, first0}.
    function automatic bit [183:0] us_cq_tuser_encode(input int unsigned data_width,
                                                      input bit          straddle,
                                                      input bit [3:0]    first_be0,
                                                      input bit [3:0]    last_be0,
                                                      input bit [3:0]    first_be1 = '0,
                                                      input bit [3:0]    last_be1  = '0,
                                                      input bit [15:0]   sop_lanes = '0,
                                                      input bit [15:0]   eop_lanes = '0);
        bit [183:0] u = '0;
        int seg;

        if (data_width >= 512) begin
            u[3:0]   = first_be0;
            u[11:8]  = last_be0;
            if (straddle) begin
                u[7:4]   = first_be1;
                u[15:12] = last_be1;

                seg = 0;
                for (int lane = 0; lane < 16; lane += US_STRADDLE_LANE_STEP)
                    if (sop_lanes[lane] && seg < 2) begin
                        u[80 + seg]        = 1'b1;
                        u[82 + seg*2 +: 2] = 2'(lane / US_STRADDLE_LANE_STEP);
                        seg++;
                    end
                seg = 0;
                for (int lane = 0; lane < 16; lane++)
                    if (eop_lanes[lane] && seg < 2) begin
                        u[86 + seg]        = 1'b1;
                        u[88 + seg*4 +: 4] = 4'(lane);
                        seg++;
                    end
            end
        end
        else begin
            // The narrow form packs both enables into one byte.
            u[3:0] = first_be0;
            u[7:4] = last_be0;
        end
        return u;
    endfunction

    // CQ byte enables, read back out of tuser.
    //
    // The encode side existed from the start; the decode did not, because the
    // TB drives this channel and "we already know what we sent" felt true. It
    // is not: the MONITOR is what feeds the scoreboard, and it only knows what
    // is on the wire. Without these the scoreboard predicted first_be/last_be
    // as zero and the DUT was reported for reproducing them correctly.
    function automatic bit [3:0] us_cq_first_be(bit [183:0] u, int unsigned data_width,
                                                bit straddle, int unsigned slot = 0);
        if (data_width >= 512 && straddle) return (slot == 0) ? u[3:0] : u[7:4];
        return u[3:0];
    endfunction

    function automatic bit [3:0] us_cq_last_be(bit [183:0] u, int unsigned data_width,
                                               bit straddle, int unsigned slot = 0);
        if (data_width >= 512 && straddle) return (slot == 0) ? u[11:8] : u[15:12];
        return u[7:4];
    endfunction

    // ---- RQ: DUT drives, TB decodes (pcie_us_if_rq.v:759-866) ---------------
    //
    // seq_num is SPLIT at width 62: four bits at [27:24] and the top two at
    // [61:60]. Reading only [27:24] silently truncates every sequence number
    // above 15, which would look like the DUT reusing them.
    function automatic bit [3:0] us_rq_first_be(bit [183:0] u, int unsigned w,
                                                int unsigned slot = 0);
        if (w >= 137) return (slot == 0) ? u[3:0] : u[7:4];
        return u[3:0];
    endfunction

    function automatic bit [3:0] us_rq_last_be(bit [183:0] u, int unsigned w,
                                               int unsigned slot = 0);
        if (w >= 137) return (slot == 0) ? u[11:8] : u[15:12];
        return u[7:4];
    endfunction

    function automatic int unsigned us_rq_addr_offset(bit [183:0] u, int unsigned w);
        return (w >= 137) ? int'(u[19:16]) : int'(u[10:8]);
    endfunction

    function automatic bit us_rq_discontinue(bit [183:0] u, int unsigned w);
        return (w >= 137) ? u[36] : u[11];
    endfunction

    function automatic int unsigned us_rq_seq_num(bit [183:0] u, int unsigned w,
                                                  int unsigned slot = 0);
        if (w >= 137) return (slot == 0) ? int'(u[66:61]) : int'(u[72:67]);
        if (w == 62)  return int'({u[61:60], u[27:24]});   // SPLIT - see above
        return int'(u[27:24]);                             // width 60
    endfunction

    // ---- CC: DUT drives (pcie_us_if_cc.v:484-520) ---------------------------
    function automatic bit us_cc_discontinue(bit [183:0] u, int unsigned w);
        return (w >= 81) ? u[16] : u[0];
    endfunction

    function automatic bit [1:0] us_cc_is_sop(bit [183:0] u, int unsigned w);
        return (w >= 81) ? u[1:0] : 2'b00;
    endfunction

    function automatic bit [1:0] us_cc_is_eop(bit [183:0] u, int unsigned w);
        return (w >= 81) ? u[7:6] : 2'b00;
    endfunction

    // Widths for a given data width, so a testbench cannot pick a mismatched
    // pair by hand.
    function automatic int unsigned us_user_width(mqnic_us_channel_e ch,
                                                  int unsigned data_width);
        bit narrow = (data_width < 512);
        case (ch)
            PCIE_CH_RC: return narrow ? US_RC_USER_WIDTH_256 : US_RC_USER_WIDTH_512;
            PCIE_CH_RQ: return narrow ? US_RQ_USER_WIDTH_256 : US_RQ_USER_WIDTH_512;
            PCIE_CH_CQ: return narrow ? US_CQ_USER_WIDTH_256 : US_CQ_USER_WIDTH_512;
            PCIE_CH_CC: return narrow ? US_CC_USER_WIDTH_256 : US_CC_USER_WIDTH_512;
            default:    return 0;
        endcase
    endfunction

    // Does this channel straddle at this data width?
    // mqnic_core_pcie_us.v:163-166 - RC from 256, the rest only from 512.
    function automatic bit us_straddles(mqnic_us_channel_e ch, int unsigned data_width);
        case (ch)
            PCIE_CH_RC: return (data_width >= 256);
            default:    return (data_width >= 512);
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Segmented DMA RAM interface maxima.
    //
    // These live in the PACKAGE, not in dma_ram_if, because both the interface
    // and the class-based UVC need them. A class cannot legally read an
    // interface's localparam: `interface_name::PARAM` is illegal SystemVerilog
    // (:: is package/class scope resolution only) and VCS rejects it with
    // SV-LCM-PND. Putting them here gives one definition that every consumer
    // can reach. See docs/bringup_log.md, VCS bug 2.
    // -------------------------------------------------------------------------
    localparam int DMA_RAM_MAX_SEG_COUNT      = 8;
    localparam int DMA_RAM_MAX_SEG_DATA_WIDTH = 256;
    localparam int DMA_RAM_MAX_SEG_BE_WIDTH   = DMA_RAM_MAX_SEG_DATA_WIDTH / 8;
    localparam int DMA_RAM_MAX_SEG_ADDR_WIDTH = 16;
    localparam int DMA_RAM_MAX_SEL_WIDTH      = 8;

    // -------------------------------------------------------------------------
    // DMA descriptor interface maxima. In the package for the same reason as the
    // DMA RAM maxima above: a class cannot address an interface localparam.
    // -------------------------------------------------------------------------
    localparam int DMA_DESC_MAX_LEN_WIDTH = 32;
    localparam int DMA_DESC_MAX_TAG_WIDTH = 16;

    // -------------------------------------------------------------------------
    // RSS / Toeplitz
    //
    // The conventional 40-byte Microsoft RSS key. Byte 0 sits in the MOST
    // significant position of the packed form, matching rx_hash.v's hash_key
    // port, where key bit 319 is the MSB of key byte 0.
    // -------------------------------------------------------------------------
    localparam bit [319:0] MQNIC_RSS_KEY_DEFAULT =
        320'h6d5a56da255b0ec24167253d43a38fb0d0ca2bcbae7b30b477cb2da38030f20c6a42b73bbeac01fa;

    function automatic void rss_key_default_bytes(output byte unsigned k[]);
        k = new[40];
        for (int i = 0; i < 40; i++)
            k[i] = MQNIC_RSS_KEY_DEFAULT[319 - i*8 -: 8];
    endfunction

    // -------------------------------------------------------------------------
    // Byte-stream utilities
    // -------------------------------------------------------------------------

    // 16-bit one's complement sum over a byte stream. This is the primitive used
    // by ref_checksum (STRATEGY §10); the RX checksum expected value is
    //     rx_csum == ~ones_complement_sum16(frame[14:]) & 16'hFFFF
    // Sizes are kept as signed int throughout because SystemVerilog's built-in
    // size() returns int; mixing in int unsigned produces sign-conversion
    // warnings under strict lint.
    function automatic bit [15:0] ones_complement_sum16(const ref byte unsigned q[],
                                                        input int start = 0,
                                                        input int len   = 0);
        int        size;
        int        last;
        bit [31:0] sum;
        bit [31:0] word;

        size = q.size();
        last = (len <= 0) ? size : (start + len);
        if (last > size) last = size;

        sum = 32'd0;
        for (int i = start; i < last; i += 2) begin
            word = (i + 1 < last) ? {16'd0, q[i], q[i+1]} : {16'd0, q[i], 8'h00};
            sum  = sum + word;
        end
        while (sum[31:16] != 16'd0)
            sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};

        return sum[15:0];
    endfunction

    // Compare two byte streams; returns 1 on match. On mismatch, first_diff is
    // set to the index of the first differing byte (-1 when lengths differ only).
    function automatic bit bytes_equal(const ref byte unsigned a[],
                                       const ref byte unsigned b[],
                                       output int first_diff);
        first_diff = -1;
        if (a.size() != b.size()) return 1'b0;
        foreach (a[i]) begin
            if (a[i] != b[i]) begin
                first_diff = i;
                return 1'b0;
            end
        end
        return 1'b1;
    endfunction

    // Render a byte stream as hex for log messages. Truncates past max_bytes.
    function automatic string bytes2str(const ref byte unsigned q[],
                                        input int max_bytes = 64);
        string s;
        int    size;
        int    n;

        s    = "";
        size = q.size();
        n    = (size < max_bytes) ? size : max_bytes;

        for (int i = 0; i < n; i++)
            s = {s, $sformatf("%02x", q[i]), ((i % 16 == 15) ? "\n  " : " ")};
        if (size > n)
            s = {s, $sformatf("... (%0d more bytes)", size - n)};
        return s;
    endfunction

endpackage : mqnic_vrf_pkg
