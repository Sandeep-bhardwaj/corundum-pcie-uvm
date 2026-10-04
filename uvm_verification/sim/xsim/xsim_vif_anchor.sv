// SPDX-License-Identifier: BSD-2-Clause-Views
// xsim_vif_anchor - one idle instance of every UVC interface, Vivado xsim only.
//
// Vivado xsim generates code for an interface's tasks and functions only when
// that interface is instantiated in the elaborated design. Every tier compiles
// the full class library (test_pkg includes all tiers), and those classes call
// e.g. vif.init_idle_initiator() on interfaces a given tier's top never
// instantiates - so xelab emits calls to subprograms it never generated and
// the link fails (XSIM 43-3238, "undefined reference to subprog_m_...").
// VCS, Questa and Xcelium do not have this limitation.
//
// Elaborated as a SECOND top alongside tb_top_tier<N>; no tier top changes.
// clk is constant and rst is held high, so nothing here ever toggles and every
// interface assertion (all `disable iff (rst)`) stays disabled.
//
// When a new interface with tasks or functions is added under uvc/, add it here.

`timescale 1ns / 1ps

module xsim_vif_anchor;

    logic clk = 1'b0;
    logic rst = 1'b1;

    axil_if               u_axil          (.clk(clk), .rst(rst));
    axis_if               u_axis          (.clk(clk), .rst(rst));
    csum_cmd_if           u_csum_cmd      (.clk(clk), .rst(rst));
    dma_desc_if           u_dma_desc      (.clk(clk), .rst(rst));
    dma_ram_if            u_dma_ram       (.clk(clk), .rst(rst));
    pcie_tlp_if           u_pcie_tlp      (.clk(clk), .rst(rst));
    pcie_us_axis_if       u_pcie_us_axis  (.clk(clk), .rst(rst));
    pcie_us_cfg_status_if u_pcie_us_cfg   (.clk(clk), .rst(rst));
    queue_op_if           u_queue_op      (.clk(clk), .rst(rst));
    mqnic_reset_if        u_reset         (.clk(clk));
    dma_if_cfg_if         u_dma_if_cfg    ();
    pcie_us_fc_if         u_pcie_us_fc    ();
    pcie_us_msix_if       u_pcie_us_msix  (.clk(clk), .rst(rst));

endmodule : xsim_vif_anchor
