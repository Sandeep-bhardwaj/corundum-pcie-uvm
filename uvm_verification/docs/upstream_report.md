# Corundum upstream report — draft for review

Three independent issues found by a SystemVerilog/UVM verification effort on
`mqnic_core_pcie_us` and its submodules. Each section below is written to be
filed as its own GitHub issue. Line numbers refer to the tree this project
verified (`fpga/lib/pcie/rtl/`, `fpga/common/rtl/`); the code is quoted so it
can be found if lines have moved.

Status of each issue in this project: reproduced in simulation (Vivado xsim
2026.1). The fixes proposed for issues 1 and 2 were applied to a scratch copy of
`dma_if_pcie_rd.v` and the full read-engine regression was re-run: 20/20 tests
pass, including the two reproducers, which fail on the shipped RTL.

---

## Issue 1 — `dma_if_pcie_rd`: completion timeout (and FLR) reported by the hard IP is dropped as an unexpected completion; the read operation never completes

### Summary

When the PCIe core reports a completion timeout, `dma_if_pcie_rd` discards the
report before reaching its timeout handling. The read's tag is never retired,
the descriptor never receives a status, and the engine hangs instead of
returning `DMA_ERROR_TIMEOUT`. The same applies to FLR-terminated requests.

### Details

`dma_if_pcie_rd` has no internal timer; the only path to `DMA_ERROR_TIMEOUT` is
an inbound completion whose error sideband is `PCIE_ERROR_TIMEOUT`:

```verilog
// dma_if_pcie_rd.v:1117
end else if (rx_cpl_tlp_error == PCIE_ERROR_TIMEOUT) begin
    // timeout, handle as uncorrectable (6.2.3.2.4.4)
    status_error_uncor_next = 1'b1;
    status_fifo_error_next = DMA_ERROR_TIMEOUT;
```

That report carries no data. On UltraScale, `pcie_us_if_rc` turns an RC
descriptor with a dword count of 0 into a no-data 3DW header with SC status and
sets the error sideband from the descriptor's error code
(`pcie_us_if_rc.v:347-350`, `:387`). But an earlier check in
`dma_if_pcie_rd` catches exactly that shape first:

```verilog
// dma_if_pcie_rd.v:1069
if ((rx_cpl_tlp_hdr_cpl_status == CPL_STATUS_SC && rx_cpl_tlp_hdr_fmt != TLP_FMT_3DW_DATA) ||
        ...) begin
    // incorrect completion type, handle as unexpected completion (2.3.2)
    // drop TLP and report correctable error
    status_error_cor_next = 1'b1;
```

So the branch at `:1117` is unreachable for a timeout report, and the branch at
`:1123` (`PCIE_ERROR_FLR`) is unreachable for an FLR report for the same reason.

### Reproduction

Issue a read descriptor and answer its request with a single completion:
status SC, no data (3DW, length 0), `byte_count` = the request length, and
`rx_cpl_tlp_error = PCIE_ERROR_TIMEOUT` (on UltraScale: an RC descriptor with
dword count 0 and error code `4'b1001`). Expected: a read status with
`DMA_ERROR_TIMEOUT`. Observed: `status_error_cor` pulses, no status is ever
returned, and the tag stays active. In upstream's cocotb testbench
(`fpga/lib/pcie/tb/dma_if_pcie_rd`) this is a completion injected with the
timeout error code in place of the data completions.

### Proposed fix

Exclude completions that carry a timeout or FLR report from the
unexpected-completion check, so they reach the existing transfer-terminating
handling:

```diff
-                if ((rx_cpl_tlp_hdr_cpl_status == CPL_STATUS_SC && rx_cpl_tlp_hdr_fmt != TLP_FMT_3DW_DATA) ||
+                if ((rx_cpl_tlp_hdr_cpl_status == CPL_STATUS_SC && rx_cpl_tlp_hdr_fmt != TLP_FMT_3DW_DATA &&
+                        rx_cpl_tlp_error != PCIE_ERROR_TIMEOUT && rx_cpl_tlp_error != PCIE_ERROR_FLR) ||
```

Verified for the timeout case (the read completes with `DMA_ERROR_TIMEOUT`, and
the rest of the read-engine regression is unchanged). The FLR case follows the
same path but was not separately exercised.

---

## Issue 2 — `dma_if_pcie_rd`: with MRRS = 4096, an extra 4 KB read is issued and its data overwrites the destination

### Summary

With `max_read_request_size` = 5 (4096 bytes), a read whose remaining length is
exactly 4096 bytes at a 4 KB-aligned address is not marked as the last request.
The engine then issues a second, unrequested 4096-byte read of the *next* page,
and that completion is written into RAM over data already delivered. This is
silent data corruption, plus a read of host memory no descriptor asked for.

### Details

For a remaining count that fits in MRRS but reaches a 4 KB boundary, the engine
takes the "crosses 4k" path and computes `req_last_tlp` as:

```verilog
// dma_if_pcie_rd.v:675
req_last_tlp = (((req_pcie_addr_reg & 12'hfff) + (req_op_count_reg & 12'hfff)) & 12'hfff) == 0
               && req_op_count_reg >> 12 == 0;
```

For `req_op_count_reg == 4096` at a 4 KB-aligned address, the first term is
true but `req_op_count_reg >> 12 == 0` is false, so the request is not marked
last although it completes the operation. The engine iterates with 0 bytes
remaining; the non-crossing branch then yields `req_dword_count = 0`, and a TLP
length field of 0 means 1024 DWORDs.

Only reachable with MRRS = 4096: at MRRS ≤ 2048 a 4096-byte remainder exceeds
MRRS and takes the other branch. It is triggered by a 4096-byte page-aligned
descriptor, or by any longer one whose remainder is 4096 at a page boundary
(for example 8192 bytes aligned).

### Reproduction

Set `max_read_request_size = 5`, then issue a read of 4096 bytes from a
4 KB-aligned host address. Observed in simulation: the expected 4096-byte read
request, followed by a second 4096-byte read of the following page with no
descriptor outstanding. Its completion was written over the destination: 256
bytes of the delivered data then read back with the next page's contents (zeros
in the test's host memory) instead of the requested data.

### Proposed fix

The request is last exactly when it ends the operation at the page boundary:

```diff
-            req_last_tlp = (((req_pcie_addr_reg & 12'hfff) + (req_op_count_reg & 12'hfff)) & 12'hfff) == 0 && req_op_count_reg >> 12 == 0;
+            req_last_tlp = ({1'b0, req_pcie_addr_reg[11:0]} + req_op_count_reg) == 13'h1000;
```

In this branch `req_op_count_reg ≤ 4096`, so the sum fits in 13 bits; for every
count below 4096 the new expression is equivalent to the old one, and at 4096 it
is true only for an aligned address, which is the missing case. Verified: the
4096-byte and 8192-byte reproducers complete with the correct data and no extra
request, and the rest of the read-engine regression is unchanged.

---

## Issue 3 — Constructs that standards-conformant tools reject (zero-width part-selects, parameter used before declaration)

### Summary

In the shipped configuration (one TLP segment, one port) several modules
elaborate a zero-width part-select or use a parameter before it is declared.
Vivado accepts both; slang and VCS reject them. The fixes below are behaviour-
neutral and are what this project carries locally.

### 3a. Zero-width part-selects

`SEG_SEL_WIDTH = $clog2(N)` and `CL_PORTS = $clog2(PORTS)` are 0 when N or PORTS
is 1, and a `+:` select of width 0 follows. IEEE 1800 requires a positive width
(slang: "value must be positive"; VCS: IRIPS).

| file | definition | zero-width use |
|---|---|---|
| `pcie_tlp_fifo_raw.v` | `:51` `SEG_SEL_WIDTH = $clog2(OUT_TLP_SEG_COUNT)` | `:450` `seg_mem_wr_sel[cur_seg*SEG_SEL_WIDTH +: SEG_SEL_WIDTH]` |
| `pcie_tlp_fifo.v` | `:106` `SEG_SEL_WIDTH = $clog2(INT_TLP_SEG_COUNT)` | passed down to `pcie_tlp_fifo_raw` as an explicit override (`:155`), so flooring the child's default alone does not help |
| `mqnic_rx_queue_map.v` | `:109` `CL_PORTS = $clog2(PORTS)` | `:259` `indir_tbl_index_reg[INDIR_TBL_ADDR_WIDTH +: CL_PORTS]` (under a run-time `if (PORTS > 1)`, so still elaborated) |

Suggested fix: floor the width at 1, e.g.
`$clog2(N) > 0 ? $clog2(N) : 1`. This costs one unused bit and changes no
behaviour (every use is masked when N or PORTS is 1).

If this is done, apply it consistently to modules that size wires from the
same expression and connect them to these ports — `pcie_us_if_cc.v:86` and
`pcie_us_if_rq.v:136` declare their own `SEG_SEL_WIDTH = $clog2(INT_TLP_SEG_COUNT)`
for the FIFO's offset/count signals. In this project, flooring only the FIFO
left `pcie_us_if_cc`'s `[-1:0]` offset wire mismatched against a 1-bit port.
The same `$clog2` pattern also appears in `pcie_tlp_demux.v`, `pcie_tlp_mux.v`,
`pcie_tlp_fifo_mux.v`, `dma_ram_demux_{rd,wr}.v`, `dma_if_desc_mux.v`,
`pcie_s10_if_tx.v` and `pcie_ptile_if_tx.v`; those were not part of the
verified configuration and were not checked for zero-width uses.

### 3b. Parameter used in the port list before its declaration

`mqnic_interface_tx.v` and `mqnic_interface_rx.v` use `DMA_CLIENT_LEN_WIDTH` in
the port list (`mqnic_interface_tx.v:87`, `:188`) but declare it in the module
body (`:192`; in `mqnic_interface_rx.v`, used at `:215` and declared at `:219`). Verilog-2001 requires declaration
first. Moving it into the parameter list after `DMA_LEN_WIDTH`, with the same
default, is a no-op functionally.

### 3c. (Optional, simulator compatibility) narrow address into a wider port

`mqnic_core.v` connects the `AXIL_CSR_ADDR_WIDTH`-wide `ctrl_reg_{rd,wr}_addr`
to `mqnic_ptp` and `mqnic_rb_clk_info` instances built with the wider
`REG_ADDR_WIDTH = AXIL_CTRL_ADDR_WIDTH` (`:844`, `:850`, `:900`, `:906`). This
is legal — the standard zero-extends — and is not a bug. Vivado xsim 2026.1,
however, leaves the upper bits at Z (VRFC 10-3091), so in xsim the PHC and
clock-info register blocks never respond. An explicit zero-extension,
`{{(AXIL_CTRL_ADDR_WIDTH-AXIL_CSR_ADDR_WIDTH){1'b0}}, ctrl_reg_rd_addr}`, makes
the RTL simulate correctly on xsim at no cost. Offered as a convenience only.
