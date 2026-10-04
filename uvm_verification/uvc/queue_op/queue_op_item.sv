// SPDX-License-Identifier: BSD-2-Clause-Views
//
// queue_op_item / queue_op_cfg
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.8
// Introduced : Step 1 (Tier 1a)
// -----------------------------------------------------------------------------

`ifndef QUEUE_OP_ITEM_SV
`define QUEUE_OP_ITEM_SV

// Which DUT the agent is attached to. Selects the meaning of resp_aux /
// resp_blocked and whether the notify channel has a ready.
typedef enum {
    QOP_DEQUEUE,   // queue_manager     : aux=block_size, blocked=empty, doorbell pulse
    QOP_ENQUEUE    // cpl_queue_manager : aux=event,      blocked=full,  event handshake
} queue_op_flavor_e;

typedef enum {
    QOP_REQ,       // driven  : dequeue/enqueue request
    QOP_RESP,      // observed: response
    QOP_COMMIT,    // driven  : commit of a previously returned op_tag
    QOP_NOTIFY     // observed: doorbell or event
} queue_op_kind_e;


class queue_op_item extends uvm_sequence_item;

    rand queue_op_kind_e kind;

    // ---- request / common ---------------------------------------------------
    rand bit [31:0] queue;
    rand bit [15:0] tag;

    // ---- response (monitor fills) -------------------------------------------
    bit [31:0]      ptr;
    bit             phase;
    bit [63:0]      addr;
    bit [63:0]      aux;       // block_size (dequeue) | event (enqueue)
    bit [31:0]      cpl;       // dequeue flavour only
    bit [15:0]      op_tag;
    bit             blocked;   // empty (dequeue) | full (enqueue)
    bit             error;

    // ---- commit -------------------------------------------------------------
    rand bit [15:0] commit_op_tag;

    // ---- notify (monitor fills) ---------------------------------------------
    bit [31:0]      notify_source;
    bit [63:0]      notify_data;

    // ---- timing -------------------------------------------------------------
    rand int unsigned delay;

    time            stamp;

    // Set by queue_op_driver once the item's handshake has completed. The
    // driver releases the sequencer as soon as it has QUEUED an item (so the
    // request and commit channels can run concurrently), so a sequence must
    // call wait_driven() after finish_item() to mean "the DUT has taken it".
    bit             driven;

    task wait_driven();
        wait (driven);
    endtask

    `uvm_object_utils_begin(queue_op_item)
        `uvm_field_enum(queue_op_kind_e, kind, UVM_ALL_ON)
        `uvm_field_int (queue,                 UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (tag,                   UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (ptr,                   UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (phase,                 UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (addr,                  UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (aux,                   UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (cpl,                   UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (op_tag,                UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (blocked,               UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (error,                 UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (commit_op_tag,         UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (notify_source,         UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (delay,                 UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
    `uvm_object_utils_end

    constraint c_delay {
        delay dist { 0 := 70, [1:3] := 20, [4:15] := 10 };
    }

    function new(string name = "queue_op_item");
        super.new(name);
    endfunction

    virtual function string convert2string();
        case (kind)
            QOP_REQ:    return $sformatf("REQ    queue=%0d tag=0x%0h", queue, tag);
            QOP_COMMIT: return $sformatf("COMMIT op_tag=0x%0h", commit_op_tag);
            QOP_RESP:   return $sformatf({"RESP   queue=%0d tag=0x%0h op_tag=0x%0h ptr=%0d ",
                                          "phase=%0b addr=0x%0h aux=0x%0h cpl=%0d ",
                                          "blocked=%0b error=%0b"},
                                         queue, tag, op_tag, ptr, phase, addr, aux,
                                         cpl, blocked, error);
            QOP_NOTIFY: return $sformatf("NOTIFY source=%0d data=0x%0h",
                                         notify_source, notify_data);
            default:    return "?";
        endcase
    endfunction

endclass : queue_op_item


class queue_op_cfg extends uvm_object;

    mqnic_agent_mode_e mode   = MODE_ACTIVE_MASTER;
    queue_op_flavor_e  flavor = QOP_DEQUEUE;

    // Real widths, published by the DUT wrapper.
    // Defaults match the Tier 1a golden config (STRATEGY §2.3).
    int unsigned queue_width  = 13;
    int unsigned tag_width    = 8;
    int unsigned op_tag_width = 8;
    int unsigned ptr_width    = 16;
    int unsigned addr_width   = 64;
    int unsigned aux_width    = 2;    // LOG_BLOCK_SIZE_WIDTH for queue_manager
    int unsigned cpl_width    = 8;
    int unsigned op_table_size = 32;

    // The dequeue flavour's doorbell is a pulse with NO ready. Setting this
    // wrong makes the monitor miss doorbells (STRATEGY §7.8).
    bit notify_has_ready = 1'b0;

    mqnic_bp_profile_e bp_profile = BP_RANDOM;
    bit                enable_coverage = 1'b1;

    `uvm_object_utils_begin(queue_op_cfg)
        `uvm_field_enum(mqnic_agent_mode_e, mode,   UVM_ALL_ON)
        `uvm_field_enum(queue_op_flavor_e, flavor,  UVM_ALL_ON)
        `uvm_field_int (queue_width,                UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (tag_width,                  UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (op_tag_width,               UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (ptr_width,                  UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (addr_width,                 UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (aux_width,                  UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (cpl_width,                  UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (op_table_size,              UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (notify_has_ready,           UVM_ALL_ON | UVM_BIN)
        `uvm_field_enum(mqnic_bp_profile_e, bp_profile, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "queue_op_cfg");
        super.new(name);
    endfunction

    // Set every width and the notify behaviour consistently for a flavour.
    // Calling this is strongly preferred over setting notify_has_ready by hand.
    virtual function void apply_flavor(queue_op_flavor_e f);
        flavor = f;
        case (f)
            QOP_DEQUEUE: begin
                notify_has_ready = 1'b0;   // doorbell: bare pulse
                aux_width        = 2;      // LOG_BLOCK_SIZE_WIDTH
            end
            QOP_ENQUEUE: begin
                notify_has_ready = 1'b1;   // event: valid/ready
                aux_width        = 32;     // EVENT_WIDTH
                cpl_width        = 0;      // no cpl field on the enqueue side
            end
            default: ;
        endcase
    endfunction

    function int unsigned queue_count();
        return 1 << queue_width;
    endfunction

    function bit [31:0] queue_mask();
        return (queue_width >= 32) ? 32'hFFFF_FFFF : ((32'd1 << queue_width) - 32'd1);
    endfunction

    function bit [15:0] op_tag_mask();
        return (op_tag_width >= 16) ? 16'hFFFF : ((16'd1 << op_tag_width) - 16'd1);
    endfunction

    function bit is_active();
        return (mode != MODE_PASSIVE);
    endfunction

endclass : queue_op_cfg

`endif // QUEUE_OP_ITEM_SV
