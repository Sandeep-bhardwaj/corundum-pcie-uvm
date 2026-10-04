// SPDX-License-Identifier: BSD-2-Clause-Views
// Common testbench filelist.
// Implements : VERIFICATION_STRATEGY.md  §16.1
//
// COMPILE ORDER IS STRICT. VCS, Questa and Xcelium resolve package imports in
// FILE ORDER - a package must be compiled before anything that imports it.
// (slang resolves order-independently, so a wrong order elaborates cleanly here
// and fails on a real simulator. Do not reorder without re-checking.)
//
//   mqnic_vrf_pkg -> mqnic_seq_pkg -> axil_pkg -> queue_op_pkg -> model_pkg
//   -> mqnic_env_pkg -> mqnic_test_pkg -> wrappers -> tops
//
// Paths are relative to this file's directory.

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

// ---- level 0: types, constants, pure functions (no UVM dependency) ---------
../../uvc/common/mqnic_vrf_pkg.sv
../../uvc/common/mqnic_reset_if.sv
../../uvc/common/dma_if_cfg_if.sv
../../uvc/common/pcie_us_fc_if.sv
../../uvc/common/pcie_us_cfg_status_if.sv
../../uvc/common/pcie_us_msix_if.sv

// ---- level 1: sequence bases (UVC sequences extend mqnic_base_seq) ---------
../../seq/seq_pkg.sv

// ---- level 2: UVC interfaces, then UVC packages ----------------------------
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

// ---- level 3: reference models ---------------------------------------------
../../ral/mqnic_ral_pkg.sv
../../model/model_pkg.sv

// ---- level 4: environment, then tests --------------------------------------
../../env/env_pkg.sv
../../tests/test_pkg.sv

// ---- level 5: assertions (bind into the RTL; must precede the TB top) ------
../../sva/sva_queue_manager.sv

// ---- level 6: DUT wrappers and TB tops -------------------------------------
../../tb/dut_wrapper_queue_manager.sv
../../tb/tb_top_tier1a.sv
