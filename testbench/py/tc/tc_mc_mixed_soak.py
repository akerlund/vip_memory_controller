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
import os

import cocotb
from cocotb.triggers import Combine, RisingEdge
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
from mc_equiv_model import mc_equiv_model
from mc_mixed_soak_gen import beat_addr
from mc_mixed_soak_gen import mc_mixed_soak_gen
from mc_mixed_tb_env import mc_mixed_tb_env


class _ErrorCounter(logging.Handler):

  def __init__(self):
    super().__init__(level=logging.ERROR)
    self.count = 0

  def emit(self, record):
    if record.levelno >= logging.ERROR:
      self.count += 1


class tc_mc_mixed_soak(uvm_test):
  """Randomized AXI4 + CHI-D traffic over one shared controller backend.

  The generator and the SV twin use the same LCG draw order. Each protocol has
  a disjoint line window and its own reference model, so concurrent arbitration
  cannot make the expected data order ambiguous.
  """

  # Calibrated on the reference Verilator flow: 1500 requests per port is
  # approximately 60 seconds on the development host.
  REQUESTS = 1500

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.env = None
    self._err_handler = None
    self._models = None
    self._writes = [0, 0]
    self._reads = [0, 0]

  def build_phase(self):
    self.env = mc_mixed_tb_env("env", self)

  def end_of_elaboration_phase(self):
    self._err_handler = _ErrorCounter()
    self.add_logging_handler_hier(self._err_handler)

  async def run_phase(self):
    self.raise_objection()
    try:
      await self.wait_reset_and_settle()

      count_per_port = int(os.environ.get("MC_MIXED_SOAK_TXNS", self.REQUESTS))
      seed = int(os.environ.get("MC_MIXED_SOAK_SEED", 1))
      line_bytes = int(self.env.mc_axi4_cfg_t.WDATA_BYTES_P)
      gen = mc_mixed_soak_gen(line_bytes=line_bytes)
      gen.set_seed(seed)
      axi_txns, chi_txns = gen.generate_program(count_per_port)
      self._models = [mc_equiv_model(), mc_equiv_model()]
      self._models[0].clear()
      self._models[1].clear()

      self.logger.info(
          f"Mixed soak: {count_per_port} transactions per port, seed {seed}, "
          "AXI4 + CHI-D concurrent")

      axi_task = cocotb.start_soon(self.drive_axi4(axi_txns))
      chi_task = cocotb.start_soon(self.drive_chi(chi_txns))
      await Combine(axi_task, chi_task)

      self.logger.info(
          f"Mixed soak complete: AXI4 {self._writes[0]} writes / "
          f"{self._reads[0]} reads, CHI-D {self._writes[1]} writes / "
          f"{self._reads[1]} reads")
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

  async def start_seq(self, seq, sequencer):
    await seq.start(sequencer)

  @staticmethod
  def bytes_to_int(data) -> int:
    value = 0
    for idx, byte in enumerate(data):
      value |= (int(byte) & 0xff) << (8 * idx)
    return value

  @staticmethod
  def int_to_bytes(value: int, nbytes: int):
    return [
        (int(value) >> (8 * idx)) & 0xff
        for idx in range(int(nbytes))
    ]

  async def drive_axi4(self, txns):
    nb = int(self.env.mc_axi4_cfg_t.WDATA_BYTES_P)
    model = self._models[0]
    bus = self.env.axi4_vif

    for idx, txn in enumerate(txns):
      for _ in range(txn.gap_cycles):
        await RisingEdge(bus.clk)

      if txn.is_write:
        data_beats = []
        strb_beats = []
        size = (txn.size_bytes - 1).bit_length()
        for beat in range(txn.beats):
          ba = beat_addr(txn, beat)
          lane = ba % nb
          word = 0
          strb = 0
          for byte in range(txn.size_bytes):
            word |= txn.payload[beat * txn.size_bytes + byte] << (
                8 * (lane + byte))
            strb |= 1 << (lane + byte)
          data_beats.append(word)
          strb_beats.append(strb)

        wr_seq = vip_axi4_write_seq(
            f"axi4_soak_wr_{idx}", self.env.axi4_agent_cfg_t)
        wr_seq.reset()
        wr_seq.set_awid(txn.axi_id)
        wr_seq.set_axaddr(txn.addr)
        wr_seq.set_axlen(txn.beats - 1)
        wr_seq.set_axsize(size)
        wr_seq.set_axburst(txn.burst)
        wr_seq.set_axqos(txn.qos)
        wr_seq.set_requests(1)
        wr_seq.set_get_wr_response(True)
        wr_seq.set_wdata_type(Axi4DataType.CUSTOM)
        wr_seq.set_wstrb_type(Axi4StrbType.CUSTOM)
        wr_seq.set_wdata(data_beats)
        wr_seq.set_wstrb(strb_beats)
        await self.start_seq(wr_seq, self.env.man_agent.sequencer)
        responses = wr_seq.get_wr_responses()
        assert len(responses) == 1
        assert int(responses[0].bresp) == VIP_MC_AXI4_RESP_OKAY_C
        for beat in range(txn.beats):
          ba = beat_addr(txn, beat)
          model.write(ba, txn.payload[
              beat * txn.size_bytes:(beat + 1) * txn.size_bytes])
        self._writes[0] += 1
      else:
        size = (txn.size_bytes - 1).bit_length()
        rd_seq = vip_axi4_read_seq(
            f"axi4_soak_rd_{idx}", self.env.axi4_agent_cfg_t)
        rd_seq.reset()
        rd_seq.set_arid(txn.axi_id)
        rd_seq.set_axaddr(txn.addr)
        rd_seq.set_axlen(txn.beats - 1)
        rd_seq.set_axsize(size)
        rd_seq.set_axburst(txn.burst)
        rd_seq.set_axqos(txn.qos)
        rd_seq.set_requests(1)
        rd_seq.set_get_rd_response(True)
        await self.start_seq(rd_seq, self.env.man_agent.sequencer)
        responses = rd_seq.get_rd_responses()
        assert len(responses) == 1
        assert len(responses[0].rdata) == txn.beats
        assert int(responses[0].rresp) == VIP_MC_AXI4_RESP_OKAY_C
        for beat in range(txn.beats):
          ba = beat_addr(txn, beat)
          lane = ba % nb
          got = self.int_to_bytes(responses[0].rdata[beat] >> (8 * lane),
                                  txn.size_bytes)
          model.check_read(ba, got,
                           f"mixed soak AXI4 txn {idx} beat {beat}")
        self._reads[0] += 1

  async def drive_chi(self, txns):
    nb = int(self.env.mc_chi_cfg_t.DATA_BYTES_P)
    size = (nb - 1).bit_length()
    model = self._models[1]
    bus = self.env.rni_vif

    for idx, txn in enumerate(txns):
      for _ in range(txn.gap_cycles):
        await RisingEdge(bus.clk)

      if txn.is_write:
        wr_seq = vip_chi_write_seq(
            f"chi_soak_wr_{idx}", cfg=self.env.chi_cfg_t)
        wr_seq.reset()
        wr_seq.set_requests(1)
        wr_seq.set_initial_addr(txn.addr)
        wr_seq.set_size(size)
        wr_seq.set_qos(txn.qos)
        wr_seq.set_data_type(DataType.CUSTOM)
        wr_seq.set_data([self.bytes_to_int(txn.payload)])
        wr_seq.set_get_response(True)
        wr_seq.set_verbose(False)
        await self.start_seq(wr_seq, self.env.rni_agent.sequencer)
        responses = wr_seq.get_responses()
        assert len(responses) == 1
        assert int(responses[0].rsp_resp_err) == int(RespErr.OKAY)
        model.write(txn.addr, txn.payload)
        self._writes[1] += 1
      else:
        rd_seq = vip_chi_read_seq(
            f"chi_soak_rd_{idx}", cfg=self.env.chi_cfg_t)
        rd_seq.reset()
        rd_seq.set_requests(1)
        rd_seq.set_initial_addr(txn.addr)
        rd_seq.set_size(size)
        rd_seq.set_qos(txn.qos)
        rd_seq.set_get_response(True)
        rd_seq.set_verbose(False)
        await self.start_seq(rd_seq, self.env.rni_agent.sequencer)
        responses = rd_seq.get_responses()
        assert len(responses) == 1
        assert len(responses[0].data) == 1
        assert int(responses[0].dat_resp_err[0]) == int(RespErr.OKAY)
        got = self.int_to_bytes(responses[0].data[0], nb)
        model.check_read(txn.addr, got, f"mixed soak CHI txn {idx}")
        self._reads[1] += 1
