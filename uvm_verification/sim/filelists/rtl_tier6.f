// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 6 RTL filelist - mqnic_core_pcie_us, THE STRATEGY'S TOP DUT.
// Implements : VERIFICATION_STRATEGY.md  §16.1, §3.1, §5 Tier 6
//
// THE MODULE THE DOCUMENT IS NAMED AFTER. VERIFICATION_STRATEGY.md is titled
// "Corundum mqnic_core_pcie_us - UVM Verification Strategy" and §3.1 marks this
// module TIER 6 DUT. Everything below it has been verified in isolation; this
// is the first configuration in which the whole PCIe host interface exists at
// once.
//
// It is deliberately NOT the board top. §1.3 puts fpga.v out of scope because
// its serial lanes cannot be meaningfully driven, along with the Xilinx hard IP,
// the DDR/HBM controllers and CMAC. mqnic_core_pcie_us is the highest level at
// which the design is still ordinary synchronous RTL.
//
// COMPOSITION: this is exactly the union of Tier 5 and Tier 4d.
//
//     mqnic_core_pcie_us
//       |- pcie_us_if        <- Tier 4d, 12 files
//       \- mqnic_core_pcie   <- Tier 5,  74 files
//
// Both halves are verified. What is new here is the SEAM between them: the
// generic TLP interface that Tier 5 drives directly is, in this configuration,
// produced and consumed by the Xilinx shims instead. A disagreement about
// straddling, byte enables or sequence numbers between two independently
// correct halves can only appear here.
//
// The union is taken by FILE NAME, not by path, so a module that both tiers
// carry (arbiter, priority_encoder, the TLP FIFOs) appears exactly once.

+incdir+../../../fpga/common/rtl
+incdir+../../../fpga/lib/pcie/rtl
+incdir+../../../fpga/lib/eth/lib/axis/rtl

../../../fpga/common/rtl/mqnic_core_pcie_us.v
../../rtl_patched/pcie_tlp_fifo_raw.v
../../rtl_patched/pcie_tlp_fifo.v
../../../fpga/common/rtl/mqnic_core_pcie.v
../../../fpga/lib/pcie/rtl/axis_arb_mux.v
../../../fpga/lib/pcie/rtl/dma_if_pcie.v
../../rtl_patched/mqnic_core.v
../../../fpga/lib/pcie/rtl/pcie_axil_master.v
../../../fpga/lib/pcie/rtl/pcie_msix.v
../../../fpga/lib/pcie/rtl/pulse_merge.v
../../../fpga/common/rtl/stats_dma_if_pcie.v
../../../fpga/common/rtl/stats_pcie_if.v
../../../fpga/lib/pcie/rtl/arbiter.v
../../../fpga/lib/axi/rtl/axil_crossbar.v
../../../fpga/lib/axi/rtl/axil_reg_if.v
../../../fpga/lib/pcie/rtl/dma_if_mux.v
../../../fpga/lib/pcie/rtl/dma_if_pcie_rd.v
../../../fpga/lib/pcie/rtl/dma_if_pcie_wr.v
../../../fpga/lib/pcie/rtl/irq_rate_limit.v
../../../fpga/common/rtl/mqnic_interface.v
../../../fpga/common/rtl/mqnic_ptp.v
../../../fpga/common/rtl/mqnic_rb_clk_info.v
../../../fpga/lib/eth/rtl/ptp_td_leaf.v
../../../fpga/common/rtl/stats_collect.v
../../../fpga/common/rtl/stats_counter.v
../../../fpga/common/rtl/stats_dma_latency.v
../../../fpga/common/rtl/stats_pcie_tlp.v
../../../fpga/lib/axi/rtl/axil_crossbar_rd.v
../../../fpga/lib/axi/rtl/axil_crossbar_wr.v
../../../fpga/lib/axi/rtl/axil_reg_if_rd.v
../../../fpga/lib/axi/rtl/axil_reg_if_wr.v
../../../fpga/lib/eth/lib/axis/rtl/axis_fifo.v
../../../fpga/common/rtl/cpl_op_mux.v
../../../fpga/common/rtl/cpl_queue_manager.v
../../../fpga/common/rtl/cpl_write.v
../../../fpga/common/rtl/desc_fetch.v
../../../fpga/common/rtl/desc_op_mux.v
../../../fpga/lib/pcie/rtl/dma_if_mux_rd.v
../../../fpga/lib/pcie/rtl/dma_if_mux_wr.v
../../rtl_patched/mqnic_interface_rx.v
../../rtl_patched/mqnic_interface_tx.v
../../../fpga/common/rtl/mqnic_port.v
../../../fpga/common/rtl/mqnic_ptp_clock.v
../../../fpga/common/rtl/mqnic_tx_scheduler_block_rr.v
../../../fpga/lib/pcie/rtl/priority_encoder.v
../../../fpga/common/rtl/queue_manager.v
../../../fpga/common/rtl/rx_fifo.v
../../../fpga/common/rtl/tx_fifo.v
../../../fpga/lib/axi/rtl/axil_crossbar_addr.v
../../../fpga/lib/axi/rtl/axil_register_rd.v
../../../fpga/lib/axi/rtl/axil_register_wr.v
../../../fpga/lib/eth/lib/axis/rtl/axis_fifo_adapter.v
../../../fpga/lib/pcie/rtl/dma_client_axis_sink.v
../../../fpga/lib/pcie/rtl/dma_client_axis_source.v
../../../fpga/lib/pcie/rtl/dma_if_desc_mux.v
../../../fpga/lib/pcie/rtl/dma_psdpram.v
../../../fpga/lib/pcie/rtl/dma_ram_demux_rd.v
../../../fpga/lib/pcie/rtl/dma_ram_demux_wr.v
../../../fpga/common/rtl/mqnic_egress.v
../../../fpga/common/rtl/mqnic_ingress.v
../../../fpga/common/rtl/mqnic_port_rx.v
../../../fpga/common/rtl/mqnic_port_tx.v
../../../fpga/lib/eth/rtl/ptp_td_phc.v
../../../fpga/common/rtl/rx_engine.v
../../../fpga/common/rtl/tx_engine.v
../../../fpga/common/rtl/tx_scheduler_rr.v
../../../fpga/lib/eth/lib/axis/rtl/axis_async_fifo.v
../../../fpga/lib/eth/lib/axis/rtl/axis_async_fifo_adapter.v
../../../fpga/lib/eth/lib/axis/rtl/axis_pipeline_fifo.v
../../../fpga/common/rtl/mqnic_l2_egress.v
../../../fpga/common/rtl/mqnic_l2_ingress.v
../../rtl_patched/mqnic_rx_queue_map.v
../../../fpga/common/rtl/rx_checksum.v
../../../fpga/common/rtl/rx_hash.v
../../../fpga/common/rtl/tx_checksum.v
../../../fpga/lib/pcie/rtl/pcie_us_if.v
../../../fpga/lib/pcie/rtl/pcie_us_if_rc.v
../../../fpga/lib/pcie/rtl/pcie_us_if_rq.v
../../../fpga/lib/pcie/rtl/pcie_us_if_cq.v
../../../fpga/lib/pcie/rtl/pcie_us_if_cc.v
../../../fpga/lib/pcie/rtl/pcie_us_cfg.v
../../../fpga/lib/pcie/rtl/pcie_tlp_fifo_mux.v
../../../fpga/lib/pcie/rtl/pcie_tlp_fc_count.v

// -----------------------------------------------------------------------------
// pcie_tlp_fifo, pcie_tlp_fifo_raw, mqnic_interface_tx/rx, mqnic_core and
// mqnic_rx_queue_map come from rtl_patched/, NOT from fpga/. One line differs in
// each; see those files' headers and bugs 13/24 in docs/bringup_log.md. Every
// other RTL file here is verbatim.
// -----------------------------------------------------------------------------
