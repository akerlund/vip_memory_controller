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
################################################################################

from __future__ import annotations

import logging

import cocotb
from cocotb.triggers import Combine, with_timeout
from pyuvm import uvm_test

from seq_lib.vip_axi4_read_seq import vip_axi4_read_seq
from seq_lib.vip_axi4_write_seq import vip_axi4_write_seq
from vip_axi4_types_pkg import Axi4DataType, Axi4StrbType
from vip_chi_read_seq import vip_chi_read_seq
from vip_chi_types_pkg import DataType, RespErr
from vip_chi_write_seq import vip_chi_write_seq
from vip_mc_axi4_types_pkg import (
  VIP_MC_AXI4_BURST_INCR_C,
  VIP_MC_AXI4_RESP_OKAY_C,
)
from mc_mixed_tb_env import mc_mixed_tb_env


MIXED_AXI4_ADDR_C = 0x0001_0000
MIXED_CHI_ADDR_C = 0x0002_0000
N_LINES_C = 8


class _ErrorCounter(logging.Handler):

  def __init__(self):
    super().__init__(level=logging.ERROR)
    self.count = 0

  def emit(self, record):
    if record.levelno >= logging.ERROR:
      self.count += 1


class tc_mc_mixed_concurrent(uvm_test):

  MAX_WAIT_CYCLES = 2000

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.env = None
    self._err_handler = None

  def build_phase(self):
    self.env = mc_mixed_tb_env("env", self)

  def end_of_elaboration_phase(self):
    self._err_handler = _ErrorCounter()
    self.add_logging_handler_hier(self._err_handler)

  async def run_phase(self):
    self.raise_objection()
    try:
      await self.wait_reset_and_settle()
      axi_task = cocotb.start_soon(self.drive_axi4())
      chi_task = cocotb.start_soon(self.drive_chi())
      await with_timeout(
          Combine(axi_task, chi_task), self.MAX_WAIT_CYCLES * 10, "ns")
    finally:
      self.drop_objection()

  def check_phase(self):
    n_errors = self._err_handler.count if self._err_handler is not None else 0
    if n_errors:
      raise AssertionError(
          f"{type(self).__name__}: {n_errors} UVM_ERROR(s) logged")

  async def wait_reset_and_settle(self):
    while self.env.rni_vif.in_reset():
      await self.env.rni_vif.rising()
    await self.env.rni_vif.clocks(20)

  async def start_seq_or_timeout(self, seq, sequencer):
    timeout_ns = self.MAX_WAIT_CYCLES * 10
    await with_timeout(seq.start(sequencer), timeout_ns, "ns")

  @staticmethod
  def byte_word(base: int, line: int, nbytes: int) -> int:
    value = 0
    for idx in range(int(nbytes)):
      value |= ((int(base) + int(line) + idx) & 0xff) << (8 * idx)
    return value

  @staticmethod
  def word_byte(word: int, idx: int) -> int:
    return (int(word) >> (8 * int(idx))) & 0xff

  async def drive_axi4(self):
    nb = int(self.env.mc_axi4_cfg_t.WDATA_BYTES_P)
    size = (nb - 1).bit_length()
    strb = (1 << nb) - 1

    for line in range(N_LINES_C):
      addr = MIXED_AXI4_ADDR_C + (line * nb)
      word = self.byte_word(0xA0, line, nb)

      wr = vip_axi4_write_seq(f"axi4_wr_{line}", self.env.axi4_agent_cfg_t)
      wr.reset()
      wr.set_awid(0x3)
      wr.set_axaddr(addr)
      wr.set_axlen(0)
      wr.set_axsize(size)
      wr.set_axburst(VIP_MC_AXI4_BURST_INCR_C)
      wr.set_axqos(0)
      wr.set_requests(1)
      wr.set_get_wr_response(True)
      wr.set_wdata_type(Axi4DataType.CUSTOM)
      wr.set_wstrb_type(Axi4StrbType.CUSTOM)
      wr.set_wdata([word])
      wr.set_wstrb([strb])
      await self.start_seq_or_timeout(wr, self.env.man_agent.sequencer)
      wrsp = wr.get_wr_responses()
      assert len(wrsp) == 1
      assert int(wrsp[0].bresp) == VIP_MC_AXI4_RESP_OKAY_C

      rd = vip_axi4_read_seq(f"axi4_rd_{line}", self.env.axi4_agent_cfg_t)
      rd.reset()
      rd.set_arid(0x5)
      rd.set_axaddr(addr)
      rd.set_axlen(0)
      rd.set_axsize(size)
      rd.set_axburst(VIP_MC_AXI4_BURST_INCR_C)
      rd.set_axqos(0)
      rd.set_requests(1)
      rd.set_get_rd_response(True)
      await self.start_seq_or_timeout(rd, self.env.man_agent.sequencer)
      rrsp = rd.get_rd_responses()
      assert len(rrsp) == 1
      assert len(rrsp[0].rdata) == 1
      assert int(rrsp[0].rresp) == VIP_MC_AXI4_RESP_OKAY_C
      for idx in range(nb):
        got = self.word_byte(rrsp[0].rdata[0], idx)
        exp = (0xA0 + line + idx) & 0xff
        assert got == exp

  async def drive_chi(self):
    nb = int(self.env.mc_chi_cfg_t.DATA_BYTES_P)
    size = (nb - 1).bit_length()

    for line in range(N_LINES_C):
      addr = MIXED_CHI_ADDR_C + (line * nb)
      word = self.byte_word(0x50, line, nb)

      wr = vip_chi_write_seq(f"chi_wr_{line}", cfg=self.env.chi_cfg_t)
      wr.reset()
      wr.set_requests(1)
      wr.set_initial_addr(addr)
      wr.set_size(size)
      wr.set_allow_retry(0)
      wr.set_data_type(DataType.CUSTOM)
      wr.set_data([word])
      wr.set_get_response(True)
      wr.set_verbose(False)
      await self.start_seq_or_timeout(wr, self.env.rni_agent.sequencer)
      wrsp = wr.get_responses()
      assert len(wrsp) == 1
      assert int(wrsp[0].rsp_resp_err) == int(RespErr.OKAY)

      rd = vip_chi_read_seq(f"chi_rd_{line}", cfg=self.env.chi_cfg_t)
      rd.reset()
      rd.set_requests(1)
      rd.set_initial_addr(addr)
      rd.set_size(size)
      rd.set_allow_retry(0)
      rd.set_get_response(True)
      rd.set_verbose(False)
      await self.start_seq_or_timeout(rd, self.env.rni_agent.sequencer)
      rrsp = rd.get_responses()
      assert len(rrsp) == 1
      assert len(rrsp[0].data) == 1
      assert int(rrsp[0].dat_resp_err[0]) == int(RespErr.OKAY)
      for idx in range(nb):
        got = self.word_byte(rrsp[0].data[0], idx)
        exp = (0x50 + line + idx) & 0xff
        assert got == exp
