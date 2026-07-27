################################################################################
##
## Copyright (C) 2026 Fredrik Akerlund
##
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
## SOFTWARE.
##
## Description:
## cocotb smoke top for the first vip_mc Python porting slice.
##
################################################################################

from __future__ import annotations

import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadWrite, RisingEdge
from pyuvm import ConfigDB, uvm_root

_HERE = os.path.dirname(os.path.abspath(__file__))
_PY_ROOT = os.path.dirname(_HERE)


def _find_vip_root(start):
  env = os.environ.get("VIP_ROOT")
  if env:
    return os.path.abspath(env)
  d = start
  while True:
    if os.path.exists(os.path.join(d, ".git")):
      return d
    parent = os.path.dirname(d)
    if parent == d:
      return os.path.abspath(os.path.join(start, "..", ".."))
    d = parent


_ROOT = _find_vip_root(_HERE)


def _add_required_path(path):
  if os.path.isdir(path) and path not in sys.path:
    sys.path.insert(0, path)
    return
  if not os.path.isdir(path):
    raise RuntimeError(
        f"mc_tb_top: expected source dir not found: {path}\n"
        f"  (VIP root resolved to {_ROOT}; set $VIP_ROOT to override)")


_PYS = [
    _HERE,
    _PY_ROOT,
    os.path.join(_PY_ROOT, "tc"),
    os.path.join(_ROOT, "py"),
    os.path.join(_ROOT, "submodules", "vip_axi4_agent", "py"),
    os.path.join(_ROOT, "submodules", "vip_dram", "py"),
    os.path.join(_ROOT, "submodules", "vip_memory", "py"),
    os.path.join(_ROOT, "submodules", "vip_gauss", "py"),
]
for p in _PYS:
  _add_required_path(p)

_CHI_PY = os.path.join(_ROOT, "submodules", "vip_chi_agent", "py")
_HAVE_CHI = (
    os.path.isdir(_CHI_PY) and
    os.path.isdir(os.path.join(_CHI_PY, "seq_lib")))
if _HAVE_CHI:
  _CHI_SEQ_PY = os.path.join(_CHI_PY, "seq_lib")
  if _CHI_SEQ_PY not in sys.path:
    sys.path.insert(0, _CHI_SEQ_PY)
  if _CHI_PY not in sys.path:
    sys.path.append(_CHI_PY)

import test_mc_core as core  # noqa: E402
from vip_axi4_if import Axi4Bus  # noqa: E402
from vip_axi4_types_pkg import Axi4CfgT  # noqa: E402
from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT  # noqa: E402
from vip_mc_axi4_types_pkg import VipMcAxi4CfgT  # noqa: E402
from vip_mc_types_pkg import VipMcChiCfgT, VipMcChiIssue  # noqa: E402

from tc_mc_axi4_single_beat import tc_mc_axi4_single_beat  # noqa: E402,F401
from tc_mc_axi4_burst import tc_mc_axi4_burst  # noqa: E402,F401
from tc_mc_axi4_narrow_unaligned import tc_mc_axi4_narrow_unaligned  # noqa: E402,F401
from tc_mc_axi4_fixed import tc_mc_axi4_fixed  # noqa: E402,F401
from tc_mc_axi4_wrap import tc_mc_axi4_wrap  # noqa: E402,F401
from tc_mc_axi4_page_hit_streak import tc_mc_axi4_page_hit_streak  # noqa: E402,F401
from tc_mc_axi4_user_passthrough import tc_mc_axi4_user_passthrough  # noqa: E402,F401
from tc_mc_axi4_exclusive import tc_mc_axi4_exclusive  # noqa: E402,F401
from tc_mc_axi4_unsupported_reject import tc_mc_axi4_unsupported_reject  # noqa: E402,F401
from tc_mc_status_probe import tc_mc_status_probe  # noqa: E402,F401
from tc_mc_axi4_agent import tc_mc_axi4_agent  # noqa: E402,F401
from tc_mc_axi4_multi_port import tc_mc_axi4_multi_port  # noqa: E402,F401
from tc_mc_axi4_outstanding_limit import tc_mc_axi4_outstanding_limit  # noqa: E402,F401
from tc_mc_axi4_aw_backpressure import tc_mc_axi4_aw_backpressure  # noqa: E402,F401
from tc_mc_axi4_wready_backpressure import tc_mc_axi4_wready_backpressure  # noqa: E402,F401
from tc_mc_axi4_bresp_backpressure import tc_mc_axi4_bresp_backpressure  # noqa: E402,F401
from tc_mc_axi4_rsp_backpressure import tc_mc_axi4_rsp_backpressure  # noqa: E402,F401
from tc_mc_axi4_write_coalesce import tc_mc_axi4_write_coalesce  # noqa: E402,F401
from tc_mc_axi4_fr_fcfs_mixed_rd_wr import tc_mc_axi4_fr_fcfs_mixed_rd_wr  # noqa: E402,F401
from tc_mc_axi4_read_pipeline import tc_mc_axi4_read_pipeline  # noqa: E402,F401
from tc_mc_axi4_read_multi_id import tc_mc_axi4_read_multi_id  # noqa: E402,F401
from tc_mc_axi4_ooo_inter_id import tc_mc_axi4_ooo_inter_id  # noqa: E402,F401
from tc_mc_fr_fcfs_starvation_cap import tc_mc_fr_fcfs_starvation_cap  # noqa: E402,F401
from tc_mc_qos_scheduling import tc_mc_qos_scheduling  # noqa: E402,F401
from tc_mc_qos_aging import tc_mc_qos_aging  # noqa: E402,F401
from tc_mc_rd_wr_grouping import tc_mc_rd_wr_grouping  # noqa: E402,F401
from tc_mc_observability import tc_mc_observability  # noqa: E402,F401
from tc_mc_telemetry_counters import tc_mc_telemetry_counters  # noqa: E402,F401
from tc_mc_reset_recovery import tc_mc_reset_recovery  # noqa: E402,F401
from tc_mc_refresh_collision import tc_mc_refresh_collision  # noqa: E402,F401
from tc_mc_narrow_axi4 import tc_mc_narrow_axi4  # noqa: E402,F401
from tc_mc_multi_rank import tc_mc_multi_rank  # noqa: E402,F401
from tc_mc_equiv_axi4 import tc_mc_equiv_axi4  # noqa: E402,F401
from tc_mc_cfg import tc_mc_cfg  # noqa: E402,F401
from tc_mc_refresh import tc_mc_refresh  # noqa: E402,F401
from tc_mc_refresh_deferred import tc_mc_refresh_deferred  # noqa: E402,F401
from tc_mc_init_delay import tc_mc_init_delay  # noqa: E402,F401
from tc_mc_preset_sweep import tc_mc_preset_sweep  # noqa: E402,F401
from tc_mc_ecc_slverr import tc_mc_ecc_slverr  # noqa: E402,F401
from vip_mc_status_if import vip_mc_status_if  # noqa: E402

if _HAVE_CHI:
  from vip_chi_if import ChiBus  # noqa: E402
  from vip_chi_types_pkg import ChiCfg, Issue, Role  # noqa: E402
  from tc_mc_chi_d_read import tc_mc_chi_d_read  # noqa: E402,F401
  from tc_mc_chi_d_write_read import tc_mc_chi_d_write_read  # noqa: E402,F401
  from tc_mc_chi_d_write_ptl import tc_mc_chi_d_write_ptl  # noqa: E402,F401
  from tc_mc_chi_d_decerr import tc_mc_chi_d_decerr  # noqa: E402,F401
  from tc_mc_chi_d_combined_write import tc_mc_chi_d_combined_write  # noqa: E402,F401
  from tc_mc_chi_d_persist import tc_mc_chi_d_persist  # noqa: E402,F401
  from tc_mc_chi_d_unsupported import tc_mc_chi_d_unsupported  # noqa: E402,F401
  from tc_mc_chi_d_reject import tc_mc_chi_d_reject  # noqa: E402,F401
  from tc_mc_chi_d_narrow import tc_mc_chi_d_narrow  # noqa: E402,F401
  from tc_mc_chi_e_write_read import tc_mc_chi_e_write_read  # noqa: E402,F401
  from tc_mc_chi_e_write_zero import tc_mc_chi_e_write_zero  # noqa: E402,F401
  from tc_mc_chi_e_read_sep import tc_mc_chi_e_read_sep  # noqa: E402,F401
  from tc_mc_equiv_chi import tc_mc_equiv_chi_d  # noqa: E402,F401
  from tc_mc_equiv_chi import tc_mc_equiv_chi_e  # noqa: E402,F401
  from tc_mc_mixed_concurrent import tc_mc_mixed_concurrent  # noqa: E402,F401


_CORE_TESTS = [
    core.test_config_validate_sizes_ports_and_device_window,
    core.test_config_rejects_bad_port_region,
    core.test_cmd_queue_preserves_same_stream_order_across_qos_classes,
    core.test_cmd_queue_aging_promotes_old_entries,
    core.test_cmd_queue_write_coalescing_overlays_newer_byte_lanes,
    core.test_backend_fr_fcfs_uses_predicted_ready_time,
    core.test_backend_fr_fcfs_starvation_cap_forces_oldest_bypassed_entry,
    core.test_backend_read_write_grouping_prefers_current_direction,
    core.test_backend_ecc_correctable_repairs_data_and_counts,
    core.test_backend_ecc_uncorrectable_maps_slverr,
    core.test_refresh_deferred_emits_catchup_burst_per_debt_and_rank,
]


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def tc_mc_core_slice(dut):
  for test in _CORE_TESTS:
    test()


CFG_T = VipMcAxi4CfgT(
    AWID_WIDTH_P=4,
    ARID_WIDTH_P=4,
    ADDR_WIDTH_P=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
    WDATA_BYTES_P=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P,
    RDATA_BYTES_P=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P,
    AWUSER_WIDTH_P=4,
    WUSER_WIDTH_P=4,
    BUSER_WIDTH_P=4,
    ARUSER_WIDTH_P=4,
    RUSER_WIDTH_P=4,
)

AXI4_AGENT_CFG_T = Axi4CfgT(
    AWID_WIDTH_P=CFG_T.AWID_WIDTH_P,
    ARID_WIDTH_P=CFG_T.ARID_WIDTH_P,
    ADDR_WIDTH_P=CFG_T.ADDR_WIDTH_P,
    WDATA_BYTES_P=CFG_T.WDATA_BYTES_P,
    RDATA_BYTES_P=CFG_T.RDATA_BYTES_P,
    AWUSER_WIDTH_P=CFG_T.AWUSER_WIDTH_P,
    WUSER_WIDTH_P=CFG_T.WUSER_WIDTH_P,
    BUSER_WIDTH_P=CFG_T.BUSER_WIDTH_P,
    ARUSER_WIDTH_P=CFG_T.ARUSER_WIDTH_P,
    RUSER_WIDTH_P=CFG_T.RUSER_WIDTH_P,
)

if _HAVE_CHI:
  CHI_D_CFG = ChiCfg(
      issue=Issue.D,
      node_id_width=11,
      addr_width=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      data_bytes=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P)
  MC_CHI_D_CFG_T = VipMcChiCfgT(
      issue=VipMcChiIssue.D,
      NODE_ID_WIDTH_P=11,
      ADDR_WIDTH_P=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      DATA_BYTES_P=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P)
  CHI_E_CFG = ChiCfg(
      issue=Issue.E,
      node_id_width=11,
      addr_width=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      data_bytes=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P)
  MC_CHI_E_CFG_T = VipMcChiCfgT(
      issue=VipMcChiIssue.E,
      NODE_ID_WIDTH_P=11,
      ADDR_WIDTH_P=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      DATA_BYTES_P=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P)
  CHI_N32_CFG = ChiCfg(
      issue=Issue.D,
      node_id_width=11,
      addr_width=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      data_bytes=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P // 2)
  MC_CHI_N32_CFG_T = VipMcChiCfgT(
      issue=VipMcChiIssue.D,
      NODE_ID_WIDTH_P=11,
      ADDR_WIDTH_P=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      DATA_BYTES_P=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P // 2)


_STATUS_SCALARS = (
    "rst_active",
    "cmd_queue_depth",
    "cmd_queue_peak_depth",
    "inflight_to_device",
    "rsp_buf_used",
    "rsp_buf_full",
    "device_issue_credit_avail",
    "backend_stall_reason",
    "refresh_count",
    "issue_pulse",
    "issue_port_id",
    "issue_tag",
    "issue_op",
    "issue_qos_class",
    "issue_pre_resolved",
    "complete_pulse",
    "complete_port_id",
    "complete_tag",
    "complete_op",
    "complete_resp",
    "complete_page",
    "complete_pre_resolved",
    "refresh_emit_pulse",
    "refresh_emit_rank",
    "local_reject_pulse",
    "local_reject_port_id",
    "local_reject_op",
    "local_reject_reason",
)

_STATUS_ARRAYS = (
    "rd_outstanding_count",
    "wr_outstanding_count",
    "aw_pending_depth",
    "pending_b_depth",
    "pending_r_depth",
    "active_r_slots_used",
    "w_data_buf_occupancy",
    "aw_block_reason",
    "ar_block_reason",
    "w_block_reason",
)


def _status_int(value):
  """Convert bools and enum-like status fields into HDL integer values."""
  return int(value)


def _drive_status_hdl(status_hdl, status_vif):
  """Drive one snapshot of the Python status object into the HDL interface."""
  for name in _STATUS_SCALARS:
    getattr(status_hdl, name).value = _status_int(getattr(status_vif, name))
  for name in _STATUS_ARRAYS:
    values = getattr(status_vif, name)
    hdl_array = getattr(status_hdl, name)
    for port_id in range(2):
      value = values[port_id] if port_id < len(values) else 0
      hdl_array[port_id].value = _status_int(value)


async def _mirror_status_to_hdl(dut, status_vif):
  """Continuously mirror the Python status probe into wave-visible HDL."""
  if not hasattr(dut, "status_if"):
    return
  _drive_status_hdl(dut.status_if, status_vif)
  while True:
    await RisingEdge(dut.clk)
    await ReadWrite()
    _drive_status_hdl(dut.status_if, status_vif)


async def _run_uvm(dut, test_name, prefixes=None):
  prefixes = [""] if prefixes is None else list(prefixes)
  ConfigDB().clear()
  cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
  buses = [Axi4Bus(dut, prefix=p) for p in prefixes]
  for bus in buses:
    bus.reset_master()
    bus.reset_subordinate()
  dut.rst_n.value = 0
  for _ in range(5):
    await RisingEdge(dut.clk)
  dut.rst_n.value = 1
  await RisingEdge(dut.clk)

  status_vif = vip_mc_status_if("status_vif", len(buses))
  status_task = cocotb.start_soon(_mirror_status_to_hdl(dut, status_vif))
  ConfigDB().set(None, "*", "vif", buses[0])
  ConfigDB().set(None, "*", "cfg_t", CFG_T)
  ConfigDB().set(None, "*", "axi4_vifs", buses)
  ConfigDB().set(None, "*", "axi4_cfg_ts", [CFG_T] * len(buses))
  ConfigDB().set(None, "*", "axi4_agent_cfg_ts", [AXI4_AGENT_CFG_T] * len(buses))
  ConfigDB().set(None, "*", "n_ports", len(buses))
  ConfigDB().set(None, "*", "status_vif", status_vif)
  try:
    await uvm_root().run_test(test_name, keep_set={ConfigDB})
  finally:
    status_task.cancel()


async def _run_chi_uvm(dut, test_name, chi_cfg, mc_chi_cfg_t,
                       rni_prefix="rni_", mc_prefix="mcchi_"):
  if not _HAVE_CHI:
    raise RuntimeError(
        "vip_chi_agent Python dependency not available at "
        "submodules/vip_chi_agent/py.")

  ConfigDB().clear()
  cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
  rni_vif = ChiBus(dut, chi_cfg, Role.RNI, prefix=rni_prefix)
  mc_chi_vif = ChiBus(dut, chi_cfg, Role.SNF, prefix=mc_prefix)
  rni_vif.reset_role()
  mc_chi_vif.reset_role()

  dut.rst_n.value = 0
  for _ in range(5):
    await RisingEdge(dut.clk)
  dut.rst_n.value = 1
  await RisingEdge(dut.clk)

  ConfigDB().set(None, "*", "rni_vif", rni_vif)
  ConfigDB().set(None, "*", "mc_chi_vif", mc_chi_vif)
  ConfigDB().set(None, "*", "chi_cfg_t", chi_cfg)
  ConfigDB().set(None, "*", "mc_chi_cfg_t", mc_chi_cfg_t)
  await uvm_root().run_test(test_name, keep_set={ConfigDB})


async def _run_mixed_uvm(dut, test_name):
  if not _HAVE_CHI:
    raise RuntimeError(
        "vip_chi_agent Python dependency not available at "
        "submodules/vip_chi_agent/py.")

  ConfigDB().clear()
  cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
  axi4_vif = Axi4Bus(dut, prefix="p0_")
  rni_vif = ChiBus(dut, CHI_D_CFG, Role.RNI, prefix="rni_")
  mc_chi_vif = ChiBus(dut, CHI_D_CFG, Role.SNF, prefix="mcchi_")
  axi4_vif.reset_master()
  axi4_vif.reset_subordinate()
  rni_vif.reset_role()
  mc_chi_vif.reset_role()

  dut.rst_n.value = 0
  for _ in range(5):
    await RisingEdge(dut.clk)
  dut.rst_n.value = 1
  await RisingEdge(dut.clk)

  ConfigDB().set(None, "*", "axi4_vif", axi4_vif)
  ConfigDB().set(None, "*", "axi4_agent_cfg_t", AXI4_AGENT_CFG_T)
  ConfigDB().set(None, "*", "mc_axi4_cfg_t", CFG_T)
  ConfigDB().set(None, "*", "rni_vif", rni_vif)
  ConfigDB().set(None, "*", "mc_chi_vif", mc_chi_vif)
  ConfigDB().set(None, "*", "chi_cfg_t", CHI_D_CFG)
  ConfigDB().set(None, "*", "mc_chi_cfg_t", MC_CHI_D_CFG_T)
  await uvm_root().run_test(test_name, keep_set={ConfigDB})


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_single_beat(dut):
  await _run_uvm(dut, "tc_mc_axi4_single_beat")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_burst(dut):
  await _run_uvm(dut, "tc_mc_axi4_burst")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_narrow_unaligned(dut):
  await _run_uvm(dut, "tc_mc_axi4_narrow_unaligned")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_fixed(dut):
  await _run_uvm(dut, "tc_mc_axi4_fixed")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_wrap(dut):
  await _run_uvm(dut, "tc_mc_axi4_wrap")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_page_hit_streak(dut):
  await _run_uvm(dut, "tc_mc_axi4_page_hit_streak")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_user_passthrough(dut):
  await _run_uvm(dut, "tc_mc_axi4_user_passthrough")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_exclusive(dut):
  await _run_uvm(dut, "tc_mc_axi4_exclusive")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_unsupported_reject(dut):
  await _run_uvm(dut, "tc_mc_axi4_unsupported_reject")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_status_probe(dut):
  await _run_uvm(dut, "tc_mc_status_probe")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_agent(dut):
  await _run_uvm(dut, "tc_mc_axi4_agent", prefixes=["p0_", "p1_"])


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_multi_port(dut):
  await _run_uvm(dut, "tc_mc_axi4_multi_port", prefixes=["p0_", "p1_"])


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_outstanding_limit(dut):
  await _run_uvm(dut, "tc_mc_axi4_outstanding_limit")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_aw_backpressure(dut):
  await _run_uvm(dut, "tc_mc_axi4_aw_backpressure")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_wready_backpressure(dut):
  await _run_uvm(dut, "tc_mc_axi4_wready_backpressure")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_bresp_backpressure(dut):
  await _run_uvm(dut, "tc_mc_axi4_bresp_backpressure")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_rsp_backpressure(dut):
  await _run_uvm(dut, "tc_mc_axi4_rsp_backpressure")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_write_coalesce(dut):
  await _run_uvm(dut, "tc_mc_axi4_write_coalesce")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_fr_fcfs_mixed_rd_wr(dut):
  await _run_uvm(dut, "tc_mc_axi4_fr_fcfs_mixed_rd_wr")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_read_pipeline(dut):
  await _run_uvm(dut, "tc_mc_axi4_read_pipeline")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_read_multi_id(dut):
  await _run_uvm(dut, "tc_mc_axi4_read_multi_id")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_axi4_ooo_inter_id(dut):
  await _run_uvm(dut, "tc_mc_axi4_ooo_inter_id")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_fr_fcfs_starvation_cap(dut):
  await _run_uvm(dut, "tc_mc_fr_fcfs_starvation_cap")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_qos_scheduling(dut):
  await _run_uvm(dut, "tc_mc_qos_scheduling")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_qos_aging(dut):
  await _run_uvm(dut, "tc_mc_qos_aging")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_rd_wr_grouping(dut):
  await _run_uvm(dut, "tc_mc_rd_wr_grouping")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_observability(dut):
  await _run_uvm(dut, "tc_mc_observability", prefixes=["p0_", "p1_"])


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_telemetry_counters(dut):
  await _run_uvm(dut, "tc_mc_telemetry_counters")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_reset_recovery(dut):
  await _run_uvm(dut, "tc_mc_reset_recovery")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_refresh_collision(dut):
  await _run_uvm(dut, "tc_mc_refresh_collision")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_narrow_axi4(dut):
  await _run_uvm(dut, "tc_mc_narrow_axi4")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_multi_rank(dut):
  await _run_uvm(dut, "tc_mc_multi_rank", prefixes=["p0_", "p1_"])


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_equiv_axi4(dut):
  await _run_uvm(dut, "tc_mc_equiv_axi4")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_cfg(dut):
  await _run_uvm(dut, "tc_mc_cfg")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_refresh(dut):
  await _run_uvm(dut, "tc_mc_refresh")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_refresh_deferred(dut):
  await _run_uvm(dut, "tc_mc_refresh_deferred")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_init_delay(dut):
  await _run_uvm(dut, "tc_mc_init_delay")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_preset_sweep(dut):
  await _run_uvm(dut, "tc_mc_preset_sweep")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tc_mc_ecc_slverr(dut):
  await _run_uvm(dut, "tc_mc_ecc_slverr")


if _HAVE_CHI:

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_d_read(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_d_read", CHI_D_CFG, MC_CHI_D_CFG_T,
        rni_prefix="rni_", mc_prefix="mcchi_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_d_write_read(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_d_write_read", CHI_D_CFG, MC_CHI_D_CFG_T,
        rni_prefix="rni_", mc_prefix="mcchi_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_d_write_ptl(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_d_write_ptl", CHI_D_CFG, MC_CHI_D_CFG_T,
        rni_prefix="rni_", mc_prefix="mcchi_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_d_decerr(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_d_decerr", CHI_D_CFG, MC_CHI_D_CFG_T,
        rni_prefix="rni_", mc_prefix="mcchi_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_d_combined_write(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_d_combined_write", CHI_D_CFG, MC_CHI_D_CFG_T,
        rni_prefix="rni_", mc_prefix="mcchi_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_d_persist(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_d_persist", CHI_D_CFG, MC_CHI_D_CFG_T,
        rni_prefix="rni_", mc_prefix="mcchi_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_d_unsupported(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_d_unsupported", CHI_D_CFG, MC_CHI_D_CFG_T,
        rni_prefix="rni_", mc_prefix="mcchi_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_d_reject(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_d_reject", CHI_D_CFG, MC_CHI_D_CFG_T,
        rni_prefix="rni_", mc_prefix="mcchi_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_d_narrow(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_d_narrow", CHI_N32_CFG, MC_CHI_N32_CFG_T,
        rni_prefix="rni_n32_", mc_prefix="mcchi_n32_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_e_write_read(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_e_write_read", CHI_E_CFG, MC_CHI_E_CFG_T,
        rni_prefix="rni_e_", mc_prefix="mcchi_e_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_e_write_zero(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_e_write_zero", CHI_E_CFG, MC_CHI_E_CFG_T,
        rni_prefix="rni_e_", mc_prefix="mcchi_e_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_chi_e_read_sep(dut):
    await _run_chi_uvm(
        dut, "tc_mc_chi_e_read_sep", CHI_E_CFG, MC_CHI_E_CFG_T,
        rni_prefix="rni_e_", mc_prefix="mcchi_e_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_equiv_chi_d(dut):
    await _run_chi_uvm(
        dut, "tc_mc_equiv_chi_d", CHI_D_CFG, MC_CHI_D_CFG_T,
        rni_prefix="rni_", mc_prefix="mcchi_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_equiv_chi_e(dut):
    await _run_chi_uvm(
        dut, "tc_mc_equiv_chi_e", CHI_E_CFG, MC_CHI_E_CFG_T,
        rni_prefix="rni_e_", mc_prefix="mcchi_e_")

  @cocotb.test(timeout_time=5, timeout_unit="ms")
  async def tc_mc_mixed_concurrent(dut):
    await _run_mixed_uvm(dut, "tc_mc_mixed_concurrent")
