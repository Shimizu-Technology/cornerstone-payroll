#!/usr/bin/env python3
"""Capture private read-only snapshots and preflight historical payroll candidates.

This tool never applies a manifest, creates mappings, or records payment. Its
report is a review packet, not an authorization to pay or attest delivery.
"""
import argparse
import base64
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess


FORMAT = "connected-payroll-inventory/1"
STATUS_RANK = {name: index for index, name in enumerate(("imported", "committed", "payment_prepared", "payment_issued", "payment_failed", "payment_voided"))}


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def decimal(value):
    if value is None:
        raise ValueError("Missing numeric evidence")
    return Decimal(str(value)).quantize(Decimal("0.01"))


def enabled(value):
    return value is True or value in ("t", "true")


def event_order(event):
    instant = datetime.fromisoformat(event["occurred_at"].replace("Z", "+00:00"))
    if instant.tzinfo is None:
        instant = instant.replace(tzinfo=timezone.utc)
    return instant.astimezone(timezone.utc), STATUS_RANK[event["status"]], int(event["id"])


def latest_source_events(events):
    batches = {}
    for event in events:
        batches.setdefault(str(event.get("payroll_batch_id")), []).append(event)
    latest = []
    for candidates in batches.values():
        keys = {event.get("source_line_key") for event in candidates if event.get("source_line_key")} or {None}
        for key in keys:
            compatible = [event for event in candidates if not event.get("source_line_key") or event["source_line_key"] == key]
            latest.append(max(compatible, key=event_order))
    return latest


def normalize_name(value):
    return re.sub(r"[^a-z0-9]", "", str(value).lower())


def check_identity(value):
    reference = str(value or "").strip()
    return str(int(reference)) if reference.isdigit() else reference


def indexed(rows, key):
    result = {}
    for row in rows:
        identity = str(row[key])
        if identity in result:
            raise ValueError(f"Duplicate snapshot identity: {key}")
        result[identity] = row
    return result


def private_write(path, value):
    path = Path(path).expanduser().resolve()
    if any((parent / ".git").exists() for parent in [path.parent, *path.parents]):
        raise ValueError("Private reconciliation data must be outside Git checkouts")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def capture(ssh_target, folder, queries):
    if not re.fullmatch(r"[A-Za-z0-9_.@-]+", ssh_target):
        raise ValueError("Invalid SSH target")
    # No Rails boot: model callbacks, identity generation and background jobs
    # cannot run. Every SELECT shares one PostgreSQL read-only snapshot.
    program = '''require "pg"; require "json"; require "base64"
c = PG.connect(ENV.fetch("DATABASE_URL"))
begin
  c.exec("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
  c.exec("SET LOCAL statement_timeout = '20s'")
  data = {"metadata" => {"missing_tables" => [], "read_only" => c.exec("SHOW transaction_read_only").getvalue(0,0),
    "captured_at" => c.exec("SELECT transaction_timestamp()").getvalue(0,0),
    "revision" => ENV["RENDER_GIT_COMMIT"]}}
  QUERIES.each do |key, sql, optional_table|
    if optional_table && c.exec_params("SELECT to_regclass($1)", [optional_table]).getvalue(0,0).nil?
      data[key] = []
      data["metadata"]["missing_tables"] << optional_table
      next
    end
    begin
      rows = c.exec(sql).to_a
    rescue PG::Error => error
      warn JSON.generate({"failed_query" => key, "error_class" => error.class.name})
      raise
    end
    raise "Snapshot limit exceeded" if rows.length > 50000
    data[key] = rows
  end
  puts JSON.generate(data)
ensure
  c.exec("ROLLBACK") rescue nil
  c.close
end
'''.replace("QUERIES", 'JSON.parse(Base64.strict_decode64("' + base64.b64encode(json.dumps(queries).encode()).decode() + '"))')
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", ssh_target,
         f"cd {shlex.quote(folder)} && bundle exec ruby"],
        input=program, text=True, capture_output=True, timeout=120)
    if result.returncode:
        # Remote stderr may contain credentials or row values; keep it private.
        raise ValueError("Read-only snapshot capture failed; no report was written")
    snapshot = json.loads(result.stdout)
    if snapshot["metadata"]["read_only"] != "on":
        raise ValueError("Capture was not enforced read-only")
    return snapshot


def payroll_queries(company_id, source_id, candidate_employee_ids):
    company_id, source_id = int(company_id), int(source_id)
    extra_ids = ",".join(str(int(value)) for value in candidate_employee_ids) or "NULL"
    return [
        ["company", f"SELECT id,name FROM companies WHERE id={company_id}", None],
        ["source", f"SELECT id,company_id,name,source_type,active,to_jsonb(s)->>'connection_uuid' AS connection_uuid,to_jsonb(s)->>'expected_source_instance_id' AS expected_source_instance_id FROM time_tracking_sources s WHERE id={source_id} AND company_id={company_id}", None],
        ["employees", f"SELECT id,company_id,first_name||' '||last_name AS name,status FROM employees WHERE company_id={company_id} OR id IN ({extra_ids}) ORDER BY id LIMIT 50001", None],
        ["mappings", f"SELECT employee_id,company_id,source_user_id,source_user_uuid FROM time_tracking_employee_mappings WHERE time_tracking_source_id={source_id} ORDER BY id LIMIT 50001", None],
        ["payroll_items", f"SELECT i.id,i.company_id,i.employee_id,i.pay_period_id,i.check_number,i.net_pay,i.hours_worked AS regular_hours,i.overtime_hours,i.voided_at,p.status AS period_status FROM payroll_items i JOIN pay_periods p ON p.id=i.pay_period_id WHERE i.company_id={company_id} ORDER BY i.id LIMIT 50001", None],
        ["check_events", f"SELECT e.payroll_item_id,e.event_type,e.check_number,e.effective_on,e.evidence_type FROM check_events e JOIN payroll_items i ON i.id=e.payroll_item_id WHERE i.company_id={company_id} ORDER BY e.id LIMIT 50001", None],
        ["allocations", f"SELECT a.id,a.company_id,a.employee_id,a.payroll_item_id,a.source_time_entry_id,a.source_user_id,a.source_user_uuid,a.line_key,a.original_work_date,a.regular_hours,a.overtime_hours,i.external_batch_id,i.external_batch_checksum FROM time_tracking_entry_allocations a JOIN time_tracking_imports i ON i.id=a.time_tracking_import_id WHERE a.time_tracking_source_id={source_id} ORDER BY a.id LIMIT 50001", None],
        ["pay_periods", f"SELECT id,start_date,end_date,pay_date,status,cycle,run_purpose,correction_status,parallel_run FROM pay_periods WHERE company_id={company_id} ORDER BY id LIMIT 50001", None],
        ["manual_allocations", f"SELECT id,payroll_item_id,source_time_entry_id,source_user_uuid,status,regular_hours,overtime_hours FROM time_tracking_manual_allocations WHERE time_tracking_source_id={source_id} ORDER BY id LIMIT 50001", "time_tracking_manual_allocations"],
        ["schedules", f"SELECT id,effective_on,ends_on,frequency,pay_date_rule,payroll_cutoff_at_minutes,to_jsonb(s)->>'time_tracking_cutoff_rule' AS cutoff_rule,to_jsonb(s)->>'time_tracking_cutoff_days' AS cutoff_days FROM company_pay_schedules s WHERE company_id={company_id} ORDER BY id LIMIT 50001", None],
        ["standalone_checks", f"SELECT id,check_number,amount,voided_at FROM non_employee_checks WHERE company_id={company_id} ORDER BY id LIMIT 50001", None],
    ]


def source_queries():
    return [
        ["installation", "SELECT value AS source_instance_id FROM settings WHERE key='payroll_source_instance_id'", None],
        ["users", "SELECT id,payroll_integration_uuid AS uuid,first_name||' '||last_name AS name,is_active,time_tracking_enabled FROM users ORDER BY id LIMIT 50001", None],
        ["entries", "SELECT e.id,e.user_id,u.payroll_integration_uuid AS source_user_uuid,e.work_date,e.hours,e.lock_version,e.status,e.approval_status,e.overtime_status,e.time_category_id,c.name AS category_name FROM time_entries e LEFT JOIN users u ON u.id=e.user_id LEFT JOIN time_categories c ON c.id=e.time_category_id ORDER BY e.id LIMIT 50001", None],
        ["events", "SELECT id,payroll_batch_id,source_time_entry_id,source_user_uuid,status,external_payroll_item_id,occurred_at,to_jsonb(e)->>'source_line_key' AS source_line_key FROM payroll_entry_processing_events e ORDER BY id LIMIT 50001", None],
        ["manual_allocations", "SELECT id,time_entry_id AS source_time_entry_id,source_user_uuid,status,external_payroll_item_id,regular_hours,overtime_hours FROM payroll_manual_allocations ORDER BY id LIMIT 50001", "payroll_manual_allocations"],
        ["payment_attestations", "SELECT time_entry_id AS source_time_entry_id,source_user_uuid,status,hours FROM payroll_payment_attestations ORDER BY id LIMIT 50001", "payroll_payment_attestations"],
    ]


def build_inventory(payroll, source, manifest):
    for snapshot in (payroll, source):
        if snapshot.get("metadata", {}).get("read_only") != "on":
            raise ValueError("Snapshots must include enforced read-only capture metadata")
        if not snapshot["metadata"].get("captured_at") or not snapshot["metadata"].get("revision"):
            raise ValueError("Capture time and application revision are required")
    employees = indexed(payroll["employees"], "id")
    users = indexed(source["users"], "id")
    entries = indexed(source["entries"], "id")
    items = indexed(payroll["payroll_items"], "id")
    company_id = int(manifest["company_id"])
    exceptions, identities = [], {}

    def issue(code, **details):
        exceptions.append({"code": code, **details})

    if len(payroll["company"]) != 1 or int(payroll["company"][0]["id"]) != company_id or payroll["company"][0]["name"] != manifest["company_name"]:
        issue("company_identity_changed")
    if len(payroll["source"]) != 1 or int(payroll["source"][0]["id"]) != int(manifest["source_id"]) or int(payroll["source"][0]["company_id"]) != company_id:
        issue("source_identity_changed")
    elif payroll["source"][0].get("source_type") != "aire_services" or not enabled(payroll["source"][0].get("active")):
        issue("source_disabled_or_wrong_provider")
    installation = source["installation"]
    pin = payroll["source"][0].get("expected_source_instance_id") if payroll["source"] else None
    if len(installation) != 1 or not installation[0].get("source_instance_id"):
        issue("source_installation_not_recorded")
    elif not pin:
        issue("source_installation_not_pinned")
    elif pin.lower() != installation[0]["source_instance_id"].lower():
        issue("source_installation_changed")
    # Live agreement is not proof of the old candidate inventory's provenance.
    binding = manifest.get("capture_binding", {})
    candidate_instance = manifest.get("source_instance_id")
    if not candidate_instance or not binding.get("connection_uuid"):
        issue("candidate_installation_provenance_unverified")
    elif (not installation or candidate_instance.lower() != installation[0]["source_instance_id"].lower() or
          not payroll["source"] or binding["connection_uuid"] != payroll["source"][0].get("connection_uuid")):
        issue("candidate_installation_provenance_changed")
    if source["metadata"].get("missing_tables"):
        issue("source_payment_evidence_schema_missing", tables=source["metadata"]["missing_tables"])
    if "missing_tables" not in source["metadata"]:
        issue("source_payment_schema_availability_unknown")
    for key in ("events", "manual_allocations", "payment_attestations"):
        if key not in source:
            issue("source_payment_evidence_unavailable", evidence=key)

    seen_employee_ids, seen_source_ids = set(), set()
    for row in manifest["identity_links"]:
        employee_id, user_id = str(row["employee_id"]), str(row["source_user_id"])
        uuid = str(row["source_user_uuid"]).lower()
        if employee_id in seen_employee_ids or user_id in seen_source_ids or uuid in identities:
            raise ValueError("Candidate identity links are duplicated")
        seen_employee_ids.add(employee_id)
        seen_source_ids.add(user_id)
        identities[uuid] = row
        employee, user = employees.get(employee_id), users.get(user_id)
        if not employee or int(employee["company_id"]) != company_id:
            issue("payroll_identity_wrong_company_or_missing", employee_id=employee_id, source_user_id=user_id)
        elif normalize_name(employee["name"]) != normalize_name(row["employee_name"]) or employee["status"] != row["employee_status"]:
            issue("payroll_identity_changed", employee_id=employee_id, source_user_id=user_id)
        if not user or str(user["uuid"]).lower() != uuid:
            issue("source_employee_identity_changed", source_user_id=user_id)
        elif normalize_name(user.get("name")) != normalize_name(row.get("source_employee_name", row.get("source_user_name", row["employee_name"]))):
            issue("source_employee_name_review", source_user_id=user_id)
        if user and ((row["employee_status"] == "active" and (not enabled(user.get("is_active")) or not enabled(user.get("time_tracking_enabled")))) or (row["employee_status"] == "terminated" and enabled(user.get("time_tracking_enabled")))):
            issue("source_employee_state_review", source_user_id=user_id)
        for mapping in payroll["mappings"]:
            touches = str(mapping["employee_id"]) == employee_id or str(mapping["source_user_id"]) == user_id or str(mapping.get("source_user_uuid") or "").lower() == uuid
            if touches and (int(mapping["company_id"]) != company_id or str(mapping["employee_id"]) != employee_id or str(mapping["source_user_id"]) != user_id or (mapping.get("source_user_uuid") and str(mapping["source_user_uuid"]).lower() != uuid)):
                issue("existing_mapping_conflict", employee_id=employee_id, source_user_id=user_id)

    candidates = [("historical_exact", row) for row in manifest["issued_entries"]]
    for case in manifest.get("classification_cases", []):
        if sorted(str(x["source_time_entry_id"]) for x in case["source_entries"]) != sorted(str(x) for x in case["source_time_entry_ids"]):
            raise ValueError("Classification case entry list disagrees with its evidence")
        candidates.extend(("classification_review", {**row, "payroll_item_id": case["payroll_item_id"], "source_user_uuid": case["source_user_uuid"]}) for row in case["source_entries"])
    candidates.extend(("existing_integration", row) for row in manifest.get("finalized_batch_entries", []))
    seen, seen_lines, results = set(), set(), []
    covered_allocation_lines = set()
    legacy_binding_proposals = []
    for kind, candidate in candidates:
        entry_id, item_id = str(candidate["source_time_entry_id"]), str(candidate["payroll_item_id"])
        line_identity = (item_id, entry_id, candidate.get("source_line_key"))
        if (kind != "existing_integration" and entry_id in seen) or (kind == "existing_integration" and (line_identity in seen_lines or any(row["source_time_entry_id"] == entry_id and row["path"] != kind for row in results))):
            raise ValueError("A candidate source entry belongs to more than one reconciliation path")
        seen.add(entry_id)
        seen_lines.add(line_identity)
        entry, item = entries.get(entry_id), items.get(item_id)
        uuid = str(candidate.get("source_user_uuid") or "").lower()
        if not entry:
            issue("source_entry_missing", source_time_entry_id=entry_id)
        else:
            # Legacy imported allocations may lack UUIDs. Resolve ownership
            # through the captured source identity, never through a null UUID.
            identity = identities.get(uuid or str(entry["source_user_uuid"]).lower())
            if not identity or (uuid and str(entry["source_user_uuid"]).lower() != uuid):
                issue("source_entry_identity_changed", source_time_entry_id=entry_id)
            if not item or int(item["company_id"]) != company_id or not identity or str(item["employee_id"]) != str(identity["employee_id"]):
                issue("source_entry_payroll_owner_changed", source_time_entry_id=entry_id, payroll_item_id=item_id)
            if kind != "existing_integration" and (entry["work_date"] != candidate["original_work_date"] or decimal(entry["hours"]) != decimal(candidate["regular_hours"]) + decimal(candidate["overtime_hours"])):
                issue("source_entry_date_or_hours_changed", source_time_entry_id=entry_id)
            if candidate.get("source_time_entry_version") is not None and int(entry["lock_version"]) != int(candidate["source_time_entry_version"]):
                issue("source_entry_version_changed", source_time_entry_id=entry_id)
            if candidate.get("category_name") is not None and entry.get("category_name") != candidate["category_name"]:
                issue("source_entry_category_changed", source_time_entry_id=entry_id,
                      expected_category=candidate["category_name"], actual_category=entry.get("category_name"))
            if entry.get("status") != "completed" or entry.get("approval_status") != "approved" or entry.get("overtime_status") in ("pending", "denied"):
                issue("source_entry_approval_review", source_time_entry_id=entry_id,
                      entry_status=entry.get("status"), approval_status=entry.get("approval_status"), overtime_status=entry.get("overtime_status"))
        allocations = [row for row in payroll["allocations"] if str(row["source_time_entry_id"]) == entry_id]
        if kind == "existing_integration":
            matching = [row for row in allocations if item and int(row["company_id"]) == company_id and str(row["employee_id"]) == str(item["employee_id"]) and str(row["payroll_item_id"]) == item_id and decimal(row["regular_hours"]) == decimal(candidate["regular_hours"]) and decimal(row["overtime_hours"]) == decimal(candidate["overtime_hours"]) and str(row.get("source_user_uuid") or "").lower() == uuid and (not candidate.get("source_line_key") or row["line_key"] == candidate["source_line_key"])]
            if len(matching) != 1:
                issue("existing_integration_allocation_changed", source_time_entry_id=entry_id)
            elif not uuid:
                issue("legacy_identity_binding_required", source_time_entry_id=entry_id)
                legacy_binding_proposals.append({"allocation_id": matching[0].get("id"), "source_time_entry_id": entry_id,
                    "source_user_uuid": entry.get("source_user_uuid") if entry else None,
                    "source_time_entry_version": int(entry["lock_version"]) if entry else None,
                    "source_line_key": matching[0].get("line_key"), "batch_id": matching[0].get("external_batch_id"),
                    "batch_checksum": matching[0].get("external_batch_checksum"), "approval_status": "unapproved"})
            if len(matching) == 1:
                covered_allocation_lines.add((item_id, entry_id, matching[0].get("line_key")))
        elif allocations:
            issue("historical_candidate_already_integrated", source_time_entry_id=entry_id)
        manual = [row for row in payroll.get("manual_allocations", []) if str(row["source_time_entry_id"]) == entry_id and row["status"] != "voided"]
        for row in manual:
            if str(row["payroll_item_id"]) != item_id or str(row["source_user_uuid"]).lower() != uuid or decimal(row["regular_hours"]) != decimal(candidate["regular_hours"]) or decimal(row["overtime_hours"]) != decimal(candidate["overtime_hours"]):
                issue("historical_allocation_conflict", source_time_entry_id=entry_id)
        latest_events = latest_source_events([event for event in source.get("events", []) if str(event["source_time_entry_id"]) == entry_id])
        for event in latest_events:
            if event["status"] == "payment_voided":
                continue
            if str(event.get("external_payroll_item_id")) != item_id or (event.get("source_user_uuid") and str(event["source_user_uuid"]).lower() != str(entry.get("source_user_uuid") if entry else uuid).lower()):
                issue("source_payment_receipt_conflict", source_time_entry_id=entry_id, recorded_payroll_item_id=event.get("external_payroll_item_id"))
            elif kind != "existing_integration":
                issue("historical_candidate_has_integration_receipt", source_time_entry_id=entry_id, recorded_status=event["status"])
        for row in source.get("manual_allocations", []):
            if str(row["source_time_entry_id"]) != entry_id or row["status"] == "voided":
                continue
            if str(row.get("external_payroll_item_id")) != item_id or str(row["source_user_uuid"]).lower() != uuid or decimal(row["regular_hours"]) != decimal(candidate["regular_hours"]) or decimal(row["overtime_hours"]) != decimal(candidate["overtime_hours"]):
                issue("source_manual_payment_conflict", source_time_entry_id=entry_id)
        if any(str(row["source_time_entry_id"]) == entry_id and row["status"] == "pending_evidence" for row in source.get("payment_attestations", [])):
            issue("source_payment_evidence_hold", source_time_entry_id=entry_id)
        deliveries = [row for row in payroll["check_events"] if str(row["payroll_item_id"]) == item_id and row["event_type"] == "delivered" and item and row["check_number"] == item["check_number"]]
        results.append({"source_time_entry_id": entry_id, "payroll_item_id": item_id, "path": kind,
                        "source_line_key": candidate.get("source_line_key"),
                        "source_user_id": str(entry.get("user_id")) if entry else None,
                        "employee_id": str(item.get("employee_id")) if item else None,
                        "source_version": entry.get("lock_version") if entry else None,
                        "recorded_delivery": bool(deliveries), "requires_owner_review": not bool(deliveries) or kind == "classification_review"})

    by_item = {}
    finalized_items = set()
    for kind, row in candidates:
        by_item.setdefault(str(row["payroll_item_id"]), []).append((kind, row))
        if kind == "existing_integration":
            finalized_items.add(str(row["payroll_item_id"]))
    for item_id, rows in by_item.items():
        item = items.get(item_id)
        if not item:
            continue
        regular = sum((decimal(row["regular_hours"]) for _, row in rows), Decimal("0"))
        overtime = sum((decimal(row["overtime_hours"]) for _, row in rows), Decimal("0"))
        if regular + overtime != decimal(item["regular_hours"]) + decimal(item["overtime_hours"]):
            issue("candidate_check_source_hours_incomplete", payroll_item_id=item_id,
                  candidate_total_hours=str(regular + overtime), recorded_total_hours=str(decimal(item["regular_hours"]) + decimal(item["overtime_hours"])))
        elif all(kind != "classification_review" for kind, _ in rows) and (regular != decimal(item["regular_hours"]) or overtime != decimal(item["overtime_hours"])):
            issue("candidate_check_classification_review_required", payroll_item_id=item_id)
    for allocation in payroll["allocations"]:
        line = (str(allocation["payroll_item_id"]), str(allocation["source_time_entry_id"]), allocation.get("line_key"))
        if line[0] in finalized_items and line not in covered_allocation_lines:
            issue("finalized_check_allocation_omitted", payroll_item_id=line[0], source_time_entry_id=line[1], source_line_key=line[2])

    check_ids = set()
    for row in manifest["delivered_checks"]:
        key = str(row["payroll_item_id"])
        if key in check_ids:
            raise ValueError("Candidate checks are duplicated")
        check_ids.add(key)
        item = items.get(key)
        if not item or int(item["company_id"]) != company_id or str(item["employee_id"]) != str(row["employee_id"]) or str(item["pay_period_id"]) != str(row["pay_period_id"]) or item["check_number"] != row["check_number"] or item["period_status"] != "committed" or item.get("voided_at") or any(decimal(item[field]) != decimal(row[field]) for field in ("net_pay", "regular_hours", "overtime_hours")):
            issue("candidate_check_changed", payroll_item_id=key)
        deliveries = [event for event in payroll["check_events"] if str(event["payroll_item_id"]) == key and event["event_type"] == "delivered" and event["check_number"] == row["check_number"]]
        if any(event["effective_on"] != row["delivered_on"] for event in deliveries):
            issue("candidate_delivery_date_conflict", payroll_item_id=key)
    if any(str(row["payroll_item_id"]) not in check_ids for _, row in candidates):
        raise ValueError("Candidate entries lack a referenced check")
    for check in payroll["standalone_checks"]:
        if not check.get("voided_at") and check.get("check_number") and any(check_identity(item["check_number"]) == check_identity(check["check_number"]) and not item.get("voided_at") and item["period_status"] == "committed" for item in items.values()):
            issue("active_standalone_payroll_check_overlap", standalone_check_id=str(check["id"]), check_number=check["check_number"])
    source_not_in_inventory = [str(entry["id"]) for entry in source["entries"] if str(entry["id"]) not in seen]
    regular_periods = [row for row in payroll.get("pay_periods", []) if row["status"] == "committed" and row["cycle"] == "regular" and row["run_purpose"] == "regular" and not row.get("correction_status") and not enabled(row.get("parallel_run"))]
    history_through = max((row["end_date"] for row in regular_periods), default=None)
    uncovered_history = [str(entry["id"]) for entry in source["entries"] if history_through and entry["work_date"] <= history_through and str(entry["id"]) not in seen]
    if uncovered_history:
        issue("historical_scope_incomplete", through_work_date=history_through, source_entry_count=len(uncovered_history))
    for entry in source["entries"]:
        if entry.get("user_id") is None or not entry.get("source_user_uuid"):
            issue("source_entry_owner_missing", source_time_entry_id=str(entry["id"]))
    global_blockers = [issue["code"] for issue in exceptions if not any(key in issue for key in ("source_time_entry_id", "payroll_item_id", "source_user_id", "employee_id", "standalone_check_id"))]
    for row in results:
        blockers = [issue["code"] for issue in exceptions if any(str(issue[key]) == row.get(key) for key in ("source_time_entry_id", "payroll_item_id", "source_user_id", "employee_id") if key in issue)]
        row["blockers"] = sorted(set(global_blockers + blockers))
        row["valid_current_delivery"] = row["recorded_delivery"] and not row["blockers"]
        row["requires_owner_review"] = not row["valid_current_delivery"] or row["path"] == "classification_review"
    return {"format": FORMAT, "generated_at": datetime.now(timezone.utc).isoformat(),
            "approval_status": "unapproved_review_packet", "apply_allowed": False,
            "captures": {"payroll": payroll["metadata"], "source": source["metadata"]},
            "hashes": {"payroll_snapshot": fingerprint(payroll), "source_snapshot": fingerprint(source), "candidate_manifest": fingerprint(manifest)},
            "summary": {"candidate_entries": len(seen), "candidate_lines": len(results), "paths": dict(Counter(row["path"] for row in results)),
                        "candidate_checks": len(check_ids), "exceptions": len(exceptions),
                        "exception_types": dict(Counter(row["code"] for row in exceptions)),
                        "entries_requiring_owner_review": sum(row["requires_owner_review"] for row in results),
                        "source_entries_outside_candidate_inventory": len(source_not_in_inventory)},
            "history_through_work_date": history_through, "uncovered_historical_entries": uncovered_history,
            "legacy_identity_binding_proposals": legacy_binding_proposals,
            "exceptions": exceptions, "entries": results, "source_entries_outside_candidate_inventory": source_not_in_inventory}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-manifest", required=True)
    parser.add_argument("--output", required=True, help="New private report outside Git; existing files are never overwritten")
    parser.add_argument("--payroll-snapshot")
    parser.add_argument("--source-snapshot")
    parser.add_argument("--payroll-ssh")
    parser.add_argument("--source-ssh")
    parser.add_argument("--payroll-folder", default="/opt/render/project/src/api")
    parser.add_argument("--source-folder", default="/opt/render/project/src/backend")
    args = parser.parse_args()
    with open(args.candidate_manifest) as stream:
        manifest = json.load(stream)
    if args.payroll_snapshot and args.source_snapshot and not (args.payroll_ssh or args.source_ssh):
        payroll = json.loads(Path(args.payroll_snapshot).read_text())
        source = json.loads(Path(args.source_snapshot).read_text())
    elif args.payroll_ssh and args.source_ssh and not (args.payroll_snapshot or args.source_snapshot):
        payroll = capture(args.payroll_ssh, args.payroll_folder, payroll_queries(manifest["company_id"], manifest["source_id"], [row["employee_id"] for row in manifest["identity_links"]]))
        source = capture(args.source_ssh, args.source_folder, source_queries())
        private_write(args.output + ".payroll.json", payroll)
        private_write(args.output + ".source.json", source)
    else:
        parser.error("Supply either both snapshot files or both read-only SSH targets")
    report = build_inventory(payroll, source, manifest)
    private_write(args.output, report)
    print(json.dumps({"format": FORMAT, "apply_allowed": False, "summary": report["summary"]}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.TimeoutExpired) as error:
        # Do not echo employee rows, connection strings, or remote diagnostics.
        raise SystemExit("Inventory could not be generated; validate private inputs and capture metadata") from error
