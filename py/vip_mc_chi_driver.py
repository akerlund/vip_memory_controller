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
## Native CHI SN front-end matching vip_mc/sv/vip_mc_chi_driver.sv.
##
################################################################################

from __future__ import annotations

from pyuvm import ConfigDB, UVMConfigItemNotFound

from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT, VipDramOp, sim_time_ns

from vip_chi_types_pkg import (
  ChiCfg,
  DatOpcode,
  Issue,
  ReqOpcode,
  Resp,
  RespErr,
  RspOpcode,
  chi_size_bytes,
  chi_xfer_dat_beats,
  req_opcode_is_atomic_returning_data,
)

from vip_mc_axi4_types_pkg import VIP_MC_AXI4_RESP_OKAY_C
from vip_mc_chi_cfg import vip_mc_chi_cfg
from vip_mc_chi_cmd_entry import vip_mc_chi_cmd_entry
from vip_mc_config import vip_mc_config
from vip_mc_fe_base import vip_mc_fe_base
from vip_mc_types_pkg import VipMcChiCfgT, VipMcChiIssue, VipMcStatusOp


BEAT_EPS_C = 0.001


def vip_mc_chi_cfg_to_chi_cfg(cfg_t: VipMcChiCfgT) -> ChiCfg:
  issue = Issue.E if cfg_t.issue == VipMcChiIssue.E else Issue.D
  return ChiCfg(
      issue=issue,
      node_id_width=int(cfg_t.NODE_ID_WIDTH_P),
      addr_width=int(cfg_t.ADDR_WIDTH_P),
      data_bytes=int(cfg_t.DATA_BYTES_P),
      datacheck_en=bool(cfg_t.DATACHECK_EN_P),
      poison_en=bool(cfg_t.POISON_EN_P),
      mpam_en=bool(cfg_t.MPAM_EN_P),
      parity_en=bool(cfg_t.PARITY_EN_P),
  )


class vip_mc_chi_driver(vip_mc_fe_base):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.mc_cfg = None
    self.chi_cfg = None
    self.cfg_t = None
    self.chi_bus_cfg = None
    self.geom = VIP_DRAM_CFG_DEFAULT
    self.vif = None

    self.sn_node_id = 0
    self.initial_req_credits = 15
    self.initial_rsp_credits = 15
    self.initial_dat_credits = 15
    self.split_write_rsp = True

    self.req_grant_pending = 0
    self.rsp_grant_pending = 0
    self.dat_grant_pending = 0
    self.rsp_send_credits = 0
    self.dat_send_credits = 0
    self.link_active = False

    self.wr_await_q = []
    self.rsp_send_flit_q = []
    self.rsp_send_time_q = []
    self.dat_send_flit_q = []
    self.dat_send_time_q = []
    self.dat_send_last_q = []
    self.rsp_announce_flit = None
    self.dat_announce_flit = None
    self.dat_announce_last = False
    self.tx_activity_count = 0

    self.observed_req_count = 0
    self.issued_req_count = 0
    self.complete_count = 0
    self.decerr_count = 0
    self.unsupported_count = 0
    self.persist_count = 0
    self.read_count = 0
    self.write_count = 0
    self.last_issued = None
    self.last_completed = None

  def build_phase(self):
    try:
      self.vif = ConfigDB().get(self, "", "vif")
    except UVMConfigItemNotFound:
      pass
    try:
      self.mc_cfg = ConfigDB().get(self, "", "cfg")
    except UVMConfigItemNotFound:
      pass
    try:
      self.chi_cfg = ConfigDB().get(self, "", "chi_cfg")
    except UVMConfigItemNotFound:
      pass
    try:
      self.cfg_t = ConfigDB().get(self, "", "cfg_t")
    except UVMConfigItemNotFound:
      pass
    try:
      self.geom = ConfigDB().get(self, "", "geom")
    except UVMConfigItemNotFound:
      pass

    if self.mc_cfg is None:
      self.mc_cfg = vip_mc_config()
      self.mc_cfg.ensure_port_count(self.port_id + 1)
    if self.chi_cfg is None:
      self.chi_cfg = self.mc_cfg.chi if self.mc_cfg is not None else vip_mc_chi_cfg()
    if self.cfg_t is None:
      self.cfg_t = VipMcChiCfgT(
          issue=VipMcChiIssue.D,
          NODE_ID_WIDTH_P=11,
          ADDR_WIDTH_P=self.geom.ADDR_WIDTH_P,
          DATA_BYTES_P=self.geom.ROW_BYTES_P)
    self.chi_bus_cfg = vip_mc_chi_cfg_to_chi_cfg(self.cfg_t)

    if self.chi_cfg is not None:
      self.sn_node_id = int(self.chi_cfg.sn_node_id)
      self.initial_req_credits = int(self.chi_cfg.initial_req_credits)
      self.initial_rsp_credits = int(self.chi_cfg.initial_rsp_credits)
      self.initial_dat_credits = int(self.chi_cfg.initial_dat_credits)
      self.split_write_rsp = bool(self.chi_cfg.split_write_rsp)

    self._validate_config()

  def _validate_config(self) -> None:
    if self.vif is None:
      raise RuntimeError(f"[{self.get_name()}] CHI vif handle is null")
    if self.port_id < 0 or self.port_id >= len(self.mc_cfg.ports):
      raise RuntimeError(
          f"[{self.get_name()}] port_id {self.port_id} outside configured ports")
    if (self.cfg_t.DATA_BYTES_P > self.geom.ROW_BYTES_P or
        self.geom.ROW_BYTES_P % self.cfg_t.DATA_BYTES_P != 0):
      raise RuntimeError(
          f"[{self.get_name()}] DATA_BYTES_P={self.cfg_t.DATA_BYTES_P} must "
          f"divide ROW_BYTES_P={self.geom.ROW_BYTES_P}")
    if getattr(self.vif, "cfg", None) is not None:
      if (self.vif.cfg.issue != self.chi_bus_cfg.issue or
          self.vif.cfg.node_id_width != self.chi_bus_cfg.node_id_width or
          self.vif.cfg.addr_width != self.chi_bus_cfg.addr_width or
          self.vif.cfg.data_bytes != self.chi_bus_cfg.data_bytes):
        raise RuntimeError(
            f"[{self.get_name()}] CHI bus cfg {self.vif.cfg} does not match "
            f"MC port cfg {self.chi_bus_cfg}")

  async def run_phase(self):
    self.handle_reset()

    while True:
      await self.vif.rising()
      if self.vif.in_reset():
        self.handle_reset()
        continue

      self.drive_link_sideband()
      if not self.link_active and self.vif.get_or("rxlinkactivereq"):
        self.link_active = True
        self.schedule_initial_credit_grants()

      if self.vif.get_or("rxrsplcrdv"):
        self.rsp_send_credits += 1
      if self.vif.get_or("rxdatlcrdv"):
        self.dat_send_credits += 1

      if self.link_active and self.vif.get_or("rxreqflitv"):
        req = self.vif.sample_flit("req", "rx")
        # An LCRD return occupies a REQ flit but is not a transaction and must
        # not be answered with another credit grant.
        if int(req.get("opcode", 0)) != int(ReqOpcode.LCRD_RETURN):
          self.handle_req(req)
          self.req_grant_pending += 1

      if self.link_active and self.vif.get_or("rxdatflitv"):
        self.handle_write_data(self.vif.sample_flit("dat", "rx"))
        self.dat_grant_pending += 1

      if self.link_active and self.vif.get_or("rxrspflitv"):
        self.rsp_grant_pending += 1

      self.drive_credit_grants()
      self.drive_sends()

  def complete(self, entry) -> None:
    if not isinstance(entry, vip_mc_chi_cmd_entry):
      self.logger.error("complete() received a non-CHI cmd entry")
      return

    self.last_completed = entry
    self.complete_count += 1
    if entry.resp != VIP_MC_AXI4_RESP_OKAY_C and entry.chi_resp_err == int(RespErr.OKAY):
      entry.chi_resp_err = int(RespErr.DERR)
    if entry.op == VipDramOp.RD:
      self.enqueue_read_completion(entry)
    else:
      self.enqueue_write_completion(entry)

  def handle_reset(self) -> None:
    self.reset_runtime_state()

  def reset_runtime_state(self) -> None:
    self.wr_await_q.clear()
    self.rsp_send_flit_q.clear()
    self.rsp_send_time_q.clear()
    self.dat_send_flit_q.clear()
    self.dat_send_time_q.clear()
    self.dat_send_last_q.clear()
    self.rsp_announce_flit = None
    self.dat_announce_flit = None
    self.dat_announce_last = False
    self.tx_activity_count = 0

    self.req_grant_pending = 0
    self.rsp_grant_pending = 0
    self.dat_grant_pending = 0
    self.rsp_send_credits = 0
    self.dat_send_credits = 0
    self.link_active = False

    self.observed_req_count = 0
    self.issued_req_count = 0
    self.complete_count = 0
    self.decerr_count = 0
    self.unsupported_count = 0
    self.persist_count = 0
    self.read_count = 0
    self.write_count = 0

    if self.vif is not None:
      self.vif.drive(
          txlinkactivereq=0, txlinkactiveack=0, txsactive=0,
          txreqlcrdv=0, txrsplcrdv=0, txdatlcrdv=0,
          txreqflitpend=0, txreqflitv=0,
          txrspflitpend=0, txrspflitv=0,
          txdatflitpend=0, txdatflitv=0)
      self.vif.drive_flit("req", {})
      self.vif.drive_flit("rsp", {})
      self.vif.drive_flit("dat", {})

  def schedule_initial_credit_grants(self) -> None:
    self.req_grant_pending += self.initial_req_credits
    self.rsp_grant_pending += self.initial_rsp_credits
    self.dat_grant_pending += self.initial_dat_credits

  def drive_credit_grants(self) -> None:
    self.vif.drive(
        txreqlcrdv=1 if self.req_grant_pending else 0,
        txrsplcrdv=1 if self.rsp_grant_pending else 0,
        txdatlcrdv=1 if self.dat_grant_pending else 0)
    if self.req_grant_pending:
      self.req_grant_pending -= 1
    if self.rsp_grant_pending:
      self.rsp_grant_pending -= 1
    if self.dat_grant_pending:
      self.dat_grant_pending -= 1

  def link_drained(self) -> bool:
    return (
        self.req_grant_pending == 0 and
        self.rsp_grant_pending == 0 and
        self.dat_grant_pending == 0 and
        self.rsp_send_credits == 0 and
        self.dat_send_credits == 0 and
        not self.rsp_send_flit_q and
        not self.dat_send_flit_q and
        self.rsp_announce_flit is None and
        self.dat_announce_flit is None and
        self.tx_activity_count == 0)

  def drive_link_sideband(self) -> None:
    if self.vif.get_or("rxlinkactivereq"):
      want_link = True
    else:
      want_link = (
          bool(self.vif.get_or("txlinkactivereq")) or
          bool(self.vif.get_or("txlinkactiveack"))) and not self.link_drained()
    if (self.vif.get_or("txlinkactivereq") and
        not self.vif.get_or("txlinkactiveack")):
      want_link = True
    if self.vif.input_race_hold():
      return
    self.vif.drive(
        txlinkactivereq=1 if want_link else 0,
        txlinkactiveack=1 if self.vif.get_or("txlinkactivereq") else 0)

  def handle_req(self, req: dict) -> None:
    self.observed_req_count += 1
    self.tx_activity_count += 1
    op = int(req.get("opcode", 0))

    if op in (int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP)):
      self.handle_read_req(req, op == int(ReqOpcode.READ_NO_SNP_SEP))
    elif op in (int(ReqOpcode.WRITE_NO_SNP_FULL),
                int(ReqOpcode.WRITE_NO_SNP_PTL)):
      self.handle_write_req(req)
    elif op == int(ReqOpcode.WRITE_NO_SNP_ZERO):
      self.handle_write_zero_req(req)
    elif op in (int(ReqOpcode.CLEAN_SHARED_PERSIST),
                int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP)):
      self.handle_persist_req(req, op == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP))
    else:
      self.handle_unsupported_req(req)

  def new_entry_from_req(self, req: dict, op: VipDramOp) -> vip_mc_chi_cmd_entry:
    entry = vip_mc_chi_cmd_entry(f"chi_cmd_{self.observed_req_count}")
    entry.port_id = self.port_id
    entry.op = op
    entry.addr = int(req.get("addr", 0))
    entry.axi4_id = int(req.get("txnid", 0))
    entry.beats = chi_xfer_dat_beats(int(req.get("size", 0)), self.geom.ROW_BYTES_P)
    entry.chi_dat_beats = chi_xfer_dat_beats(
        int(req.get("size", 0)), self.cfg_t.DATA_BYTES_P)
    entry.chi_size_bytes = chi_size_bytes(int(req.get("size", 0)))
    entry.qos = int(req.get("qos", 0))
    entry.qos_class = self.mc_cfg.axi4.qos_to_class(entry.qos)
    entry.enqueue_time = sim_time_ns()

    entry.chi_srcid = int(req.get("srcid", 0))
    entry.chi_tgtid = int(req.get("tgtid", 0))
    entry.chi_txnid = int(req.get("txnid", 0))
    entry.chi_dbid = int(req.get("txnid", 0))
    entry.chi_qos = int(req.get("qos", 0))
    entry.chi_exp_comp_ack = bool(req.get("expcompack", 0))
    return entry

  def handle_read_req(self, req: dict, is_sep: bool) -> None:
    entry = self.new_entry_from_req(req, VipDramOp.RD)
    entry.chi_is_sep_read = bool(is_sep)
    if is_sep:
      entry.chi_return_nid = int(req.get("returnnid", 0))
      entry.chi_return_txn = int(req.get("returntxnid", 0))
    entry.chi_needs_receipt = self.req_has_ordering(req)
    if entry.chi_needs_receipt:
      self.queue_read_receipt(entry)

    if self.classify_decerr(entry):
      entry.chi_resp_err = int(RespErr.NDERR)
      self.make_pre_resolved(entry)
      entry.rdata = [0] * max(1, entry.beats)
      self.enqueue_read_completion(entry)
      return

    self.read_count += 1
    self.issue_request(entry)

  def handle_write_req(self, req: dict) -> None:
    entry = self.new_entry_from_req(req, VipDramOp.WR)
    entry.chi_is_write = True
    entry.chi_split_write_rsp = self.split_write_rsp
    entry.wdata = [0] * max(1, entry.beats)
    entry.wstrb = [0] * max(1, entry.beats)

    if self.classify_decerr(entry):
      entry.chi_resp_err = int(RespErr.NDERR)

    self.queue_write_grant(entry)
    self.wr_await_q.append(entry)

  def handle_write_zero_req(self, req: dict) -> None:
    entry = self.new_entry_from_req(req, VipDramOp.WR)
    entry.chi_is_write = True
    entry.chi_is_write_zero = True
    entry.chi_split_write_rsp = True
    entry.wdata = [0] * max(1, entry.beats)
    entry.wstrb = [(1 << self.geom.ROW_BYTES_P) - 1] * max(1, entry.beats)

    # WriteNoSnpZero still uses the normal split write response shape: the RN
    # must receive a DBID-bearing grant before the final Comp, even though no
    # write DAT burst follows.
    self.queue_write_grant(entry)
    if self.classify_decerr(entry):
      entry.chi_resp_err = int(RespErr.NDERR)
      self.make_pre_resolved(entry)
      self.enqueue_write_completion(entry)
      return

    self.write_count += 1
    self.issue_request(entry)

  def handle_persist_req(self, req: dict, is_sep: bool) -> None:
    self.persist_count += 1
    entry = self.new_entry_from_req(req, VipDramOp.RD)
    entry.chi_resp_err = int(RespErr.OKAY)
    if is_sep:
      self.push_rsp(self.build_rsp_flit(entry, RspOpcode.PERSIST), sim_time_ns())
      self.push_rsp(self.build_rsp_flit(entry, RspOpcode.COMP_PERSIST), sim_time_ns())
    else:
      self.push_rsp(self.build_rsp_flit(entry, RspOpcode.COMP), sim_time_ns())

  def handle_unsupported_req(self, req: dict) -> None:
    self.unsupported_count += 1
    op = int(req.get("opcode", 0))
    if req_opcode_is_atomic_returning_data(op):
      self.logger.warning(
          "Unsupported CHI data-returning atomic opcode 0x%x (txnid=0x%x) "
          "-> CompData(NONDATA_ERROR)", op, int(req.get("txnid", 0)))
      entry = self.new_entry_from_req(req, VipDramOp.RD)
      entry.chi_resp_err = int(RespErr.NDERR)
      self.make_pre_resolved(entry)
      entry.rdata = [0] * max(1, entry.beats)
      self.enqueue_read_completion(entry)
      return
    self.logger.warning(
      "Unsupported CHI REQ opcode 0x%x (txnid=0x%x) -> Comp(NONDATA_ERROR)",
      op, int(req.get("txnid", 0)))
    entry = self.new_entry_from_req(req, VipDramOp.WR)
    entry.chi_is_write = True
    entry.chi_split_write_rsp = True
    entry.chi_resp_err = int(RespErr.NDERR)
    self.make_pre_resolved(entry)
    self.enqueue_write_completion(entry)

  def handle_write_data(self, dat: dict) -> None:
    match_idx = -1
    for i, entry in enumerate(self.wr_await_q):
      if int(entry.chi_dbid) == int(dat.get("txnid", 0)):
        match_idx = i
        break
    if match_idx < 0:
      self.logger.error(
          "Write DAT beat with unmatched txnid/dbid 0x%x",
          int(dat.get("txnid", 0)))
      return

    entry = self.wr_await_q[match_idx]
    if entry.chi_wr_beats_seen < entry.chi_dat_beats:
      self.pack_chi_write_beat(
          entry, entry.chi_wr_beats_seen,
          int(dat.get("data", 0)), int(dat.get("be", 0)))
    entry.chi_wr_beats_seen += 1

    if entry.chi_wr_beats_seen < entry.chi_dat_beats:
      return

    del self.wr_await_q[match_idx]
    if entry.chi_resp_err == int(RespErr.NDERR):
      self.make_pre_resolved(entry)
      self.enqueue_write_completion(entry)
      return

    self.write_count += 1
    self.issue_request(entry)

  def issue_request(self, entry: vip_mc_chi_cmd_entry) -> None:
    self.last_issued = entry
    self.issued_req_count += 1
    self.req_port.write(entry)

  def make_pre_resolved(self, entry: vip_mc_chi_cmd_entry) -> None:
    now = sim_time_ns()
    entry.pre_resolved = True
    entry.completed = True
    entry.first_beat_ready_time = now
    entry.last_beat_ready_time = now

  def chi_beat_row_map(self, entry: vip_mc_chi_cmd_entry, dat_beat_idx: int):
    base_data_addr = entry.addr - (entry.addr % self.cfg_t.DATA_BYTES_P)
    beat_base = base_data_addr + (int(dat_beat_idx) * self.cfg_t.DATA_BYTES_P)
    base_row = entry.addr // self.geom.ROW_BYTES_P
    row_idx = (beat_base // self.geom.ROW_BYTES_P) - base_row
    row_lane_offset = beat_base % self.geom.ROW_BYTES_P
    return int(row_idx), int(row_lane_offset)

  def pack_chi_write_beat(self, entry: vip_mc_chi_cmd_entry,
                          dat_beat_idx: int, data: int, be: int) -> None:
    row_idx, row_lane_offset = self.chi_beat_row_map(entry, dat_beat_idx)
    if row_idx >= len(entry.wdata):
      self.logger.error(
          "CHI write DAT beat %d -> row %d outside wdata.size=%d",
          dat_beat_idx, row_idx, len(entry.wdata))
      return

    for k in range(self.cfg_t.DATA_BYTES_P):
      row_lane = row_lane_offset + k
      if row_lane >= self.geom.ROW_BYTES_P:
        self.logger.error(
            "CHI write row lane %d outside ROW_BYTES_P=%d",
            row_lane, self.geom.ROW_BYTES_P)
        return
      if (int(be) >> k) & 1:
        byte = (int(data) >> (8 * k)) & 0xff
        entry.wdata[row_idx] &= ~(0xff << (8 * row_lane))
        entry.wdata[row_idx] |= byte << (8 * row_lane)
        entry.wstrb[row_idx] |= 1 << row_lane

  @staticmethod
  def req_has_ordering(req: dict) -> bool:
    return int(req.get("order", 0)) != 0

  def classify_decerr(self, entry: vip_mc_chi_cmd_entry) -> bool:
    total_bytes = entry.chi_size_bytes if entry.chi_size_bytes else 1
    first_addr = int(entry.addr)
    last_addr = int(entry.addr) + int(total_bytes) - 1
    if not self.port_owns_range(first_addr, last_addr) or self.range_hits_decerr(
        first_addr, last_addr):
      if self.mc_cfg.perf_counters_enabled:
        self.decerr_count += 1
      return True
    return False

  def port_owns_range(self, addr: int, last_addr: int) -> bool:
    port_cfg = self.mc_cfg.ports[self.port_id]
    if not port_cfg.regions:
      return True
    return any(int(addr) >= int(r.lo) and int(last_addr) <= int(r.hi)
               for r in port_cfg.regions)

  def range_hits_decerr(self, addr: int, last_addr: int) -> bool:
    for lo, hi in zip(self.mc_cfg.axi4.decerr_addr_lo,
                      self.mc_cfg.axi4.decerr_addr_hi):
      if int(addr) <= int(hi) and int(last_addr) >= int(lo):
        return True
    return False

  def queue_write_grant(self, entry: vip_mc_chi_cmd_entry) -> None:
    grant_op = RspOpcode.DBID_RESP if entry.chi_split_write_rsp else RspOpcode.COMP_DBID_RESP
    self.push_rsp(self.build_rsp_flit(entry, grant_op), sim_time_ns())

  def queue_read_receipt(self, entry: vip_mc_chi_cmd_entry) -> None:
    self.push_rsp(self.build_rsp_flit(entry, RspOpcode.READ_RECEIPT), sim_time_ns())

  def enqueue_read_completion(self, entry: vip_mc_chi_cmd_entry) -> None:
    dat_op = DatOpcode.DATA_SEP_RESP if entry.chi_is_sep_read else DatOpcode.COMP_DATA
    n_beats = max(1, int(entry.chi_dat_beats))
    if entry.chi_is_sep_read:
      self.push_rsp(
          self.build_rsp_flit(entry, RspOpcode.RESP_SEP_DATA),
          self.beat_target(entry, 0, n_beats))

    for i in range(n_beats):
      self.push_dat(
          self.build_dat_flit(entry, dat_op, i),
          self.beat_target(entry, i, n_beats),
          i == (n_beats - 1))

  def enqueue_write_completion(self, entry: vip_mc_chi_cmd_entry) -> None:
    if not entry.chi_split_write_rsp:
      if entry.pre_resolved:
        self.logger.error(
            "combined write (txnid=0x%x) reached enqueue_write_completion "
            "pre_resolved after CompDBIDResp",
            entry.chi_txnid)
      return
    target = sim_time_ns() if entry.pre_resolved else entry.last_beat_ready_time
    if not self.mc_cfg.honor_beat_timing:
      target = sim_time_ns()
    self.push_rsp(self.build_rsp_flit(entry, RspOpcode.COMP), target)

  def build_rsp_flit(self, entry: vip_mc_chi_cmd_entry, opcode) -> dict:
    opcode = int(opcode)
    resperr = int(entry.chi_resp_err)
    if opcode in (int(RspOpcode.DBID_RESP), int(RspOpcode.DBID_RESP_ORD)):
      resperr = int(RespErr.OKAY)
    # Table A-4 uses the I encoding for the cache state on write grants and
    # completions. Keep the assignment explicit at this protocol boundary.
    resp = int(Resp.I)
    if entry.chi_is_write and opcode in (
        int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP)):
      resp = int(Resp.I)
    txnid = 0 if opcode == int(RspOpcode.PERSIST) else int(entry.chi_txnid)
    return {
        "opcode": opcode,
        "tgtid": int(entry.chi_srcid),
        "srcid": int(entry.chi_tgtid),
        "txnid": txnid,
        "dbid": int(entry.chi_dbid),
        "resp": resp,
        "resperr": resperr,
        "qos": int(entry.chi_qos) & 0xf,
    }

  def build_dat_flit(self, entry: vip_mc_chi_cmd_entry, opcode,
                     beat_idx: int) -> dict:
    rsp_txnid = entry.chi_return_txn if entry.chi_is_sep_read else entry.chi_txnid
    rsp_tgtid = entry.chi_return_nid if entry.chi_is_sep_read else entry.chi_srcid
    fields = {
        "opcode": int(opcode),
        "tgtid": int(rsp_tgtid),
        "srcid": int(entry.chi_tgtid),
        "homenid": int(entry.chi_tgtid),
        "txnid": int(rsp_txnid),
        "dbid": int(rsp_txnid),
        "dataid": int(beat_idx),
        "resp": int(Resp.I),
        "resperr": int(entry.chi_resp_err),
        "qos": int(entry.chi_qos) & 0xf,
    }

    if entry.chi_resp_err == int(RespErr.NDERR):
      fields["data"] = 0
      fields["be"] = 0
      return fields

    row_idx, row_lane_offset = self.chi_beat_row_map(entry, beat_idx)
    data = 0
    if row_idx < len(entry.rdata):
      for k in range(self.cfg_t.DATA_BYTES_P):
        byte = (int(entry.rdata[row_idx]) >>
                (8 * (row_lane_offset + k))) & 0xff
        data |= byte << (8 * k)
    fields["data"] = data
    fields["be"] = (1 << self.cfg_t.DATA_BYTES_P) - 1
    return fields

  def beat_target(self, entry: vip_mc_chi_cmd_entry, beat_idx: int,
                  n_beats: int) -> float:
    if entry.pre_resolved:
      return sim_time_ns()
    if n_beats <= 1:
      return float(entry.first_beat_ready_time)
    span = float(entry.last_beat_ready_time) - float(entry.first_beat_ready_time)
    step = span / float(n_beats - 1)
    return float(entry.first_beat_ready_time) + (float(beat_idx) * step)

  def push_rsp(self, flit: dict, ready_time: float) -> None:
    self.rsp_send_flit_q.append(dict(flit))
    self.rsp_send_time_q.append(float(ready_time))

  def push_dat(self, flit: dict, ready_time: float, is_last: bool) -> None:
    self.dat_send_flit_q.append(dict(flit))
    self.dat_send_time_q.append(float(ready_time))
    self.dat_send_last_q.append(bool(is_last))

  def send_time_reached(self, ready_time: float) -> bool:
    if not self.mc_cfg.honor_beat_timing:
      return True
    return (sim_time_ns() + BEAT_EPS_C) >= float(ready_time)

  def announce_rsp_flit(self) -> bool:
    if (not self.rsp_send_flit_q or self.rsp_send_credits <= 0 or
        not self.send_time_reached(self.rsp_send_time_q[0])):
      return False
    self.rsp_announce_flit = self.rsp_send_flit_q.pop(0)
    self.rsp_send_time_q.pop(0)
    return True

  def announce_dat_flit(self) -> bool:
    if (not self.dat_send_flit_q or self.dat_send_credits <= 0 or
        not self.send_time_reached(self.dat_send_time_q[0])):
      return False
    self.dat_announce_flit = self.dat_send_flit_q.pop(0)
    self.dat_send_time_q.pop(0)
    self.dat_announce_last = self.dat_send_last_q.pop(0)
    return True

  @staticmethod
  def rsp_flit_closes_activity(flit: dict) -> bool:
    return int(flit.get("opcode", 0)) in (
        int(RspOpcode.COMP),
        int(RspOpcode.COMP_DBID_RESP),
        int(RspOpcode.COMP_PERSIST))

  def drive_sends(self) -> None:
    sending = False
    sending_resp_sep = False

    self.vif.drive(txrspflitpend=0, txrspflitv=0)
    if self.rsp_announce_flit is not None:
      flit = self.rsp_announce_flit
      self.rsp_send_credits -= 1
      self.vif.drive_flit("rsp", flit)
      self.vif.drive(txrspflitpend=0, txrspflitv=1)
      self.rsp_announce_flit = None
      sending = True
      if (self.rsp_flit_closes_activity(flit) and
          self.tx_activity_count > 0):
        self.tx_activity_count -= 1
      sending_resp_sep = int(flit.get("opcode", 0)) == int(RspOpcode.RESP_SEP_DATA)
    elif self.announce_rsp_flit():
      self.vif.drive_flit("rsp", self.rsp_announce_flit)
      self.vif.drive(txrspflitpend=1, txrspflitv=0)

    self.vif.drive(txdatflitpend=0, txdatflitv=0)
    if (self.dat_announce_flit is not None and
        not (sending_resp_sep and
             int(self.dat_announce_flit.get("opcode", 0)) ==
             int(DatOpcode.DATA_SEP_RESP))):
      flit = self.dat_announce_flit
      self.dat_send_credits -= 1
      self.vif.drive_flit("dat", flit)
      self.vif.drive(
          txdatflitpend=0 if self.dat_announce_last else 1,
          txdatflitv=1)
      self.dat_announce_flit = None
      sending = True
      if self.dat_announce_last and self.tx_activity_count > 0:
        self.tx_activity_count -= 1
    elif (self.dat_announce_flit is None and
          not (sending_resp_sep and self.dat_send_flit_q and
               int(self.dat_send_flit_q[0].get("opcode", 0)) ==
               int(DatOpcode.DATA_SEP_RESP))):
      if self.announce_dat_flit():
        self.vif.drive_flit("dat", self.dat_announce_flit)
        self.vif.drive(txdatflitpend=1, txdatflitv=0)

    if self.dat_announce_flit is not None and sending_resp_sep:
      self.vif.drive(txdatflitpend=1)

    self.vif.drive(
        txsactive=1 if (self.tx_activity_count > 0 or sending) else 0)

  def get_decerr_count(self) -> int:
    return self.decerr_count if self.mc_cfg.perf_counters_enabled else 0

  def get_read_count(self) -> int:
    return self.read_count

  def get_write_count(self) -> int:
    return self.write_count

  def get_unsupported_count(self) -> int:
    return self.unsupported_count

  def get_persist_count(self) -> int:
    return self.persist_count

  def get_rsp_slots_used_count(self) -> int:
    return len(self.rsp_send_flit_q) + len(self.dat_send_flit_q)
