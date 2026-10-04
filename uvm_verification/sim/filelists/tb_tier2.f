// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 2 testbench filelist - segmented memory.
//
// NO dut_wrapper_queue_manager.sv and NO sva_queue_manager.sv here. Both are
// Tier 1a-specific: the wrapper instantiates queue_manager, and the SVA file
// contains `bind queue_manager ...`. queue_manager.v is not in rtl_tier2.f, so
// including them leaves a stray top-level module and makes VCS reject the bind
// with SVA-COBMMI "Can only bind to modules or instances".
//
// A tb filelist must only carry wrappers and bind files whose RTL is present in
// the matching rtl_*.f. sim/scripts/check_filelists.py enforces this.
// Implements : VERIFICATION_STRATEGY.md  §16.1

+incdir+../../uvc/common
+incdir+../../uvc/axil
+incdir+../../uvc/queue_op
+incdir+../../uvc/axis
+incdir+../../uvc/csum_cmd
+incdir+../../uvc/dma_ram
+incdir+../../uvc/dma_desc
+incdir+../../uvc/pcie_tlp
+incdir+../../uvc/pcie_us_axis
+incdir+../../seq
+incdir+../../seq/driver_model
+incdir+../../ral
+incdir+../../env
+incdir+../../model
+incdir+../../cov
+incdir+../../tests
+incdir+../../tests/tier1a
+incdir+../../tests/tier1b
+incdir+../../tests/tier1c
+incdir+../../tests/tier2
+incdir+../../tests/tier3
+incdir+../../tests/tier3b
+incdir+../../tests/tier3c
+incdir+../../tests/tier4a
+incdir+../../tests/tier4b
+incdir+../../tests/tier4c
+incdir+../../tests/tier4d
+incdir+../../tests/tier5
+incdir+../../tests/tier6
+incdir+../../tb
+incdir+../../sva

../../uvc/common/mqnic_vrf_pkg.sv
../../uvc/common/mqnic_reset_if.sv
../../uvc/common/dma_if_cfg_if.sv
../../uvc/common/pcie_us_fc_if.sv
../../uvc/common/pcie_us_cfg_status_if.sv
../../uvc/common/pcie_us_msix_if.sv
../../seq/seq_pkg.sv
../../uvc/axil/axil_if.sv
../../uvc/axil/axil_pkg.sv
../../uvc/queue_op/queue_op_if.sv
../../uvc/queue_op/queue_op_pkg.sv
../../uvc/axis/axis_if.sv
../../uvc/axis/axis_pkg.sv
../../uvc/csum_cmd/csum_cmd_if.sv
../../uvc/csum_cmd/csum_cmd_pkg.sv
../../uvc/pcie_tlp/pcie_tlp_if.sv
../../uvc/pcie_tlp/pcie_tlp_pkg.sv
../../uvc/pcie_us_axis/pcie_us_axis_if.sv
../../uvc/pcie_us_axis/pcie_us_axis_pkg.sv
../../uvc/dma_ram/dma_ram_if.sv
../../uvc/dma_ram/dma_ram_pkg.sv
../../uvc/dma_desc/dma_desc_if.sv
../../uvc/dma_desc/dma_desc_pkg.sv
../../ral/mqnic_ral_pkg.sv
../../model/model_pkg.sv
../../env/env_pkg.sv
../../tests/test_pkg.sv
../../tb/tb_top_tier2.sv
