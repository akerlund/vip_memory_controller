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
## pyUVM port of vip_mc/sv/vip_mc_config.sv.
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import (
  VIP_DRAM_CFG_DEFAULT, clog2, vip_dram_default_addr_map,
)

from vip_mc_axi4_cfg import vip_mc_axi4_cfg
from vip_mc_chi_cfg import vip_mc_chi_cfg
from vip_mc_port_runtime_cfg import vip_mc_port_runtime_cfg
from vip_mc_types_pkg import VipMcRefreshPolicy, vip_mc_region_is_valid


class vip_mc_config:

  def __init__(self, name="vip_mc_config"):
    self.name = name
    self.axi4 = vip_mc_axi4_cfg("axi4")
    self.chi = vip_mc_chi_cfg("chi")
    self.max_outstanding_rd = 16
    self.max_outstanding_wr = 16
    self.qos_class_count = 1
    self.qos_aging_ns = 0.0
    self.fr_fcfs_enable = False
    self.fr_fcfs_starvation_cap = 0
    self.rd_wr_grouping_enable = False
    self.rd_wr_grouping_max = 0
    self.write_coalescing_enable = False
    self.ecc_enable = False
    self.rsp_buf_depth = 0
    self.max_inflight_to_device = -1
    self.addr_map_policy = vip_dram_default_addr_map(VIP_DRAM_CFG_DEFAULT)
    self.refresh_enabled = True
    self.refresh_policy = VipMcRefreshPolicy.PERIODIC
    self.refresh_max_deferred = 8
    self.tREFI_override = -1.0
    self.init_delay_enabled = False
    self.init_delay_ns = 0.0
    self.perf_counters_enabled = True
    self.honor_beat_timing = True
    self.ports = []

  def ensure_port_count(self, port_count: int) -> None:
    if port_count < 0:
      raise RuntimeError(f"[{self.name}] Port count must be >= 0 (got {port_count})")

    old = list(self.ports)
    self.ports = old[:port_count]
    while len(self.ports) < port_count:
      self.ports.append(vip_mc_port_runtime_cfg(f"port_cfg_{len(self.ports)}"))

    for port_id, port in enumerate(self.ports):
      if port is None:
        port = vip_mc_port_runtime_cfg(f"port_cfg_{port_id}")
        self.ports[port_id] = port
      if port.vif_key == "":
        port.vif_key = f"vif_port{port_id}"

  def validate(self, dram_cfg=VIP_DRAM_CFG_DEFAULT) -> None:
    if self.axi4 is None:
      raise RuntimeError(f"[{self.name}] axi4 config handle is null")
    if self.chi is None:
      raise RuntimeError(f"[{self.name}] chi config handle is null")
    self.chi.validate()

    if self.max_outstanding_rd < 0 or self.max_outstanding_wr < 0:
      raise RuntimeError(
          f"[{self.name}] Outstanding limits must be >= 0 "
          f"(rd={self.max_outstanding_rd} wr={self.max_outstanding_wr})")
    if self.qos_class_count < 1:
      raise RuntimeError(
          f"[{self.name}] qos_class_count must be >= 1 "
          f"(got {self.qos_class_count})")
    if self.refresh_max_deferred < 1:
      raise RuntimeError(
          f"[{self.name}] refresh_max_deferred must be >= 1 "
          f"(got {self.refresh_max_deferred})")
    if self.qos_aging_ns < 0.0:
      raise RuntimeError(
          f"[{self.name}] qos_aging_ns must be >= 0.0 "
          f"(got {self.qos_aging_ns:.3f})")
    if self.rd_wr_grouping_max < 0:
      raise RuntimeError(
          f"[{self.name}] rd_wr_grouping_max must be >= 0 "
          f"(got {self.rd_wr_grouping_max})")
    if self.rsp_buf_depth < 0:
      raise RuntimeError(
          f"[{self.name}] rsp_buf_depth must be >= 0 "
          f"(got {self.rsp_buf_depth})")
    if self.max_inflight_to_device < -1:
      raise RuntimeError(
          f"[{self.name}] max_inflight_to_device must be >= -1 "
          f"(got {self.max_inflight_to_device})")
    if self.max_inflight_to_device < 0:
      self.max_inflight_to_device = self.default_max_inflight_to_device(dram_cfg)

    if self.axi4.aw_outstanding_limit < 0 or self.axi4.ar_outstanding_limit < 0:
      raise RuntimeError(
          f"[{self.name}] AXI4 outstanding limits must be >= 0 "
          f"(aw={self.axi4.aw_outstanding_limit} "
          f"ar={self.axi4.ar_outstanding_limit})")
    if self.axi4.aw_pending_depth < 0 or self.axi4.w_data_buf_depth < 0:
      raise RuntimeError(
          f"[{self.name}] AXI4 buffer depths must be >= 0 "
          f"(aw_pending={self.axi4.aw_pending_depth} "
          f"w_data={self.axi4.w_data_buf_depth})")
    if len(self.axi4.decerr_addr_lo) != len(self.axi4.decerr_addr_hi):
      raise RuntimeError(
          f"[{self.name}] DECERR range vectors differ in size "
          f"(lo={len(self.axi4.decerr_addr_lo)} "
          f"hi={len(self.axi4.decerr_addr_hi)})")

    for i, (lo, hi) in enumerate(zip(self.axi4.decerr_addr_lo,
                                     self.axi4.decerr_addr_hi)):
      if lo > hi:
        raise RuntimeError(
            f"[{self.name}] DECERR range {i} has lo > hi "
            f"(lo=0x{lo:x} hi=0x{hi:x})")

    for i, q in enumerate(self.axi4.qos_class_map):
      if q < 0:
        raise RuntimeError(
            f"[{self.name}] qos_class_map[{i}] must be >= 0 (got {q})")
      if q >= self.qos_class_count:
        self.axi4.qos_class_map[i] = self.qos_class_count - 1

    for i, port in enumerate(self.ports):
      if port is None:
        raise RuntimeError(f"[{self.name}] ports[{i}] is null")
      if port.arb_weight < 0:
        raise RuntimeError(
            f"[{self.name}] ports[{i}].arb_weight must be >= 0 "
            f"(got {port.arb_weight})")
      for j, region in enumerate(port.regions):
        if not vip_mc_region_is_valid(region):
          raise RuntimeError(
              f"[{self.name}] ports[{i}].regions[{j}] has lo > hi "
              f"(lo=0x{region.lo:x} hi=0x{region.hi:x})")

    self.validate_addr_map(dram_cfg)

  @staticmethod
  def default_max_inflight_to_device(dram_cfg) -> int:
    total_banks = (dram_cfg.N_RANKS_P * dram_cfg.N_BANK_GROUPS_P *
                   dram_cfg.BANKS_PER_BG_P)
    return 1 if total_banks < 1 else int(total_banks)

  def validate_addr_map(self, dram_cfg) -> None:
    if dram_cfg.ADDR_WIDTH_P > 256:
      raise RuntimeError(
          f"[{self.name}] ADDR_WIDTH_P={dram_cfg.ADDR_WIDTH_P} exceeds "
          "vip_mc_config validation mask width")

    used_bits = set()
    self.validate_addr_slice(
        "byte", self.addr_map_policy.byte_lsb, clog2(dram_cfg.ROW_BYTES_P),
        dram_cfg.ADDR_WIDTH_P, used_bits)
    self.validate_addr_slice(
        "col", self.addr_map_policy.col_lsb, dram_cfg.COL_BITS_P,
        dram_cfg.ADDR_WIDTH_P, used_bits)
    self.validate_addr_slice(
        "bank", self.addr_map_policy.bank_lsb, clog2(dram_cfg.BANKS_PER_BG_P),
        dram_cfg.ADDR_WIDTH_P, used_bits)
    self.validate_addr_slice(
        "bg", self.addr_map_policy.bg_lsb, clog2(dram_cfg.N_BANK_GROUPS_P),
        dram_cfg.ADDR_WIDTH_P, used_bits)
    self.validate_addr_slice(
        "row", self.addr_map_policy.row_lsb, dram_cfg.ROW_BITS_P,
        dram_cfg.ADDR_WIDTH_P, used_bits)
    self.validate_addr_slice(
        "rank", self.addr_map_policy.rank_lsb, clog2(dram_cfg.N_RANKS_P),
        dram_cfg.ADDR_WIDTH_P, used_bits)

    for bit_idx in range(dram_cfg.ADDR_WIDTH_P):
      if bit_idx not in used_bits:
        raise RuntimeError(
            f"[{self.name}] addr_map_policy leaves address bit {bit_idx} "
            "uncovered")

  def validate_addr_slice(self, field_name: str, lsb: int, width: int,
                          addr_width: int, used_bits: set[int]) -> None:
    if width == 0:
      return
    if lsb < 0:
      raise RuntimeError(
          f"[{self.name}] addr_map_policy.{field_name}_lsb must be >= 0 "
          f"(got {lsb})")
    if (lsb + width) > addr_width:
      raise RuntimeError(
          f"[{self.name}] addr_map_policy.{field_name}_lsb={lsb} width={width} "
          f"exceeds ADDR_WIDTH_P={addr_width}")

    for bit_idx in range(lsb, lsb + width):
      if bit_idx in used_bits:
        raise RuntimeError(
            f"[{self.name}] addr_map_policy bit {bit_idx} overlaps while "
            f"placing {field_name}")
      used_bits.add(bit_idx)
