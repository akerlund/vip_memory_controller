////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Åkerlund
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

// -----------------------------------------------------------------------------
// mc_tb_pkg
//
// Shared types and local parameters for the executable vip_mc example harness.
// The example is intentionally small, but it now drives the owned AXI4 front-
// ends end-to-end against a real vip_dram instance.
// -----------------------------------------------------------------------------
`ifndef VIP_MC_TB_PKG
`define VIP_MC_TB_PKG

package mc_tb_pkg;

  `include "uvm_macros.svh"
  import uvm_pkg::*;

  // bool_t/TRUE/FALSE come from vip_mc's own vip_mc_types_pkg (imported below).
  // Peer agents expose vip_mem_types_pkg::bool_t on their cfg, so cross-agent
  // assignments use an explicit vip_mem_types_pkg:: qualifier.
  import vip_memory_pkg::*;
  import vip_dram_types_pkg::*;
  import vip_dram_timing_pkg::*;
  import vip_dram_addr_pkg::*;
  import vip_dram_pkg::*;
  import vip_axi4_types_pkg::*;
  import vip_axi4_agent_pkg::*;
  import vip_chi_types_pkg::*;
  import vip_chi_agent_pkg::*;
  import clk_rst_pkg::*;
  import vip_mc_axi4_types_pkg::*;
  import vip_mc_types_pkg::*;
  import vip_mc_pkg::*;

  // The report helpers are package-scoped because the environments below are
  // package classes; compilation-unit functions are not visible from here.
  `include "mc_chi_check_report.svh"

  localparam vip_dram_cfg_t DRAM_CFG_C = VIP_DRAM_CFG_DEFAULT_C;

  localparam vip_mc_axi4_cfg_t VIP_MC_AXI4_CFG_C = '{
    AWID_WIDTH_P    : 4,
    ARID_WIDTH_P    : 4,
    ADDR_WIDTH_P    : DRAM_CFG_C.ADDR_WIDTH_P,
    WDATA_BYTES_P   : DRAM_CFG_C.ROW_BYTES_P,
    RDATA_BYTES_P   : DRAM_CFG_C.ROW_BYTES_P,
    AWUSER_WIDTH_P  : 1,
    WUSER_WIDTH_P   : 1,
    BUSER_WIDTH_P   : 1,
    ARUSER_WIDTH_P  : 1,
    RUSER_WIDTH_P   : 1
  };

  localparam int N_PORTS_C = 2;

  localparam vip_mc_port_cfg_t PORTS_C [N_PORTS_C] = '{
    '{proto: VIP_MC_PROTO_AXI4_E, axi4: VIP_MC_AXI4_CFG_C, chi: '0},
    '{proto: VIP_MC_PROTO_AXI4_E, axi4: VIP_MC_AXI4_CFG_C, chi: '0}
  };

  localparam vip_axi4_cfg_t VIP_AXI4_AGENT_CFG_C = '{
    AWID_WIDTH_P    : VIP_MC_AXI4_CFG_C.AWID_WIDTH_P,
    ARID_WIDTH_P    : VIP_MC_AXI4_CFG_C.ARID_WIDTH_P,
    ADDR_WIDTH_P    : VIP_MC_AXI4_CFG_C.ADDR_WIDTH_P,
    WDATA_BYTES_P   : VIP_MC_AXI4_CFG_C.WDATA_BYTES_P,
    RDATA_BYTES_P   : VIP_MC_AXI4_CFG_C.RDATA_BYTES_P,
    AWUSER_WIDTH_P  : VIP_MC_AXI4_CFG_C.AWUSER_WIDTH_P,
    WUSER_WIDTH_P   : VIP_MC_AXI4_CFG_C.WUSER_WIDTH_P,
    BUSER_WIDTH_P   : VIP_MC_AXI4_CFG_C.BUSER_WIDTH_P,
    ARUSER_WIDTH_P  : VIP_MC_AXI4_CFG_C.ARUSER_WIDTH_P,
    RUSER_WIDTH_P   : VIP_MC_AXI4_CFG_C.RUSER_WIDTH_P
  };

  typedef vip_mc_env_cfg #(DRAM_CFG_C, N_PORTS_C, PORTS_C) env_cfg_t;
  typedef vip_mc_axi4_vif_holder #(VIP_MC_AXI4_CFG_C)       axi4_vif_holder_t;

  // ---------------------------------------------------------------------------
  // CHI slice (tc_mc_chi_*). A stock vip_chi RN-I manager drives ReadNoSnp /
  // WriteNoSnp traffic into a self-contained one-port CHI vip_mc instance built
  // by the CHI test env, bridged to vip_mc's owned SN interface by
  // vip_mc_chi_connect in tb_top. These cfgs/types are shared by tb_top (which
  // instantiates the interfaces) and the CHI test env (which builds the agents).
  //
  // Flit types use the SUPERSET vip_chi_types (not vip_chi_types_d): the SN
  // interface derives its flit shape from vip_chi_types, so the RN-I agent must
  // use the same family for the connector cross-wire to be a same-type assign.
  // DATA_BYTES_P must equal the DRAM row width (one CHI DAT beat maps 1:1 to one
  // DRAM row word here), and ADDR_WIDTH_P matches the device.
  localparam vip_chi_cfg_t VIP_CHI_CFG_C = '{
    ISSUE_P         : VIP_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : DRAM_CFG_C.ADDR_WIDTH_P,
    DATA_BYTES_P    : DRAM_CFG_C.ROW_BYTES_P,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  typedef vip_chi_types #(VIP_CHI_CFG_C) chi_types_t;   // superset, matches vip_mc_chi_if
  typedef vip_chi_item  #(VIP_CHI_CFG_C) chi_item_t;

  // vip_mc thin CHI selector mirroring VIP_CHI_CFG_C field-for-field.
  localparam vip_mc_chi_cfg_t VIP_MC_CHI_CFG_C = '{
    issue           : VIP_MC_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : DRAM_CFG_C.ADDR_WIDTH_P,
    DATA_BYTES_P    : DRAM_CFG_C.ROW_BYTES_P,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  localparam int N_CHI_PORTS_C = 1;

  // Single CHI port. Both cfg fields are filled per the vip_mc convention (only
  // .chi is used here since proto == CHI).
  localparam vip_mc_port_cfg_t CHI_PORTS_C [N_CHI_PORTS_C] = '{
    '{proto: VIP_MC_PROTO_CHI_E, axi4: '0, chi: VIP_MC_CHI_CFG_C}
  };

  typedef vip_mc_env_cfg        #(DRAM_CFG_C, N_CHI_PORTS_C, CHI_PORTS_C) chi_env_cfg_t;
  typedef vip_mc_chi_vif_holder #(VIP_MC_CHI_CFG_C)                       chi_vif_holder_t;

  // Aligned, in-range CHI test addresses (row = 64 B), clear of the AXI4 slice's
  // low-address traffic and the DECERR window below.
  localparam chi_item_t::addr_t CHI_WRITE_READ_ADDR_C = chi_item_t::addr_t'('h0001_0000);
  localparam chi_item_t::addr_t CHI_READ_ADDR_C       = chi_item_t::addr_t'('h0002_0000);
  localparam chi_item_t::addr_t CHI_PTL_ADDR_C        = chi_item_t::addr_t'('h0004_0000);
  localparam chi_item_t::addr_t CHI_COMBINED_ADDR_C   = chi_item_t::addr_t'('h0006_0000);

  // MC-owned DECERR window the CHI env installs; the decerr test targets it and
  // every other test address stays clear of it.
  localparam longint unsigned   CHI_DECERR_LO_C   = 'h0003_0000;
  localparam longint unsigned   CHI_DECERR_HI_C   = 'h0003_FFFF;
  localparam chi_item_t::addr_t CHI_DECERR_ADDR_C = chi_item_t::addr_t'('h0003_0000);

  // ---------------------------------------------------------------------------
  // CHI-E variant of the slice (the D/E matrix). Identical geometry to the
  // CHI-D family above but issue = E, which both the vip_mc SN front-end and the
  // stock vip_chi RN-I manager key on to enable the E-only opcodes
  // WriteNoSnpZero and ReadNoSnpSep. The CHI test env/base test are parameterized
  // over the (vip_chi, vip_mc) cfg pair, so the same env builds either family.
  // Only one test runs per simv, so the CHI-E interface set in tb_top shares the
  // CHI-D config_db keys -- uvm_config_db separates entries by their vif type.
  // ---------------------------------------------------------------------------
  localparam vip_chi_cfg_t VIP_CHI_CFG_E_C = '{
    ISSUE_P         : VIP_CHI_ISSUE_E_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : DRAM_CFG_C.ADDR_WIDTH_P,
    DATA_BYTES_P    : DRAM_CFG_C.ROW_BYTES_P,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  typedef vip_chi_types #(VIP_CHI_CFG_E_C) chi_types_e_t;   // superset, matches vip_mc_chi_if
  typedef vip_chi_item  #(VIP_CHI_CFG_E_C) chi_item_e_t;

  // vip_mc thin CHI selector mirroring VIP_CHI_CFG_E_C field-for-field.
  localparam vip_mc_chi_cfg_t VIP_MC_CHI_CFG_E_C = '{
    issue           : VIP_MC_CHI_ISSUE_E_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : DRAM_CFG_C.ADDR_WIDTH_P,
    DATA_BYTES_P    : DRAM_CFG_C.ROW_BYTES_P,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  // E-only test addresses (row-aligned, clear of the CHI-D addresses and the
  // DECERR window). Only one test runs per simv, so these may overlap D windows
  // in principle; distinct values keep the intent legible.
  localparam chi_item_e_t::addr_t CHI_ZERO_ADDR_C = chi_item_e_t::addr_t'('h0005_0000);
  localparam chi_item_e_t::addr_t CHI_SEP_ADDR_C  = chi_item_e_t::addr_t'('h0007_0000);

  // ---------------------------------------------------------------------------
  // Protocol-equivalence suite (tc_mc_equiv_*). One protocol-neutral golden
  // model (mc_equiv_model) and one deterministic program (mc_equiv_program)
  // are shared by three sibling tests -- AXI4, CHI-D, CHI-E -- that each
  // replay the identical logical op list and check every read-back against a
  // fresh model. All three passing is a transitive equivalence proof. Line
  // addresses live below the CHI slice's traffic and clear of the DECERR window.
  // ---------------------------------------------------------------------------
  typedef enum {
    EQ_WRITE_FULL_E,   // full-line write, all byte-enables set
    EQ_WRITE_PTL_E,    // byte-enabled partial write
    EQ_READ_E          // read one line and check against the model
  } eq_op_e;

  typedef struct {
    eq_op_e          op;
    longint unsigned addr;
    int unsigned     nbytes;   // == DRAM_CFG_C.ROW_BYTES_P for every line op
    byte unsigned    data [];  // write payload (empty for reads)
    bit              be   [];  // per-byte enable (all-ones for full writes)
  } eq_txn_t;

  localparam longint unsigned EQ_BASE_ADDR_C   = 'h0000_8000;
  localparam longint unsigned EQ_LINE_STRIDE_C = 'h0000_1000;

  `include "mc_equiv_model.sv"
  `include "mc_equiv_program.sv"

  // ---------------------------------------------------------------------------
  // Mixed-protocol concurrent slice (tc_mc_mixed_concurrent). A single
  // vip_mc instance with port 0 = AXI4 and port 1 = CHI-D over one shared backend
  // and one shared vip_dram, driven concurrently to exercise cross-protocol
  // arbitration / QoS / ordering with no interference. Per the vip_mc
  // representative-cfg convention (both derive from PORTS[0]), every entry must
  // carry BOTH a valid .axi4 and .chi representative regardless of its own proto.
  // ---------------------------------------------------------------------------
  localparam int N_MIXED_PORTS_C = 2;

  localparam vip_mc_port_cfg_t MIXED_PORTS_C [N_MIXED_PORTS_C] = '{
    '{proto: VIP_MC_PROTO_AXI4_E, axi4: VIP_MC_AXI4_CFG_C, chi: VIP_MC_CHI_CFG_C},
    '{proto: VIP_MC_PROTO_CHI_E,  axi4: VIP_MC_AXI4_CFG_C, chi: VIP_MC_CHI_CFG_C}
  };

  typedef vip_mc_env_cfg #(DRAM_CFG_C, N_MIXED_PORTS_C, MIXED_PORTS_C) mixed_env_cfg_t;

  `include "mc_mixed_soak_gen.sv"

  // Disjoint per-protocol address windows so each leg verifies its own data and a
  // cross-protocol byte leak would be caught (row = 64 B, both clear of each
  // other, the CHI slice's windows, and the AXI4 slice DECERR range 'h1000-1FFF).
  localparam longint unsigned MIXED_AXI4_ADDR_C = 'h0001_0000;
  localparam longint unsigned MIXED_CHI_ADDR_C  = 'h0002_0000;

  // ---------------------------------------------------------------------------
  // Narrow-bus (multi-beat / sub-row) slice. A DRAM whose row (128 B) is WIDER
  // than the host bus (64 B) drives the WDATA_BYTES_P < ROW_BYTES_P path in the
  // front-ends without any new tb_top interfaces: the existing 64 B AXI4/CHI
  // interfaces stay, but two 64 B host beats now gather into one 128 B row and a
  // single 64 B beat scatters into half a row. COL_BITS drops 10 -> 9 to absorb
  // the byte field growing clog2(64)->clog2(128), keeping the byte-address decode
  // summed to ADDR_WIDTH_P = 33 (byte 7 + col 9 + bank 2 + bg 2 + row 13 = 33).
  // ---------------------------------------------------------------------------
  localparam vip_dram_cfg_t NARROW_DRAM_CFG_C = '{
    ROW_BYTES_P          : 128,
    ADDR_WIDTH_P         : 33,
    N_RANKS_P            : 1,
    N_BANK_GROUPS_P      : 4,
    BANKS_PER_BG_P       : 4,
    ROW_BITS_P           : 13,
    COL_BITS_P           : 9,
    DEVICE_WIDTH_P       : 8,
    N_DEVICES_PER_RANK_P : 8
  };

  localparam int N_NARROW_PORTS_C = 1;

  // Single AXI4 port at the stock 64 B width over the 128 B-row device. Carries
  // both representative cfgs per the PORTS[0] convention.
  localparam vip_mc_port_cfg_t NARROW_AXI4_PORTS_C [N_NARROW_PORTS_C] = '{
    '{proto: VIP_MC_PROTO_AXI4_E, axi4: VIP_MC_AXI4_CFG_C, chi: VIP_MC_CHI_CFG_C}
  };

  typedef vip_mc_env_cfg #(NARROW_DRAM_CFG_C, N_NARROW_PORTS_C, NARROW_AXI4_PORTS_C) narrow_axi4_env_cfg_t;

  // Row-aligned (128 B) narrow-test base address, clear of the other windows.
  localparam longint unsigned NARROW_AXI4_ADDR_C = 'h0000_C000;

  // ---------------------------------------------------------------------------
  // Narrow-DAT CHI family (32 B DAT over the stock 64 B DRAM row) for the CHI
  // multi-beat gather test: a 64 B WriteNoSnp becomes two 32 B DAT beats that
  // gather into one 64 B row word. Identical to the CHI-D family otherwise. It
  // reuses the parameterized CHI env/base test; tb_top carries a matching 32 B-DAT
  // SN+RN-I interface pair (same config_db keys, distinguished by vif type).
  // ---------------------------------------------------------------------------
  localparam vip_chi_cfg_t VIP_CHI_CFG_N32_C = '{
    ISSUE_P         : VIP_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : DRAM_CFG_C.ADDR_WIDTH_P,
    DATA_BYTES_P    : 32,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  typedef vip_chi_types #(VIP_CHI_CFG_N32_C) chi_types_n32_t;
  typedef vip_chi_item  #(VIP_CHI_CFG_N32_C) chi_item_n32_t;

  localparam vip_mc_chi_cfg_t VIP_MC_CHI_CFG_N32_C = '{
    issue           : VIP_MC_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : DRAM_CFG_C.ADDR_WIDTH_P,
    DATA_BYTES_P    : 32,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  localparam chi_item_n32_t::addr_t CHI_NARROW_ADDR_C = chi_item_n32_t::addr_t'('h000A_0000);

  `include "mc_soak_gen.sv"
  `include "mc_scoreboard.sv"
  `include "mc_coverage.sv"
  `include "mc_tb_env.sv"

  // Specialized self-contained topologies (each reuses the shared tb_top
  // interfaces but builds its own device/mc/agents): a one-port CHI SN env, an
  // AXI4+CHI mixed env, and a narrow-bus AXI4 env over a 128 B-row device.
  `include "mc_chi_tb_env.sv"
  `include "mc_mixed_tb_env.sv"
  `include "mc_narrow_axi4_tb_env.sv"

endpackage

`endif
