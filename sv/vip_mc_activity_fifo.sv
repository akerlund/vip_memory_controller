////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Åkerlund
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

// -----------------------------------------------------------------------------
// vip_mc_activity_fifo
//
// Small unbounded queue with an analysis export and an explicit wakeup event.
// Unlike uvm_tlm_analysis_fifo, the analysis_imp here is typed to this class,
// so the local write() implementation is the one that actually runs.
// -----------------------------------------------------------------------------
class vip_mc_activity_fifo #(
  type T = int
  ) extends uvm_component;

  uvm_analysis_imp #(T, vip_mc_activity_fifo #(T)) analysis_export;
  uvm_event                                          state_changed_ev;

  protected T item_q[$];
  protected int queued_count = 0;

  `uvm_component_param_utils(vip_mc_activity_fifo #(T))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
    this.analysis_export = new("analysis_export", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Enqueue one item and notify any backend thread waiting for new work.
  // ---------------------------------------------------------------------------
  function void write(input T t);
    this.item_q.push_back(t);
    this.queued_count++;
    if (this.state_changed_ev != null) begin
      this.state_changed_ev.trigger();
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return one queued item immediately if available.
  // ---------------------------------------------------------------------------
  function bit try_get(output T t);
    if (this.queued_count == 0) begin
      return 1'b0;
    end

    t = this.item_q.pop_front();
    this.queued_count--;
    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Block until one queued item is available, then return it.
  // ---------------------------------------------------------------------------
  task get(output T t);
    wait (this.queued_count > 0);
    t = this.item_q.pop_front();
    this.queued_count--;
  endtask

  // ---------------------------------------------------------------------------
  // Drop every queued item (reset choreography, §9). Does not notify waiters;
  // the backend flush triggers state_changed_ev once after draining all FIFOs.
  // ---------------------------------------------------------------------------
  function void flush();
    this.item_q.delete();
    this.queued_count = 0;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the queue is empty.
  // ---------------------------------------------------------------------------
  function bit is_empty();
    return (this.queued_count == 0);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of queued items.
  // ---------------------------------------------------------------------------
  function int used();
    return this.queued_count;
  endfunction

endclass