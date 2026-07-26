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
## pyUVM port of vip_mc/sv/vip_mc_cmd_entry.sv.
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import VipDramOp

from vip_mc_axi4_types_pkg import (
  VIP_MC_AXI4_BURST_INCR_C, VIP_MC_AXI4_RESP_OKAY_C,
)


class vip_mc_cmd_entry:

  def __init__(self, name="vip_mc_cmd_entry"):
    self.name = name
    self.tag = 0
    self.port_id = 0
    self.axi4_id = 0
    self.op = VipDramOp.RD
    self.addr = 0
    self.beats = 1
    self.axi_beats = 1
    self.axi_size_bytes = 1
    self.axi_burst = VIP_MC_AXI4_BURST_INCR_C
    self.captured_w_beats = 0
    self.has_explicit_rank = False
    self.rank = 0
    self.qos = 0
    self.qos_class = 0
    self.admit_time = 0.0
    self.admit_order = 0
    self.bypass_count = 0
    self.is_exclusive = False
    self.auser = 0
    self.wuser = 0
    self.wdata = []
    self.wstrb = []
    self.enqueue_time = 0.0
    self.pre_resolved = False
    self.resp = VIP_MC_AXI4_RESP_OKAY_C
    self.rdata = []
    self.first_beat_ready_time = 0.0
    self.last_beat_ready_time = 0.0
    self.completed = False
    self.merged_writes = []

  def clone(self, name=None):
    c = vip_mc_cmd_entry(name or self.name)
    c.do_copy(self)
    return c

  def do_copy(self, rhs) -> None:
    self.tag = rhs.tag
    self.port_id = rhs.port_id
    self.axi4_id = rhs.axi4_id
    self.op = rhs.op
    self.addr = rhs.addr
    self.beats = rhs.beats
    self.axi_beats = rhs.axi_beats
    self.axi_size_bytes = rhs.axi_size_bytes
    self.axi_burst = rhs.axi_burst
    self.captured_w_beats = rhs.captured_w_beats
    self.has_explicit_rank = rhs.has_explicit_rank
    self.rank = rhs.rank
    self.qos = rhs.qos
    self.qos_class = rhs.qos_class
    self.admit_time = rhs.admit_time
    self.admit_order = rhs.admit_order
    self.bypass_count = rhs.bypass_count
    self.is_exclusive = rhs.is_exclusive
    self.auser = rhs.auser
    self.wuser = rhs.wuser
    self.wdata = list(rhs.wdata)
    self.wstrb = list(rhs.wstrb)
    self.enqueue_time = rhs.enqueue_time
    self.pre_resolved = rhs.pre_resolved
    self.resp = rhs.resp
    self.rdata = list(rhs.rdata)
    self.first_beat_ready_time = rhs.first_beat_ready_time
    self.last_beat_ready_time = rhs.last_beat_ready_time
    self.completed = rhs.completed
    self.merged_writes = list(rhs.merged_writes)

  def convert2string(self) -> str:
    return (f"MC_CMD: port={self.port_id} id=0x{self.axi4_id:x} "
            f"op={self.op.name} addr=0x{self.addr:x} beats={self.beats} "
            f"qos_class={self.qos_class} tag=0x{self.tag:x}")
