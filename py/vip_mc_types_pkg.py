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
## pyUVM port of vip_mc/sv/vip_mc_types_pkg.sv.
##
################################################################################

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum

from vip_mc_axi4_types_pkg import VipMcAxi4CfgT


class VipMcChiIssue(IntEnum):
  D = 0
  E = 1


@dataclass
class VipMcChiCfgT:
  issue: VipMcChiIssue = VipMcChiIssue.D
  NODE_ID_WIDTH_P: int = 0
  ADDR_WIDTH_P: int = 0
  DATA_BYTES_P: int = 0
  DATACHECK_EN_P: bool = False
  POISON_EN_P: bool = False
  MPAM_EN_P: bool = False
  PARITY_EN_P: bool = False


class VipMcProto(IntEnum):
  AXI4 = 0
  CHI = 1


@dataclass
class VipMcPortCfgT:
  proto: VipMcProto = VipMcProto.AXI4
  axi4: VipMcAxi4CfgT = field(default_factory=VipMcAxi4CfgT)
  chi: VipMcChiCfgT = field(default_factory=VipMcChiCfgT)


@dataclass(frozen=True)
class VipMcAddrRegionT:
  lo: int = 0
  hi: int = 0


class VipMcRefreshPolicy(IntEnum):
  PERIODIC = 0
  DEFERRED = 1


class VipMcStatusOp(IntEnum):
  NONE = 0
  RD = 1
  WR = 2
  REF = 3


class VipMcStatusRsp(IntEnum):
  NONE = 0
  OKAY = 1
  EXOKAY = 2
  SLVERR = 3
  DECERR = 4


class VipMcStatusPage(IntEnum):
  UNKNOWN = 0
  HIT = 1
  MISS = 2
  EMPTY = 3


class VipMcStatusStall(IntEnum):
  NONE = 0
  IN_RESET = 1
  NO_BUFFERED_INPUT = 2
  CMD_QUEUE_EMPTY = 3
  SAME_STREAM_BLOCKED = 4
  DEVICE_CREDIT_FULL = 5
  RSP_BUFFER_FULL = 6
  REF_STRICT_PRIORITY = 7


class VipMcStatusReject(IntEnum):
  NONE = 0
  DECERR_REGION = 1
  DECERR_4K = 2
  DECERR_ROW_SPAN = 3
  UNSUPPORTED_AXI_SHAPE = 4
  EXCLUSIVE_FAIL_LOCAL = 5
  SLVERR_LOCAL = 6


class VipMcStatusFeBlock(IntEnum):
  NONE = 0
  IN_RESET = 1
  AW_OUTSTANDING_FULL = 2
  AR_OUTSTANDING_FULL = 3
  AW_PENDING_FULL = 4
  WBUF_FULL = 5
  NO_WRITE_IN_FLIGHT = 6
  RSP_BUF_FULL = 7


def vip_mc_port_is_axi4(cfg: VipMcPortCfgT) -> bool:
  return cfg.proto == VipMcProto.AXI4


def vip_mc_port_is_chi(cfg: VipMcPortCfgT) -> bool:
  return cfg.proto == VipMcProto.CHI


def vip_mc_region_is_valid(region: VipMcAddrRegionT) -> bool:
  return region.lo <= region.hi


def vip_mc_addr_in_region(addr: int, region: VipMcAddrRegionT) -> bool:
  return region.lo <= int(addr) <= region.hi
