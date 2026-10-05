#!/usr/bin/env python3
"""Strict local validation of GitHub metadata and non-secret certificate artifacts."""
import base64
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import sys

SHA = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
REQUIRED_JOBS = {
    "cornerstone-payroll": ["backend", "frontend", "browser", "Staging v2 configuration",
        "Publish staging v2 images (cornerstone-payroll-api, api, api/Dockerfile)",
        "Publish staging v2 images (cornerstone-payroll-web, web, web/Dockerfile)"],
    "aire-services": ["backend", "frontend", "staging-configuration", "publish-gate",
        "publish (aire-services-api, backend, backend/Dockerfile)",
        "publish (aire-services-web, frontend, frontend/Dockerfile)"],
}


def positive(value):
    return type(value) is int and value > 0


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON fields")
        result[key] = value
    return result


def load(path, limit=8 * 1024 * 1024):
    data = Path(path).read_bytes()
    if len(data) > limit:
        raise ValueError("Evidence exceeded its size limit")
    return json.loads(data, object_pairs_hook=unique_object)


def inventory(pages, key):
    if not isinstance(pages, list) or not pages or len(pages) > 10:
        raise ValueError("Workflow evidence pages are missing or exceed the bound")
    count, rows = None, []
    for page in pages:
        if not isinstance(page, dict) or type(page.get("total_count")) is not int:
            raise ValueError("Workflow inventory is malformed")
        total, chunk = page["total_count"], page.get(key)
        if total < 0 or total > 1000 or not isinstance(chunk, list):
            raise ValueError("Workflow inventory is malformed or exceeds the bound")
        if count is None:
            count = total
        if total != count or len(chunk) != min(100, max(count - len(rows), 0)):
            raise ValueError("Workflow inventory changed or has incomplete pages")
        if not all(isinstance(row, dict) and positive(row.get("id")) for row in chunk):
            raise ValueError("Workflow records have invalid identities")
        rows.extend(chunk)
    if len(rows) != count or len({row["id"] for row in rows}) != len(rows) or len(pages) != max(1, (count + 99) // 100):
        raise ValueError("Workflow inventory is incomplete or duplicated")
    return rows


def created(row):
    value = row.get("created_at")
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        raise ValueError("Workflow creation time is invalid")
    return datetime.fromisoformat(value.replace("Z", "+00:00")), row["id"]


def latest_run(pages, workflow, event, sha=None, title=None):
    rows = inventory(pages, "workflow_runs")
    for row in rows:
        if row.get("path") != ".github/workflows/" + workflow or row.get("event") != event or row.get("head_branch") != "staging-v2":
            raise ValueError("Workflow inventory contains a foreign workflow, event or branch")
        if not isinstance(row.get("head_sha"), str) or not SHA.fullmatch(row["head_sha"]) or not positive(row.get("run_attempt")):
            raise ValueError("Workflow inventory has an invalid SHA or attempt")
        if sha and row["head_sha"] != sha:
            raise ValueError("Exact candidate inventory contains a foreign SHA")
        created(row)
    matches = [row for row in rows if title is None or row.get("display_title") == title]
    if not matches:
        raise ValueError("No exact immutable staging workflow evidence")
    return max(matches, key=created)["id"]


def verify_run(run, workflow, event, run_id, sha=None, title=None):
    expected = {"id": run_id, "path": ".github/workflows/" + workflow, "event": event,
        "head_branch": "staging-v2", "status": "completed", "conclusion": "success"}
    if sha:
        expected["head_sha"] = sha
    if title:
        expected["display_title"] = title
    if not isinstance(run, dict) or any(run.get(key) != value for key, value in expected.items()):
        raise ValueError("Workflow is pending, failed or mismatched")
    if not positive(run.get("id")) or not positive(run.get("run_attempt")) or not isinstance(run.get("head_sha"), str) or not SHA.fullmatch(run["head_sha"]):
        raise ValueError("Workflow SHA or current attempt is invalid")
    return run["run_attempt"]


def verify_jobs(pages, repo, run):
    jobs = inventory(pages, "jobs")
    for job in jobs:
        if not positive(job.get("run_id")) or not positive(job.get("run_attempt")) or job.get("run_id") != run["id"] or job.get("run_attempt") != run["run_attempt"] or job.get("head_sha") != run["head_sha"] or job.get("head_branch") != "staging-v2":
            raise ValueError("Job evidence belongs to another run, attempt or candidate")
    for name in REQUIRED_JOBS[repo]:
        matches = [job for job in jobs if job.get("name") == name]
        if len(matches) != 1 or matches[0].get("status") != "completed" or matches[0].get("conclusion") != "success":
            raise ValueError("Exact quality gates and both image publications must succeed")


def unchanged(before, after):
    keys = ("id", "path", "event", "head_branch", "head_sha", "run_attempt", "status", "conclusion", "display_title")
    if any(before.get(key) != after.get(key) or type(before.get(key)) is not type(after.get(key)) for key in keys):
        raise ValueError("Workflow changed while its current attempt was verified")


def content_digest(value):
    if not isinstance(value, dict) or value.get("type") != "file" or value.get("encoding") != "base64" or type(value.get("size")) is not int:
        raise ValueError("Trusted workflow file evidence is malformed")
    data = base64.b64decode(value["content"].replace("\n", ""), validate=True)
    if len(data) != value["size"] or not 0 < len(data) <= 1024 * 1024:
        raise ValueError("Trusted workflow file evidence is incomplete")
    return hashlib.sha256(data).hexdigest()


def verify_certificate(run, certificate, result_path, payroll_sha, aire_sha, fixture, driver):
    expected = {"schema_version": 2, "certification": "passed", "lane": "real-http-synthetic-v2",
        "payroll_sha": payroll_sha, "aire_sha": aire_sha, "workflow_sha": run["head_sha"],
        "run_id": run["id"], "run_attempt": run["run_attempt"], "independent_producer": "passed"}
    if not isinstance(certificate, dict) or set(certificate) != set(expected) | {"independent_result_sha256"}:
        raise ValueError("Unsupported certificate schema; recertification is required")
    if any(certificate[key] != value or type(certificate[key]) is not type(value) for key, value in expected.items()):
        raise ValueError("Certificate evidence does not match this run and pair")
    digest = certificate["independent_result_sha256"]
    data = Path(result_path).read_bytes()
    if not isinstance(digest, str) or not DIGEST.fullmatch(digest) or len(data) > 65536 or hashlib.sha256(data).hexdigest() != digest:
        raise ValueError("Independent producer artifact hash does not match")
    result = load(result_path, 65536)
    keys = {"schema_version", "source", "passed", "payroll_sha", "synthetic_only", "actual_operator_acceptance",
        "hours", "gross", "fixture_sha256", "driver_sha256", "exact_issued_lines", "capabilities", "independent_policy", "actual_http_transport"}
    if not isinstance(result, dict) or set(result) != keys or type(result.get("schema_version")) is not int or result["schema_version"] != 1:
        raise ValueError("Independent result schema is unsupported")
    if result["source"] != "neutral_weekly_time" or result["payroll_sha"] != payroll_sha or result["passed"] is not True or result["synthetic_only"] is not True or result["actual_http_transport"] is not True or result["actual_operator_acceptance"] is not False:
        raise ValueError("Independent result is not passed real HTTP evidence for this candidate")
    if result["fixture_sha256"] != content_digest(fixture) or result["driver_sha256"] != content_digest(driver):
        raise ValueError("Independent fixture or driver is not pinned to the trusted workflow revision")
    if result["hours"] != {"total": 45, "regular": 40, "overtime": 5} or Decimal(result["gross"]) != Decimal("1187.50") or type(result["exact_issued_lines"]) is not int or result["exact_issued_lines"] != 5:
        raise ValueError("Independent hours, payroll or exact receipts did not pass")
    capabilities = result["capabilities"]
    if not isinstance(capabilities, list) or not all(isinstance(value, str) for value in capabilities) or sorted(capabilities) != sorted(["time_summary_v1", "payroll_calendar_v2", "finalized_batch_v2", "exact_line_receipts_v2"]):
        raise ValueError("Independent producer capability evidence changed")
    policy = result["independent_policy"]
    expected_policy = {"schema_version": "2.0", "start_date": "2026-10-05", "end_date": "2026-10-11", "pay_date": "2026-10-16",
        "time_zone": "UTC", "cutoff_rule": "before_pay_date", "cutoff_days": 2, "schedule_version": 1,
        "overtime_policy": {"schema_version": "2.0", "calculation": "weekly_only", "weekly_threshold_hours": 40.0, "workweek_start": "monday", "time_zone": "UTC"}}
    if not isinstance(policy, dict) or set(policy) != set(expected_policy) | {"cutoff_at"} or any(policy[key] != value or type(policy[key]) is not type(value) for key, value in expected_policy.items()):
        raise ValueError("Independent company policy evidence changed")
    if datetime.fromisoformat(policy["cutoff_at"].replace("Z", "+00:00")) != datetime(2026, 10, 14, 17, tzinfo=timezone.utc):
        raise ValueError("Independent cutoff evidence changed")


def main(args):
    mode = args[0]
    if mode == "candidate":
        print(latest_run(load(args[1]), args[3], "push", sha=args[2]))
    elif mode == "certificate-run":
        print(latest_run(load(args[1]), "quality.yml", "workflow_dispatch", title=f"Connected payroll {args[2]} + {args[3]}"))
    elif mode == "candidate-run":
        run = load(args[1])
        attempt = verify_run(run, args[4], "push", int(args[5]), sha=args[3])
        selected = next(row for row in inventory(load(args[2]), "workflow_runs") if row["id"] == run["id"])
        if selected["run_attempt"] != attempt:
            raise ValueError("Candidate attempt changed after inventory selection")
        print(attempt)
    elif mode == "selection":
        run = load(args[1])
        selected = next(row for row in inventory(load(args[2]), "workflow_runs") if row["id"] == run["id"])
        if selected["run_attempt"] != run["run_attempt"]:
            raise ValueError("Workflow attempt changed during final inventory verification")
    elif mode == "certificate-detail":
        print(verify_run(load(args[1]), "quality.yml", "workflow_dispatch", int(args[4]),
            title=f"Connected payroll {args[2]} + {args[3]}"))
    elif mode == "jobs":
        verify_jobs(load(args[1]), args[2], load(args[3]))
    elif mode == "unchanged":
        unchanged(load(args[1]), load(args[2]))
    elif mode == "certificate":
        run = load(args[1])
        verify_certificate(run, load(args[2], 65536), args[3], args[4], args[5], load(args[6]), load(args[7]))
        print(run["id"])
    else:
        raise ValueError("Unknown evidence validation mode")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError, IndexError, ArithmeticError, StopIteration, AttributeError) as error:
        reason = str(error) if type(error) is ValueError else type(error).__name__
        print(f"Release evidence rejected: {reason}; deployment held.", file=sys.stderr)
        sys.exit(1)
