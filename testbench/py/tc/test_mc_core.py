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
## Pure Python checks for the first vip_mc pyUVM porting slice.
##
################################################################################

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
for p in [
    ROOT / "py",
    ROOT / "submodules" / "vip_dram" / "py",
    ROOT / "submodules" / "vip_memory" / "py",
]:
  sp = str(p)
  if sp not in sys.path:
    sys.path.insert(0, sp)

from vip_dram_rsp import VipDramRsp
from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT, VipDramFault, VipDramOp

from vip_mc_axi4_types_pkg import (
  VIP_MC_AXI4_RESP_OKAY_C, VIP_MC_AXI4_RESP_SLVERR_C,
)
from vip_mc_cmd_entry import vip_mc_cmd_entry
from vip_mc_cmd_queue import vip_mc_cmd_queue
from vip_mc_config import vip_mc_config
from vip_mc_backend import vip_mc_backend
from vip_mc_refresh import vip_mc_refresh
from vip_mc_types_pkg import VipMcRefreshPolicy


class FakeTiming:
  tBL = 4.0


class FakeCfg:
  timing = FakeTiming()


class FakeDram:
  cfg = FakeCfg()

  def predict(self, req):
    return float(req.addr), float(req.addr)


def mk_entry(name, op=VipDramOp.RD, addr=0, stream_id=0, qos_class=0):
  e = vip_mc_cmd_entry(name)
  e.op = op
  e.addr = addr
  e.axi4_id = stream_id
  e.qos_class = qos_class
  e.beats = 1
  return e


def test_config_validate_sizes_ports_and_device_window():
  cfg = vip_mc_config()
  cfg.ensure_port_count(2)
  cfg.qos_class_count = 4
  cfg.axi4.qos_class_map[15] = 9

  cfg.validate(VIP_DRAM_CFG_DEFAULT)

  assert [p.vif_key for p in cfg.ports] == ["vif_port0", "vif_port1"]
  assert cfg.max_inflight_to_device == 16
  assert cfg.axi4.qos_class_map[15] == 3


def test_config_rejects_bad_port_region():
  cfg = vip_mc_config()
  cfg.ensure_port_count(1)
  cfg.ports[0].regions.append(type("BadRegion", (), {"lo": 8, "hi": 4})())

  try:
    cfg.validate(VIP_DRAM_CFG_DEFAULT)
  except RuntimeError as e:
    assert "lo > hi" in str(e)
  else:
    raise AssertionError("validate() accepted an inverted port region")


def test_cmd_queue_preserves_same_stream_order_across_qos_classes():
  cfg = vip_mc_config()
  cfg.qos_class_count = 2
  q = vip_mc_cmd_queue(cfg=cfg)

  older = mk_entry("older", addr=0x1000, stream_id=3, qos_class=0)
  newer = mk_entry("newer", addr=0x2000, stream_id=3, qos_class=1)
  q.admit(older)
  q.admit(newer)

  assert q.pick() is older
  q.enqueue(older)
  assert q.pick() is None

  rsp = VipDramRsp("rsp")
  rsp.tag = older.tag
  assert q.complete_by_rsp(rsp) is older
  assert q.pick() is newer


def test_cmd_queue_aging_promotes_old_entries():
  now = {"ns": 0.0}
  cfg = vip_mc_config()
  cfg.qos_class_count = 3
  cfg.qos_aging_ns = 10.0
  q = vip_mc_cmd_queue(cfg=cfg, now_func=lambda: now["ns"])

  old_low = mk_entry("old_low", addr=0x1000, qos_class=0)
  q.admit(old_low)
  now["ns"] = 1.0
  high = mk_entry("high", addr=0x2000, qos_class=1)
  q.admit(high)
  now["ns"] = 25.0

  assert q.pick() is old_low


def test_cmd_queue_write_coalescing_overlays_newer_byte_lanes():
  cfg = vip_mc_config()
  cfg.write_coalescing_enable = True
  q = vip_mc_cmd_queue(cfg=cfg)

  primary = mk_entry("primary", op=VipDramOp.WR, addr=0x1000, stream_id=2)
  primary.wdata = [0x1122334455667788]
  primary.wstrb = [0x0f]
  secondary = mk_entry("secondary", op=VipDramOp.WR, addr=0x1008, stream_id=2)
  secondary.wdata = [0xaabbccddeeff0011]
  secondary.wstrb = [0xf0]

  q.admit(primary)
  assert q.try_coalesce_write(secondary)

  assert q.get_pending_count() == 1
  assert q.get_coalesced_write_count() == 1
  assert primary.merged_writes == [secondary]
  assert primary.wstrb[0] == 0xff
  assert primary.wdata[0] & 0xffffffff == 0x55667788
  assert (primary.wdata[0] >> 32) & 0xffffffff == 0xaabbccdd


def test_backend_fr_fcfs_uses_predicted_ready_time():
  cfg = vip_mc_config()
  cfg.qos_class_count = 1
  cfg.fr_fcfs_enable = True
  backend = vip_mc_backend(mc_cfg=cfg, dram=FakeDram())

  slow_old = mk_entry("slow_old", addr=20)
  fast_new = mk_entry("fast_new", addr=5, stream_id=1)
  backend.cmd_queue.admit(slow_old)
  backend.cmd_queue.admit(fast_new)

  assert backend.pick_next_entry() is fast_new


def test_backend_fr_fcfs_starvation_cap_forces_oldest_bypassed_entry():
  cfg = vip_mc_config()
  cfg.qos_class_count = 1
  cfg.fr_fcfs_enable = True
  cfg.fr_fcfs_starvation_cap = 1
  backend = vip_mc_backend(mc_cfg=cfg, dram=FakeDram())

  slow_old = mk_entry("slow_old", addr=20)
  fast_new = mk_entry("fast_new", addr=5, stream_id=1)
  backend.cmd_queue.admit(slow_old)
  backend.cmd_queue.admit(fast_new)

  assert backend.pick_next_entry() is fast_new
  replacement_fast = mk_entry("replacement_fast", addr=4, stream_id=2)
  backend.cmd_queue.admit(replacement_fast)

  assert backend.pick_next_entry() is slow_old
  assert backend.get_fr_fcfs_forced_count() == 1


def test_backend_read_write_grouping_prefers_current_direction():
  cfg = vip_mc_config()
  cfg.qos_class_count = 1
  cfg.fr_fcfs_enable = True
  cfg.rd_wr_grouping_enable = True
  backend = vip_mc_backend(mc_cfg=cfg, dram=FakeDram())
  backend.last_issued_dir_valid = True
  backend.last_issued_is_read = True
  backend.same_dir_run_len = 1

  slow_read = mk_entry("slow_read", op=VipDramOp.RD, addr=20)
  fast_write = mk_entry("fast_write", op=VipDramOp.WR, addr=5)
  backend.cmd_queue.admit(slow_read)
  backend.cmd_queue.admit(fast_write)

  assert backend.pick_next_entry() is slow_read
  assert backend.get_rd_wr_grouped_count() == 1


def test_backend_ecc_correctable_repairs_data_and_counts():
  cfg = vip_mc_config()
  cfg.ecc_enable = True
  backend = vip_mc_backend(mc_cfg=cfg, dram=FakeDram())
  entry = mk_entry("rd", op=VipDramOp.RD, addr=0x1000)
  backend.cmd_queue.admit(entry)
  assert backend.cmd_queue.pick() is entry
  backend.cmd_queue.enqueue(entry)

  rsp = VipDramRsp("rsp")
  rsp.tag = entry.tag
  rsp.op = VipDramOp.RD
  rsp.rdata = [0x101]
  rsp.corrupt_mask = [0x001]
  rsp.injected_fault = VipDramFault.CORRECTABLE
  rsp.first_beat_ready_time = 10.0
  rsp.last_beat_ready_time = 10.0

  assert backend.complete_rsp(rsp) is entry
  assert entry.resp == VIP_MC_AXI4_RESP_OKAY_C
  assert entry.rdata == [0x100]
  assert backend.get_ecc_corrected_count() == 1
  assert backend.get_latency_sample_count() == 1


def test_backend_ecc_uncorrectable_maps_slverr():
  cfg = vip_mc_config()
  cfg.ecc_enable = True
  backend = vip_mc_backend(mc_cfg=cfg, dram=FakeDram())
  entry = mk_entry("rd", op=VipDramOp.RD, addr=0x1000)
  backend.cmd_queue.admit(entry)
  assert backend.cmd_queue.pick() is entry
  backend.cmd_queue.enqueue(entry)

  rsp = VipDramRsp("rsp")
  rsp.tag = entry.tag
  rsp.op = VipDramOp.RD
  rsp.rdata = [0x1234]
  rsp.corrupt_mask = [0x0]
  rsp.injected_fault = VipDramFault.UNCORRECTABLE
  rsp.first_beat_ready_time = 2.0
  rsp.last_beat_ready_time = 3.0

  assert backend.complete_rsp(rsp) is entry
  assert entry.resp == VIP_MC_AXI4_RESP_SLVERR_C
  assert backend.get_ecc_uncorrectable_count() == 1


def test_refresh_deferred_emits_catchup_burst_per_debt_and_rank():
  cfg = vip_mc_config()
  cfg.refresh_policy = VipMcRefreshPolicy.DEFERRED
  cfg.refresh_max_deferred = 3
  r = vip_mc_refresh(cfg=cfg)

  assert r.tick() == []
  assert r.tick() == []
  emitted = r.tick()

  assert len(emitted) == 3
  assert all(e.op == VipDramOp.REF for e in emitted)
  assert r.get_refresh_count() == 3
  assert r.get_peak_deferred_debt() == 3
  assert r.get_deferred_catchup_count() == 1
