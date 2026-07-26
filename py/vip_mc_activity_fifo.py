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
## pyUVM port of vip_mc/sv/vip_mc_activity_fifo.sv.
##
################################################################################

from __future__ import annotations

from collections import deque


class vip_mc_activity_fifo:

  def __init__(self, name="vip_mc_activity_fifo", state_changed_ev=None):
    self.name = name
    self.state_changed_ev = state_changed_ev
    self._item_q = deque()

  def _trigger(self) -> None:
    if self.state_changed_ev is None:
      return
    if hasattr(self.state_changed_ev, "trigger"):
      self.state_changed_ev.trigger()
    elif hasattr(self.state_changed_ev, "set"):
      self.state_changed_ev.set()

  def write(self, item) -> None:
    self._item_q.append(item)
    self._trigger()

  def try_get(self):
    if not self._item_q:
      return None
    return self._item_q.popleft()

  def get_nowait(self):
    item = self.try_get()
    if item is None:
      raise IndexError(f"{self.name} is empty")
    return item

  def flush(self) -> None:
    self._item_q.clear()

  def is_empty(self) -> bool:
    return len(self._item_q) == 0

  def used(self) -> int:
    return len(self._item_q)
