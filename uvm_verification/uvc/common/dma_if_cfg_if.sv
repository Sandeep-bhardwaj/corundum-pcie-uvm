// SPDX-License-Identifier: BSD-2-Clause-Views
//
// dma_if_cfg_if - the dma_if_pcie configuration pins
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 3, §14.3
// Introduced : Step 5 (Tier 3); reused at Tiers 3b, 3c and 5
//
// WHY THIS EXISTS AS AN INTERFACE. max_read_request_size, rcb_128b and
// ext_tag_enable are STATIC INPUT PINS on dma_if_pcie_rd, but §14.3 crosses
// length and alignment against MRRS and RCB - so a test has to be able to change
// them. Tying them to constants in the top would leave t3_mps_mrrs_matrix,
// t3_rcb_64_128 and t3_ext_tag_off documenting configurations they cannot
// actually reach, and the cross would only ever be filled on one slice.
//
// These are quasi-static: a test sets them while the DUT is idle, not
// mid-operation. There is no clocking block for that reason - a clocked driver
// would imply they change with traffic, which is not how real configuration
// space works.
//
// The models (ref_dma, mqnic_rc_model) must be kept in step with whatever is
// driven here. tier3_base_test.set_config() is the single place that does both,
// so they cannot drift - the same discipline as cli_preload() at Tier 2.
// -----------------------------------------------------------------------------

`ifndef DMA_IF_CFG_IF_SV
`define DMA_IF_CFG_IF_SV

`timescale 1ns / 1ps

interface dma_if_cfg_if;

    logic       enable;
    logic       ext_tag_enable;
    logic       rcb_128b;
    logic [2:0] max_read_request_size;
    logic [2:0] max_payload_size;
    logic [15:0] requester_id;

    // Golden configuration, per STRATEGY §2.3: 512-byte MRRS, 64-byte RCB,
    // extended tags on. Every test starts here and changes only what it names.
    task automatic init_golden();
        enable                = 1'b1;
        ext_tag_enable        = 1'b1;
        rcb_128b              = 1'b0;
        max_read_request_size = 3'd2;      // 128 << 2 = 512 bytes
        max_payload_size      = 3'd1;      // 128 << 1 = 256 bytes
        requester_id          = 16'h0200;
    endtask

endinterface : dma_if_cfg_if

`endif // DMA_IF_CFG_IF_SV
