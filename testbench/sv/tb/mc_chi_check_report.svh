////////////////////////////////////////////////////////////////////////////////
//
// Local MC-testbench copy of the CHI checker report helper.
//
// This file is intentionally owned by the MC testbench.  The corresponding
// helper in vip_chi_agent is part of that agent's example testbench, not its
// reusable library core.  Keeping this copy local avoids a FuseSoC fileset
// entry that reaches outside the vip_mc example core directory.
//
////////////////////////////////////////////////////////////////////////////////

typedef enum {
  CHI_CHECK_SCOPE_MAIN_E,
  CHI_CHECK_SCOPE_SNP_E
} chi_check_scope_t;

function automatic bit chi_check_in_scope(
  input vip_chi_check_id_t id,
  input chi_check_scope_t  scope
);
  return (scope == CHI_CHECK_SCOPE_SNP_E) ? vip_chi_check_is_snp(id)
                                          : !vip_chi_check_is_snp(id);
endfunction

function automatic void chi_check_report_tallies(
  input string                   tag,
  input chi_check_scope_t        scope,
  input bit                      enabled    [VIP_CHI_CHK_NUM_E],
  input vip_chi_check_severity_t severity   [VIP_CHI_CHK_NUM_E],
  input int unsigned             pass_count [VIP_CHI_CHK_NUM_E],
  input int unsigned             fail_count [VIP_CHI_CHK_NUM_E]
);
  int unsigned not_exercised;
  int unsigned in_scope;

  not_exercised = 0;
  in_scope      = 0;

  for (int unsigned id = 0; id < int'(VIP_CHI_CHK_NUM_E); id++) begin
    if (!chi_check_in_scope(vip_chi_check_id_t'(id), scope)) begin
      continue;
    end
    if (!enabled[id]) begin
      continue;
    end
    in_scope++;

    if ((fail_count[id] > 0) && (severity[id] == VIP_CHI_CHK_SEV_ERROR_E)) begin
      uvm_pkg::uvm_report_error("VIP_CHI_CHECK", $sformatf(
        "%s: %s failed %0d time(s)",
        tag, vip_chi_check_name(vip_chi_check_id_t'(id)), fail_count[id]));
    end

    if ((pass_count[id] == 0) && (fail_count[id] == 0)) begin
      not_exercised++;
      uvm_pkg::uvm_report_info("VIP_CHI_CHECK", $sformatf(
        "VIP_CHI CHECK NOT EXERCISED: bind=%s rule=%s",
        tag, vip_chi_check_name(vip_chi_check_id_t'(id))), UVM_LOW);
    end
  end

  uvm_pkg::uvm_report_info("VIP_CHI_CHECK", $sformatf(
    "VIP_CHI CHECK VACUITY: bind=%s not_exercised=%0d of=%0d",
    tag, not_exercised, in_scope), UVM_LOW);
endfunction

bit chi_check_tag_claimed [string];

function automatic void chi_check_claim_tag(
  input string            run_name,
  input string            tag,
  input chi_check_scope_t scope
);
  string key;

  key = $sformatf("%s/%s/%s", run_name, tag, scope.name());
  if (chi_check_tag_claimed.exists(key)) begin
    uvm_pkg::uvm_report_error("VIP_CHI_CHECK", $sformatf(
      "check-tally tag '%s' was exported twice for scope %s in run %s: two binds under one name merge into one set of rows, and every per-bind question asked of the export afterwards is answered about the wrong interface",
      tag, scope.name(), run_name));
  end
  chi_check_tag_claimed[key] = 1'b1;
endfunction

function automatic void chi_check_export_opcode_csv(
  input string       tag,
  input int unsigned req_opcode_seen [128]
);
  string path;
  string run_name;
  int    fd;

  run_name = "unknown";
  void'($value$plusargs("UVM_TESTNAME=%s", run_name));

  if (!$value$plusargs("vip_chi_opcode_csv=%s", path)) begin
    return;
  end

  fd = $fopen(path, "r");
  if (fd == 0) begin
    fd = $fopen(path, "w");
    if (fd == 0) begin
      uvm_pkg::uvm_report_warning("VIP_CHI_CHECK", $sformatf(
        "could not open %s for the opcode-evidence export", path));
      return;
    end
    $fdisplay(fd, "run,bind,opcode,seen");
  end
  else begin
    $fclose(fd);
    fd = $fopen(path, "a");
    if (fd == 0) begin
      uvm_pkg::uvm_report_warning("VIP_CHI_CHECK", $sformatf(
        "could not append to %s for the opcode-evidence export", path));
      return;
    end
  end

  for (int unsigned op = 0; op < 128; op++) begin
    if (req_opcode_seen[op] != 0) begin
      $fdisplay(fd, "%s,%s,0x%02h,%0d", run_name, tag, op, req_opcode_seen[op]);
    end
  end

  $fclose(fd);
endfunction

function automatic void chi_check_export_csv(
  input string                   tag,
  input chi_check_scope_t        scope,
  input bit                      enabled    [VIP_CHI_CHK_NUM_E],
  input vip_chi_check_severity_t severity   [VIP_CHI_CHK_NUM_E],
  input int unsigned             pass_count [VIP_CHI_CHK_NUM_E],
  input int unsigned             fail_count [VIP_CHI_CHK_NUM_E]
);
  string path;
  string run_name;
  int    fd;

  run_name = "unknown";
  void'($value$plusargs("UVM_TESTNAME=%s", run_name));

  chi_check_claim_tag(run_name, tag, scope);

  if (!$value$plusargs("vip_chi_check_csv=%s", path)) begin
    return;
  end

  fd = $fopen(path, "r");
  if (fd == 0) begin
    fd = $fopen(path, "w");
    if (fd == 0) begin
      uvm_pkg::uvm_report_warning("VIP_CHI_CHECK", $sformatf(
        "could not open %s for the check-tally export", path));
      return;
    end
    $fdisplay(fd, "run,bind,check,enabled,severity,passes,fails");
  end
  else begin
    $fclose(fd);
    fd = $fopen(path, "a");
    if (fd == 0) begin
      uvm_pkg::uvm_report_warning("VIP_CHI_CHECK", $sformatf(
        "could not append to %s for the check-tally export", path));
      return;
    end
  end

  for (int unsigned id = 0; id < int'(VIP_CHI_CHK_NUM_E); id++) begin
    if (!chi_check_in_scope(vip_chi_check_id_t'(id), scope)) begin
      continue;
    end
    $fdisplay(fd, "%s,%s,%s,%0d,%s,%0d,%0d",
      run_name, tag, vip_chi_check_name(vip_chi_check_id_t'(id)),
      enabled[id], severity[id].name(), pass_count[id], fail_count[id]);
  end

  $fclose(fd);
endfunction
