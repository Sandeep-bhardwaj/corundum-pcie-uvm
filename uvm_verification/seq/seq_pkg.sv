// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_seq_pkg - sequence library package
//
// Implements : VERIFICATION_STRATEGY.md  §12 (sequence library)
// Introduced : Step 0 (infrastructure)
//
// Compile order: mqnic_vrf_pkg -> <uvc packages> -> mqnic_seq_pkg
//
// Step 0 contains the sequence bases only. Driver-model sequences (§12.2) are
// added at Step 7 and traffic generators at Step 8.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package mqnic_seq_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;

    `include "mqnic_base_seq.sv"

endpackage : mqnic_seq_pkg
