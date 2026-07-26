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
## pyUVM port of vip_mc/sv/vip_mc_axi4_types_pkg.sv.
##
################################################################################

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum


VIP_MC_AXI4_MAX_LENGTH_C = 256
VIP_MC_AXI4_4K_ADDRESS_BOUNDARY_C = 4096

VIP_MC_AXI4_RESP_OKAY_C = 0b00
VIP_MC_AXI4_RESP_EXOKAY_C = 0b01
VIP_MC_AXI4_RESP_SLVERR_C = 0b10
VIP_MC_AXI4_RESP_DECERR_C = 0b11

VIP_MC_AXI4_BURST_FIXED_C = 0b00
VIP_MC_AXI4_BURST_INCR_C = 0b01
VIP_MC_AXI4_BURST_WRAP_C = 0b10

VIP_MC_AXI4_SIZE_1B_C = 0b000
VIP_MC_AXI4_SIZE_2B_C = 0b001
VIP_MC_AXI4_SIZE_4B_C = 0b010
VIP_MC_AXI4_SIZE_8B_C = 0b011
VIP_MC_AXI4_SIZE_16B_C = 0b100
VIP_MC_AXI4_SIZE_32B_C = 0b101
VIP_MC_AXI4_SIZE_64B_C = 0b110
VIP_MC_AXI4_SIZE_128B_C = 0b111


class VipMcAxi4Resp(IntEnum):
  OKAY = VIP_MC_AXI4_RESP_OKAY_C
  EXOKAY = VIP_MC_AXI4_RESP_EXOKAY_C
  SLVERR = VIP_MC_AXI4_RESP_SLVERR_C
  DECERR = VIP_MC_AXI4_RESP_DECERR_C


class VipMcAxi4Burst(IntEnum):
  FIXED = VIP_MC_AXI4_BURST_FIXED_C
  INCR = VIP_MC_AXI4_BURST_INCR_C
  WRAP = VIP_MC_AXI4_BURST_WRAP_C


@dataclass
class VipMcAxi4CfgT:
  AWID_WIDTH_P: int = 0
  ARID_WIDTH_P: int = 0
  ADDR_WIDTH_P: int = 0
  WDATA_BYTES_P: int = 0
  RDATA_BYTES_P: int = 0
  AWUSER_WIDTH_P: int = 0
  WUSER_WIDTH_P: int = 0
  BUSER_WIDTH_P: int = 0
  ARUSER_WIDTH_P: int = 0
  RUSER_WIDTH_P: int = 0


def vip_mc_axi4_size_bytes(axsize: int) -> int:
  return 1 << int(axsize)
