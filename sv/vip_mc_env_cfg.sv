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
// vip_mc_env_cfg
//
// System-config aggregator for vip_mc. The testbench fills one object with the
// shared MC config, the device handle, and the per-port host interfaces, then
// hands that object to vip_mc through a single config_db set.
// -----------------------------------------------------------------------------

class vip_mc_env_cfg #(
  vip_dram_cfg_t    DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C,
  int               N_PORTS    = 1,
  vip_mc_port_cfg_t PORTS [N_PORTS]
  ) extends uvm_object;

  vip_mc_config          cfg;
  vip_dram #(DRAM_CFG_P) dram;
  virtual vip_mc_status_if #(N_PORTS) status_vif;
  vip_mc_vif_holder      vif_h [N_PORTS];

  `uvm_object_param_utils(vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(string name = "vip_mc_env_cfg");
    super.new(name);
    this.cfg = vip_mc_config::type_id::create("cfg");
    this.cfg.ensure_port_count(N_PORTS);
    this.cfg.addr_map_policy = vip_dram_default_addr_map(DRAM_CFG_P);

    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      if (this.cfg.ports[port_id].vif_key == "") begin
        this.cfg.ports[port_id].vif_key = $sformatf("vif_port%0d", port_id);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Register one type-erased host interface holder for a port.
  // ---------------------------------------------------------------------------
  function void register_vif(int port_id, vip_mc_vif_holder h);
    if (port_id < 0 || port_id >= N_PORTS) begin
      `uvm_fatal(get_name(), $sformatf(
        "Port id %0d out of range 0..%0d", port_id, N_PORTS - 1))
    end

    if (h == null) begin
      `uvm_fatal(get_name(), $sformatf(
        "register_vif(%0d) received a null holder", port_id))
    end

    if (h.proto != PORTS[port_id].proto) begin
      `uvm_fatal(get_name(), $sformatf(
        "register_vif(%0d) proto mismatch: holder=%s expected=%s",
        port_id, h.proto.name(), PORTS[port_id].proto.name()))
    end

    this.vif_h[port_id] = h;
  endfunction

  // ---------------------------------------------------------------------------
  // Publish this aggregator through config_db as the single vip_mc handoff.
  // ---------------------------------------------------------------------------
  function void apply(uvm_component ctxt, string inst = "*vip_mc*");
    this.validate();
    uvm_config_db #(vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS))::set(
      ctxt,
      inst,
      "env_cfg",
      this);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the aggregated config, device handle, and per-port interface map.
  // ---------------------------------------------------------------------------
  function void validate();
    longint unsigned max_addr;

    this.cfg.ensure_port_count(N_PORTS);
    this.cfg.validate(DRAM_CFG_P);

    if (this.dram == null) begin
      `uvm_fatal(get_name(), "dram handle is null")
    end

    max_addr = this.device_max_addr();

    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      if (this.vif_h[port_id] == null) begin
        `uvm_fatal(get_name(), $sformatf(
          "vif_h[%0d] is null", port_id))
      end

      if (this.vif_h[port_id].proto != PORTS[port_id].proto) begin
        `uvm_fatal(get_name(), $sformatf(
          "vif_h[%0d] proto mismatch: holder=%s expected=%s",
          port_id,
          this.vif_h[port_id].proto.name(),
          PORTS[port_id].proto.name()))
      end

      foreach (this.cfg.ports[port_id].regions[region_id]) begin
        if (this.cfg.ports[port_id].regions[region_id].hi > max_addr) begin
          `uvm_fatal(get_name(), $sformatf(
            "ports[%0d].regions[%0d] exceeds device address width (hi=0x%0h max=0x%0h)",
            port_id,
            region_id,
            this.cfg.ports[port_id].regions[region_id].hi,
            max_addr))
        end
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return the highest byte address representable by the DRAM geometry.
  // ---------------------------------------------------------------------------
  protected function longint unsigned device_max_addr();
    if (DRAM_CFG_P.ADDR_WIDTH_P >= 64) begin
      return '1;
    end
    return ((64'd1) << DRAM_CFG_P.ADDR_WIDTH_P) - 1;
  endfunction

endclass