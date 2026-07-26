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
## Shared base for vip_mc CHI pyUVM tests.
##
################################################################################

from __future__ import annotations

import logging

from cocotb.triggers import with_timeout
from pyuvm import ConfigDB, uvm_test

from vip_chi_read_seq import vip_chi_read_seq
from vip_chi_types_pkg import ChiCfg, DataType, DatOpcode, Issue, RespErr
from vip_chi_write_seq import vip_chi_write_seq
from vip_chi_write_zero_seq import vip_chi_write_zero_seq

from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT

from mc_chi_tb_env import CHI_DECERR_LO_C
from mc_chi_tb_env import mc_chi_tb_env
from vip_mc_types_pkg import VipMcChiCfgT, VipMcChiIssue


CHI_WRITE_READ_ADDR_C = 0x0001_0000
CHI_READ_ADDR_C = 0x0002_0000
CHI_DECERR_ADDR_C = CHI_DECERR_LO_C
CHI_PTL_ADDR_C = 0x0004_0000
CHI_ZERO_ADDR_C = 0x0005_0000
CHI_COMBINED_ADDR_C = 0x0006_0000
CHI_SEP_ADDR_C = 0x0007_0000
CHI_NARROW_ADDR_C = 0x000A_0000


class _ErrorCounter(logging.Handler):

  def __init__(self):
    super().__init__(level=logging.ERROR)
    self.count = 0

  def emit(self, record):
    if record.levelno >= logging.ERROR:
      self.count += 1


class mc_chi_base_test(uvm_test):

  DRAM_GEOM = VIP_DRAM_CFG_DEFAULT
  CHI_CFG = ChiCfg(
      issue=Issue.D,
      node_id_width=11,
      addr_width=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      data_bytes=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P)
  MC_CHI_CFG = VipMcChiCfgT(
      issue=VipMcChiIssue.D,
      NODE_ID_WIDTH_P=11,
      ADDR_WIDTH_P=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      DATA_BYTES_P=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P)
  MAX_WAIT_CYCLES = 2000
  SPLIT_WRITE_RSP = True

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.env = None
    self.rni_vif = None
    self.mc_chi_vif = None
    self.wr_seq = None
    self.rd_seq = None
    self._err_handler = None

  def build_phase(self):
    self.rni_vif = ConfigDB().get(self, "", "rni_vif")
    self.mc_chi_vif = ConfigDB().get(self, "", "mc_chi_vif")
    ConfigDB().set(self, "env", "rni_vif", self.rni_vif)
    ConfigDB().set(self, "env", "mc_chi_vif", self.mc_chi_vif)
    ConfigDB().set(self, "env", "chi_cfg_t", self.CHI_CFG)
    ConfigDB().set(self, "env", "mc_chi_cfg_t", self.MC_CHI_CFG)
    ConfigDB().set(self, "env", "dram_geom", self.DRAM_GEOM)
    ConfigDB().set(
        self, "env", "mc_chi_split_write_rsp",
        1 if self.SPLIT_WRITE_RSP else 0)
    self.env = mc_chi_tb_env("env", self)
    self.wr_seq = vip_chi_write_seq("wr_seq", cfg=self.CHI_CFG)
    self.rd_seq = vip_chi_read_seq("rd_seq", cfg=self.CHI_CFG)

  def end_of_elaboration_phase(self):
    self._err_handler = _ErrorCounter()
    self.add_logging_handler_hier(self._err_handler)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_and_settle()
    await self.body()
    self.drop_objection()

  async def body(self):
    pass

  def check_phase(self):
    n_errors = self._err_handler.count if self._err_handler is not None else 0
    if n_errors:
      raise AssertionError(f"{type(self).__name__}: {n_errors} UVM_ERROR(s) logged")

  async def wait_reset_and_settle(self):
    while self.rni_vif.in_reset():
      await self.rni_vif.rising()
    await self.rni_vif.clocks(20)

  async def start_seq_or_timeout(self, seq):
    timeout_ns = self.MAX_WAIT_CYCLES * 10
    try:
      await with_timeout(seq.start(self.env.rni_agent.sequencer), timeout_ns, "ns")
    except Exception as exc:
      fe = self.get_chi_fe()
      bus = self.rni_vif
      raise AssertionError(
          f"{seq.get_name()} timed out: "
          f"rni txreqv={bus.get_or('txreqflitv')} rxreqlcrdv={bus.get_or('rxreqlcrdv')} "
          f"rxrspv={bus.get_or('rxrspflitv')} rxdatv={bus.get_or('rxdatflitv')} "
          f"fe obs={fe.observed_req_count} issued={fe.issued_req_count} "
          f"rsp_q={len(fe.rsp_send_flit_q)} dat_q={len(fe.dat_send_flit_q)} "
          f"rsp_cr={fe.rsp_send_credits} dat_cr={fe.dat_send_credits}") from exc

  def get_chi_fe(self):
    return self.env.u_mc.fes[0]

  async def write_chi(self, addr: int, data_beats=None, be_beats=None,
                      size=6, data_type=DataType.COUNTER,
                      counter_value=0, counter_increment=1,
                      get_response=True):
    seq = self.wr_seq
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(int(addr))
    seq.set_size(int(size))
    seq.set_allow_retry(0)
    seq.set_data_type(data_type)
    if data_type == DataType.CUSTOM:
      seq.set_data([int(x) for x in data_beats])
      if be_beats is not None:
        seq.set_be([int(x) for x in be_beats])
    elif data_type == DataType.COUNTER:
      seq.set_counter_value(int(counter_value))
      seq.set_counter_increment(int(counter_increment))
    seq.set_get_response(bool(get_response))
    seq.set_verbose(False)
    await self.start_seq_or_timeout(seq)
    return seq.get_responses()

  async def read_chi(self, addr: int, size=6, sep_read=False,
                     return_nid=0, return_txn_id=0, get_response=True):
    seq = self.rd_seq
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(int(addr))
    seq.set_size(int(size))
    seq.set_allow_retry(0)
    seq.set_sep_read(bool(sep_read))
    seq.set_return_nid(int(return_nid))
    seq.set_return_txn_id(int(return_txn_id))
    seq.set_get_response(bool(get_response))
    seq.set_verbose(False)
    await self.start_seq_or_timeout(seq)
    return seq.get_responses()

  async def write_zero_chi(self, addr: int, size=6):
    seq = vip_chi_write_zero_seq("wz_seq", cfg=self.CHI_CFG)
    seq.set_requests(1)
    seq.set_initial_addr(int(addr))
    seq.set_size(int(size))
    seq.set_allow_retry(0)
    seq.set_get_response(True)
    seq.set_verbose(False)
    await self.start_seq_or_timeout(seq)
    return seq.get_responses()

  @staticmethod
  def byte_replicate(byte_val: int, n_bytes: int = 64) -> int:
    word = 0
    for i in range(n_bytes):
      word |= (int(byte_val) & 0xff) << (8 * i)
    return word

  @staticmethod
  def assert_resp_ok(resp_err: int) -> None:
    assert int(resp_err) == int(RespErr.OKAY)

  @staticmethod
  def assert_comp_data(rsp) -> None:
    assert int(rsp.dat_opcode) == int(DatOpcode.COMP_DATA)
