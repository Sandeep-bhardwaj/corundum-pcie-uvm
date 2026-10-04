// SPDX-License-Identifier: BSD-2-Clause-Views
//
// cg_offload - Tier 1c functional coverage (rx_checksum, rx_hash, tx_checksum)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §14 (Tier 1c)
// Introduced : coverage closure, after the 20-seed regression
//
// Sampled by sb_offload from monitor-observed frames (§14.1).
//
// RX: one sample per frame on the shared ingress stream. What matters to the
// DUTs is the protocol (rx_hash only hashes IPv4, adds ports for TCP/UDP -
// rx_hash.v:186-318) and the length relative to the 32-byte beat: rx_checksum
// pads an odd final byte and must stop mid-beat on the last one.
//
// TX: one sample per tx_checksum command. csum_start's PARITY selects the RTL's
// byte-swap path (tx_checksum.v:292, :354-355); the offset can sit before or
// after the summed region; init is ignored with USE_INIT_VALUE=0 but must still
// not disturb the result.
// -----------------------------------------------------------------------------

`ifndef CG_OFFLOAD_SV
`define CG_OFFLOAD_SV

class cg_offload extends uvm_component;

    `uvm_component_utils(cg_offload)

    localparam int BEAT = 32;

    // rx
    protected int unsigned m_len;
    protected int unsigned m_etype;     // 0 short, 1 ipv4, 2 ipv6, 3 vlan, 4 other
    protected bit [3:0]    m_htype;     // predicted rx_hash type
    // tx
    protected bit          m_en;
    protected int unsigned m_start;
    protected int unsigned m_offset;
    protected bit          m_init_nz;

    // -------------------------------------------------------------------------
    covergroup cg_rx;
        option.per_instance = 1;
        option.name         = "cg_offload_rx";

        cp_len : coverpoint m_len {
            bins below_l3   = {[1:33]};         // too short to carry an IPv4 header
            bins one_to_2b  = {[34:63]};
            bins two_beats  = {64};
            bins two_to_3b  = {[65:95]};
            bins three_b    = {96};
            bins long       = {[97:$]};
        }
        // Position of the last byte within its beat; odd = checksum pad byte.
        cp_tail : coverpoint (m_len % BEAT) {
            bins full_beat = {0};
            bins odd       = {1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31};
            bins even      = {2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30};
        }
        cp_etype : coverpoint m_etype {
            bins ipv4 = {1}; bins ipv6 = {2}; bins vlan = {3}; bins other = {4};
        }
        cp_htype : coverpoint m_htype {
            bins none = {4'b0000}; bins ipv4 = {4'b0001};
            bins tcp  = {4'b0101}; bins udp  = {4'b1001};
            illegal_bins undefined = default;
        }

        x_proto_len : cross cp_htype, cp_len {
            // A hashed L4 header needs >= 38 bytes; header-only IPv4 needs >= 34.
            ignore_bins l4_too_short = binsof(cp_htype) intersect {4'b0101, 4'b1001}
                                    && binsof(cp_len.below_l3);
            ignore_bins v4_too_short = binsof(cp_htype) intersect {4'b0001}
                                    && binsof(cp_len.below_l3);
        }
        x_tail_proto : cross cp_tail, cp_htype;
    endgroup

    // -------------------------------------------------------------------------
    covergroup cg_tx;
        option.per_instance = 1;
        option.name         = "cg_offload_tx";

        cp_en    : coverpoint m_en { bins off = {0}; bins on = {1}; }
        cp_start : coverpoint m_start {
            bins in_eth_hdr = {[0:13]};
            bins l3_start   = {14};
            bins in_l3      = {[15:33]};
            bins l4_or_more = {[34:$]};
        }
        cp_parity : coverpoint m_start[0] { bins even = {0}; bins odd = {1}; }
        cp_offset_pos : coverpoint (m_offset < m_start) {
            bins after_start = {0}; bins before_start = {1};
        }
        cp_init : coverpoint m_init_nz { bins zero = {0}; bins nonzero = {1}; }
        cp_len  : coverpoint m_len {
            bins short_ = {[1:63]}; bins mid = {[64:127]}; bins long_ = {[128:$]};
        }

        x_swap   : cross cp_en, cp_parity, cp_offset_pos;
        x_len_en : cross cp_en, cp_len, cp_parity;
        x_init   : cross cp_en, cp_init;
    endgroup

    // -------------------------------------------------------------------------
    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_rx = new();
        cg_rx.set_inst_name({get_full_name(), ".cg_rx"});
        cg_tx = new();
        cg_tx.set_inst_name({get_full_name(), ".cg_tx"});
    endfunction

    virtual function void sample_rx(const ref byte unsigned frame[], input bit [3:0] htype);
        bit [15:0] et;
        m_len = frame.size();
        if (frame.size() < 14) m_etype = 0;
        else begin
            et = {frame[12], frame[13]};
            case (et)
                16'h0800: m_etype = 1;
                16'h86DD: m_etype = 2;
                16'h8100: m_etype = 3;
                default:  m_etype = 4;
            endcase
        end
        m_htype = htype;
        cg_rx.sample();
    endfunction

    virtual function void sample_tx(int unsigned len, bit en, int unsigned start,
                                    int unsigned offset, bit [15:0] init);
        m_len = len; m_en = en; m_start = start; m_offset = offset;
        m_init_nz = (init != 0);
        cg_tx.sample();
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("rx coverage %.2f%%, tx coverage %.2f%%",
                      cg_rx.get_coverage(), cg_tx.get_coverage()), UVM_LOW)
    endfunction

endclass : cg_offload

`endif // CG_OFFLOAD_SV
