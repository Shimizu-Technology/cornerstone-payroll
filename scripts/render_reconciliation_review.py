#!/usr/bin/env python3
"""Render a private static evidence packet; never approve or apply payroll history.

Inputs are an inventory report, its captured snapshot siblings, and the explicit
candidate manifest. Only whitelisted review fields enter the HTML. No raw JSON,
credentials, external resources, scripts, forms, or approval controls are embedded.
"""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path


FORMAT = "connected-payroll-inventory/1"


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def escaped(value):
    return html.escape("—" if value is None else str(value), quote=True)


def table(headers, rows):
    heading = "".join(f"<th scope='col'>{escaped(value)}</th>" for value in headers)
    body = "".join("<tr>" + "".join(f"<td>{escaped(value)}</td>" for value in row) + "</tr>" for row in rows)
    if not body:
        body = f"<tr><td colspan='{len(headers)}'>No records in this captured scope.</td></tr>"
    return f"<div class='scroll'><table><thead><tr>{heading}</tr></thead><tbody>{body}</tbody></table></div>"


def private_write(path, content):
    requested = Path(path).expanduser()
    if requested.is_symlink():
        raise ValueError("Private output cannot be a symbolic link")
    parent = requested.parent.resolve()
    if any((ancestor / ".git").exists() for ancestor in [parent, *parent.parents]):
        raise ValueError("Private output must be outside Git checkouts")
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = parent / requested.name
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(content)


def validate_inputs(report, payroll, source, manifest):
    if report.get("format") != FORMAT or report.get("approval_status") != "unapproved_review_packet" or report.get("apply_allowed") is not False:
        raise ValueError("Only unapproved inventory review packets are supported")
    values = {"payroll_snapshot": payroll, "source_snapshot": source, "candidate_manifest": manifest}
    for name, value in values.items():
        if report.get("hashes", {}).get(name) != fingerprint(value):
            raise ValueError("Input digest differs from inventory evidence")
    for name, snapshot in (("payroll", payroll), ("source", source)):
        metadata = snapshot.get("metadata", {})
        if metadata.get("read_only") != "on" or not metadata.get("captured_at") or not metadata.get("revision"):
            raise ValueError("Enforced read-only capture, time, and revision are required")
        if report.get("captures", {}).get(name) != metadata:
            raise ValueError("Capture metadata differs from inventory evidence")


def render(report, payroll, source, manifest):
    validate_inputs(report, payroll, source, manifest)
    identities = {str(row["employee_id"]): row for row in manifest["identity_links"]}
    by_source_user = {str(row["source_user_id"]): row for row in manifest["identity_links"]}
    users = {str(row["id"]): row for row in source["users"]}
    source_entries = {str(row["id"]): row for row in source["entries"]}
    items = {str(row["id"]): row for row in payroll["payroll_items"]}
    employees = {str(row["id"]): row for row in payroll["employees"]}
    candidates = [("historical_exact", row) for row in manifest["issued_entries"]]
    for case in manifest.get("classification_cases", []):
        candidates.extend(("classification_review", {**row, "payroll_item_id": case["payroll_item_id"], "source_user_uuid": case["source_user_uuid"]}) for row in case["source_entries"])
    candidates.extend(("existing_integration", row) for row in manifest.get("finalized_batch_entries", []))
    identity_by_uuid = {str(row["source_user_uuid"]).lower(): row for row in manifest["identity_links"]}

    def planned_identity(candidate):
        identity = identity_by_uuid.get(str(candidate.get("source_user_uuid") or "").lower())
        if identity:
            return identity
        # A legacy payable line can omit its UUID; its expected delivered check
        # identifies the planned employee, never the actual out-of-tenant row.
        check = next((row for row in manifest["delivered_checks"] if str(row["payroll_item_id"]) == str(candidate.get("payroll_item_id"))), {})
        return identities.get(str(check.get("employee_id")), {})

    def owner_name(candidate):
        return planned_identity(candidate).get("employee_name", "Planned owner unavailable")

    capture_rows = []
    for name in ("payroll", "source"):
        meta = report["captures"][name]
        capture_rows.append((name, meta["captured_at"], meta["revision"], meta["read_only"], ", ".join(meta.get("missing_tables", [])) or "None recorded", report["hashes"][name + "_snapshot"]))
    sections = ["<h2>Captured evidence</h2>", table(("Application", "Snapshot time", "Application revision", "DB read-only", "Missing evidence tables", "Snapshot SHA-256"), capture_rows),
                f"<p>Inventory generated: {escaped(report.get('generated_at'))}. Candidate manifest SHA-256: <code>{escaped(report['hashes']['candidate_manifest'])}</code>.</p>"]
    summary = report.get("summary", {})
    summary_keys = ("candidate_entries", "candidate_checks", "exceptions", "entries_requiring_owner_review", "source_entries_outside_candidate_inventory")
    sections.extend(["<h2>Inventory scope</h2>", table(("Measure", "Captured count"), [(key.replace("_", " "), summary.get(key)) for key in summary_keys])])

    exception_rows = []
    safe_details = ("expected_category", "actual_category", "entry_status", "approval_status", "overtime_status", "recorded_status", "recorded_payroll_item_id", "evidence", "tables", "check_number", "standalone_check_id")
    for exception in report["exceptions"]:
        matches = []
        for kind, candidate in candidates:
            identity = planned_identity(candidate)
            keys = {"source_time_entry_id": candidate.get("source_time_entry_id"), "payroll_item_id": candidate.get("payroll_item_id"), "source_user_id": identity.get("source_user_id"), "employee_id": identity.get("employee_id")}
            if any(key in exception and str(exception[key]) == str(value) for key, value in keys.items() if value is not None):
                matches.append((kind, candidate))
        if not matches:
            matches = [(None, {})]
        for kind, candidate in matches:
            entry_id = str(candidate.get("source_time_entry_id", exception.get("source_time_entry_id", "")))
            entry = source_entries.get(entry_id, {})
            identity = planned_identity(candidate) or identities.get(str(exception.get("employee_id"))) or by_source_user.get(str(exception.get("source_user_id"))) or {}
            details = [f"{key}: {json.dumps(exception[key], ensure_ascii=False) if isinstance(exception[key], (list, dict)) else exception[key]}" for key in safe_details if key in exception]
            target = employees.get(str(identity.get("employee_id")))
            if target and str(target.get("company_id")) != str(manifest["company_id"]):
                details.append(f"Planned employee ID {identity.get('employee_id')} belongs to company {target.get('company_id')}; other-company employee details withheld")
            exception_rows.append((exception["code"], identity.get("employee_name", "Packet-wide / unresolved owner"), entry_id or "—", candidate.get("payroll_item_id", exception.get("payroll_item_id")), kind, entry.get("work_date"), candidate.get("category_name"), entry.get("category_name"), entry.get("approval_status"), entry.get("lock_version"), "; ".join(details) or "Review captured evidence"))
    sections.extend(["<h2>Exceptions and affected candidates</h2>", "<p>Missing categories show the candidate expectation and the captured value. A missing captured value is shown as —. Installation or schema exceptions can affect the entire packet.</p>", table(("Exception", "Planned owner", "Source entry", "Payroll item", "Path", "Work date", "Expected category", "Captured category", "Captured approval", "Captured entry version", "Evidence details"), exception_rows)])

    check_rows = []
    for check in manifest["delivered_checks"]:
        item_id = str(check["payroll_item_id"])
        item = items.get(item_id)
        identity = identities.get(str(check["employee_id"]), {})
        events = [row for row in payroll["check_events"] if str(row["payroll_item_id"]) == item_id and row["event_type"] == "delivered" and row["check_number"] == check["check_number"]]
        dates = sorted(set(str(row.get("effective_on")) for row in events))
        status = "Recorded delivery event present" if events else "No recorded delivery event"
        if dates and any(value != str(check["delivered_on"]) for value in dates):
            status += "; dates conflict with candidate"
        blockers = sorted(set(row["code"] for row in report["exceptions"] if str(row.get("payroll_item_id")) == item_id))
        check_rows.append((identity.get("employee_name", "Planned owner unavailable"), item_id, check["check_number"], check["pay_period_id"], check["regular_hours"], check["overtime_hours"], check["net_pay"], check["delivered_on"], status, ", ".join(dates) or "—", "Missing item" if item is None else item.get("period_status"), ", ".join(blockers) or "See entry and packet-wide exceptions"))
    sections.extend([f"<h2>Historical check candidates ({len(check_rows)})</h2>", "<p>Expected delivery dates come from the candidate manifest. Recorded delivery means only that a matching captured check event exists; it does not establish payment, approval, or permission to apply this packet.</p>", table(("Planned owner", "Payroll item", "Check number", "Pay period", "Regular hours", "OT hours", "Net amount", "Expected delivery date", "Captured delivery evidence", "Recorded dates", "Captured period state", "Check exceptions"), check_rows)])

    candidate_rows = []
    results = {(str(row["source_time_entry_id"]), str(row["payroll_item_id"])): row for row in report["entries"]}
    for kind, candidate in candidates:
        entry_id = str(candidate["source_time_entry_id"])
        entry = source_entries.get(entry_id, {})
        result = results.get((entry_id, str(candidate["payroll_item_id"])), {})
        candidate_rows.append((owner_name(candidate), entry_id, candidate["payroll_item_id"], candidate.get("source_line_key"), kind, candidate.get("original_work_date"), entry.get("work_date"), candidate.get("source_time_entry_version"), entry.get("lock_version"), candidate.get("regular_hours"), candidate.get("overtime_hours"), "Required" if result.get("requires_owner_review", True) else "Check all packet-wide exceptions", ", ".join(result.get("blockers", []))))
    sections.extend([f"<h2>Candidate source entries ({len(candidate_rows)})</h2>", table(("Planned owner", "Source entry", "Payroll item", "Payable line key", "Path", "Expected work date", "Captured work date", "Candidate version", "Captured version", "Regular hours", "OT hours", "Owner review", "Inventory blockers"), candidate_rows)])

    outside_rows = []
    for entry_id in report["source_entries_outside_candidate_inventory"]:
        entry = source_entries.get(str(entry_id), {})
        user = users.get(str(entry.get("user_id")), {})
        attested = [row for row in source.get("payment_attestations", []) if str(row.get("source_time_entry_id")) == str(entry_id)]
        holds = sorted(set(str(row.get("status")) for row in attested))
        outside_rows.append((entry_id, user.get("name", "Missing captured owner"), entry.get("user_id"), entry.get("work_date"), entry.get("category_name"), entry.get("status"), entry.get("approval_status"), entry.get("overtime_status"), entry.get("hours"), entry.get("lock_version"), ", ".join(holds) or "No captured attestation"))
    sections.extend([f"<h2>Source entries outside the candidate inventory ({len(outside_rows)})</h2>", "<p>These records have no historical candidate allocation in this packet. Do not infer they were paid, unpaid, or approved. Reported payment remains held pending evidence; keep any pending_evidence attestation unresolved until its evidence is separately reviewed.</p>", table(("Source entry", "Captured owner", "Source user", "Work date", "Captured category", "Entry state", "Approval state", "OT state", "Hours", "Captured version", "Captured payment attestation state"), outside_rows)])
    return """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>Private AIRE / payroll evidence review</title><style>
body{font-family:system-ui,sans-serif;line-height:1.5;margin:2rem;color:#17212b;background:#fff}h1,h2{line-height:1.2}h2{margin-top:2rem}.notice{border:2px solid #943c0c;background:#fff6ed;padding:1rem}.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:.85rem}th,td{border:1px solid #c5cbd2;padding:.5rem;vertical-align:top;text-align:left}th{background:#edf1f5}code{overflow-wrap:anywhere}td{overflow-wrap:anywhere}@media print{body{margin:.5rem}.scroll{overflow:visible}thead{display:table-header-group}tr{break-inside:avoid}}
</style></head><body><h1>Private AIRE / payroll evidence review</h1>
<div class="notice"><strong>UNAPPROVED EVIDENCE PACKET — apply_allowed: false</strong>
<p>Reviewers: Leon and Chels. This static packet records captured evidence and candidate discrepancies. It does not submit approval, record delivery, establish payment, or authorize historical changes.</p>
<p>Resolve installation provenance, identity, category, approval, and check exceptions before any separately authorized apply. Owner-attested payment notes and documentary evidence require separate review; this report does not create or infer them.</p></div>
""" + "".join(sections) + "</body></html>\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--candidate-manifest", required=True)
    parser.add_argument("--output", required=True, help="New private HTML outside Git; never overwritten")
    args = parser.parse_args()
    report_path = Path(args.inventory)
    report = json.loads(report_path.read_text())
    payroll = json.loads(Path(str(report_path) + ".payroll.json").read_text())
    source = json.loads(Path(str(report_path) + ".source.json").read_text())
    manifest = json.loads(Path(args.candidate_manifest).read_text())
    private_write(args.output, render(report, payroll, source, manifest))
    print("Private HTML evidence packet written; unapproved, apply_allowed=false")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError):
        raise SystemExit("Private review could not be rendered; validate input evidence and output location") from None
