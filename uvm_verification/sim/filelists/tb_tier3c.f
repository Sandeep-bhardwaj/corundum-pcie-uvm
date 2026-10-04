// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 3c testbench filelist - full PCIe DMA interface.
//
// BOTH bind files are listed: dma_if_pcie instantiates both engines, so
// both binds have targets and both sets of assertions run against the
// integrated design without modification.
// Implements : VERIFICATION_STRATEGY.md  §16.1
//
// sva_dma_if_pcie.sv IS included here because dma_if_pcie_rd.v is present in
// rtl_tier3.f - its `bind dma_if_pcie_rd` therefore has a target. Conversely
// sva_queue_manager.sv is NOT, for the same reason it is absent from Tier 2:
// queue_manager.v is not in this tier's RTL and VCS rejects a bind with no
// target (SVA-COBMMI). sim/scripts/check_filelists.py enforces the rule.
//
// COMPILE ORDER IS LOAD-BEARING. slang resolves packages in any order; VCS does
// not. Packages must appear before the packages that import them:
//   mqnic_vrf_pkg -> seq_pkg -> <uvc pkgs> -> model_pkg -> env_pkg -> test_pkg

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
../../sva/sva_dma_if_pcie.sv
../../sva/sva_dma_if_pcie_wr.sv
../../tb/tb_top_tier3c.sv
