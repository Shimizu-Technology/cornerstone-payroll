#!/usr/bin/env python3
"""A disposable, independent HTTP producer for connected-payroll certification.

This is not a deployable time service. It binds only loopback, owns no real
people/payments, and advertises only the protocol operations implemented here.
Its weekly Monday/UTC policy deliberately differs from AIRE's policy.
"""
import argparse
import copy
from datetime import date, datetime, timedelta, timezone
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import threading
from urllib.parse import parse_qs, urlsplit
import uuid


def timestamp(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Timestamp requires a timezone")
    return result


def checksum(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()).hexdigest()


class Conflict(ValueError):
    pass


class Producer:
    SOURCE = "neutral_weekly_time"
    CAPABILITIES = ["time_summary_v1", "payroll_calendar_v2", "finalized_batch_v2", "exact_line_receipts_v2"]

    def __init__(self, config):
        self.secret = config["shared_secret"]
        self.installation = str(uuid.UUID(config["source_instance_id"]))
        self.employee_id = str(config.get("employee_id", 2))
        self.employee_uuid = str(uuid.UUID(config["employee_uuid"]))
        self.lock = threading.RLock()
        self.calendars = {}
        self.batches = {}
        self.events = {}
        self.receipt_runs = {}
        self.receipt_items = {}
        self.clock = timestamp(config["clock"])

    def profile(self):
        return {"protocol": "shimizu_time_payroll", "protocol_version": "1.0",
                "source_type": self.SOURCE, "source_instance_id": self.installation,
                "capabilities": self.CAPABILITIES,
                "policy_constraints": {"time_zones": ["UTC"], "workweek_starts": ["monday"],
                                       "cutoff_rules": ["before_pay_date"], "frequencies": ["weekly"]}}

    def envelope(self, value):
        return {"source": self.SOURCE, "integration": self.profile(), **value}

    def authenticate(self, headers):
        if not hmac.compare_digest(headers.get("X-Payroll-Shared-Secret", ""), self.secret):
            raise PermissionError("Invalid producer credentials")
        expected = headers.get("X-Payroll-Source-Instance-Id")
        if expected and expected != self.installation:
            raise PermissionError("Installation identity mismatch")

    def publish(self, external_id, body, key):
        if not key or key != body.get("publication_id"):
            raise Conflict("Publication idempotency key mismatch")
        uuid.UUID(external_id)
        uuid.UUID(key)
        if type(body.get("schedule_version")) is not int or body["schedule_version"] < 1:
            raise Conflict("Invalid calendar revision")
        start, end, payday = (date.fromisoformat(body[field]) for field in ("start_date", "end_date", "pay_date"))
        cutoff = timestamp(body["cutoff_at"])
        policy = body.get("overtime_policy")
        expected_policy = {"schema_version": "2.0", "calculation": "weekly_only", "weekly_threshold_hours": 40.0,
                           "workweek_start": "monday", "time_zone": "UTC"}
        if (body.get("schema_version") != "2.0" or start.weekday() != 0 or end != start + timedelta(days=6)
                or payday != end + timedelta(days=5) or body.get("time_zone") != "UTC"
                or body.get("cutoff_rule") != "before_pay_date" or body.get("cutoff_days") != 2
                or cutoff != datetime.combine(payday - timedelta(days=2), datetime.min.time(), timezone.utc) + timedelta(hours=17)
                or policy != expected_policy):
            raise Conflict("Unsupported confirmed company policy")
        if cutoff.tzinfo is None or cutoff <= self.clock:
            # A byte-identical already accepted publication may still be retried after freeze.
            prior = self.calendars.get(external_id)
            if not prior or prior["publication_id"] != key or checksum(prior["payload"]) != checksum(body):
                raise Conflict("Calendar cutoff has passed")
        prior = self.calendars.get(external_id)
        if prior:
            if prior["publication_id"] == key:
                if checksum(prior["payload"]) != checksum(body):
                    raise Conflict("Changed publication replay")
                return self.calendar_response(prior)
            if body["schedule_version"] <= prior["schedule_version"] or self.clock >= timestamp(prior["payload"]["cutoff_at"]):
                raise Conflict("Stale or frozen calendar revision")
        elif body.get("schedule_version") != 1:
            raise Conflict("Initial calendar revision must be one")
        row = {"external_pay_period_id": external_id, "publication_id": key,
               "schedule_version": body["schedule_version"], "payload": copy.deepcopy(body), "status": "scheduled"}
        self.calendars[external_id] = row
        return self.calendar_response(row)

    def calendar_response(self, row):
        return self.envelope({"payroll_calendar_period": {**row["payload"], "external_pay_period_id": row["external_pay_period_id"],
                                                         "status": row["status"], "lock_version": 0,
                                                         "batch_id": row.get("batch_id")}})

    def freeze_due(self):
        for row in self.calendars.values():
            body = row["payload"]
            if row["status"] == "finalized" or self.clock < timestamp(body["cutoff_at"]):
                continue
            batch_id = "NEUTRAL-PAY-" + row["external_pay_period_id"]
            start = date.fromisoformat(body["start_date"])
            lines = []
            for index in range(5):
                regular = 9.0 if index < 4 else 4.0
                lines.append({"source_time_entry_id": str(index + 1), "source_user_uuid": self.employee_uuid,
                              "line_key": "operations:2500", "source_kind": "current",
                              "original_work_date": (start + timedelta(days=index)).isoformat(),
                              "original_week_start": start.isoformat(), "source_category_id": "1",
                              "category": {"id": "1", "key": "operations", "name": "Operations"},
                              "total_hours": 9.0, "regular_hours": regular, "overtime_hours": 9.0 - regular})
            employee = {"source_user_id": self.employee_id, "source_user_uuid": self.employee_uuid,
                        "display_name": "Morgan Neutral", "email": "neutral-worker@example.test",
                        "adjustments": lines, "total_hours": 45.0, "regular_hours": 40.0, "overtime_hours": 5.0}
            payload = self.envelope({"schema_version": "2.0", "batch_id": batch_id,
                                    "start_date": body["start_date"], "end_date": body["end_date"],
                                    "cutoff_at": body["cutoff_at"], "generated_at": body["cutoff_at"],
                                    "employees": [employee], "exclusions": [],
                                    "issues": {key: 0 for key in ["missing_category_count", "negative_adjustment_count", "pending_approval_count",
                                                                 "denied_approval_count", "open_clock_count", "pending_overtime_count", "denied_overtime_count"]},
                                    "summary": {"employee_count": 1, "adjustment_count": 5, "exclusion_count": 0,
                                                "total_hours": 45.0, "regular_hours": 40.0, "overtime_hours": 5.0,
                                                "current_count": 5, "carryover_count": 0, "correction_count": 0}})
            payload["export"] = {"id": batch_id, "batch_id": batch_id, "readiness_status": "finalized",
                                 "cutoff_at": body["cutoff_at"], "finalized_at": self.clock.isoformat(),
                                 "checksum_algorithm": "SHA-256", "checksum_scope": "payload_without_export", "checksum": checksum(payload)}
            self.batches[batch_id] = payload
            row.update(status="finalized", batch_id=batch_id)

    def receipt(self, batch_id, body):
        payload = self.batches[batch_id]
        event_id = body["event_id"]
        if not isinstance(event_id, str) or not 1 <= len(event_id) <= 200 or any(ord(char) < 32 for char in event_id):
            raise Conflict("Invalid receipt event identity")
        key = (batch_id, event_id)
        if key in self.events:
            if checksum(self.events[key]) != checksum(body):
                raise Conflict("Changed receipt replay")
            return self.envelope({"accepted": True, "duplicate": True})
        if body.get("external_system") != "cornerstone_payroll" or body.get("status") not in {"imported", "committed", "payment_prepared", "payment_issued", "payment_failed", "payment_voided"}:
            raise Conflict("Invalid receipt state")
        occurred_at = datetime.fromisoformat(body["occurred_at"].replace("Z", "+00:00"))
        if occurred_at.tzinfo is None:
            raise Conflict("Receipt timestamp requires a timezone")
        run_id = str(body.get("external_pay_period_id", ""))
        if not run_id.isdecimal() or int(run_id) < 1:
            raise Conflict("Receipt payroll run identity is required")
        metadata = body.get("metadata", {})
        for field in ("pay_period_start", "pay_period_end", "pay_date"):
            expected = payload[field.replace("pay_period_", "") + "_date"] if field != "pay_date" else next(row["payload"]["pay_date"] for row in self.calendars.values() if row.get("batch_id") == batch_id)
            if metadata.get(field) != expected:
                raise Conflict("Receipt work period mismatch")
        if batch_id in self.receipt_runs and self.receipt_runs[batch_id] != run_id:
            raise Conflict("Receipt payroll run changed")
        item_binding = None
        if body.get("source_time_entry_id"):
            employee = payload["employees"][0]
            line = next((line for line in employee["adjustments"] if line["source_time_entry_id"] == body["source_time_entry_id"] and line["line_key"] == body.get("source_line_key")), None)
            if not line or body.get("source_user_uuid") != self.employee_uuid or body.get("contract_version") != "2.0" or body.get("source_kind") != line["source_kind"]:
                raise Conflict("Receipt source identity mismatch")
            item_id = str(body.get("external_payroll_item_id", ""))
            if not item_id.isdecimal() or int(item_id) < 1:
                raise Conflict("Receipt payroll item identity is required")
            item_binding = (batch_id, self.employee_uuid, line["source_time_entry_id"], line["line_key"])
            if item_binding in self.receipt_items and self.receipt_items[item_binding] != item_id:
                raise Conflict("Receipt payroll item changed")
            for field in ("total_hours", "regular_hours", "overtime_hours"):
                if float(body.get(field, "nan")) != line[field]:
                    raise Conflict("Receipt payable dimensions mismatch")
            if body["status"] == "payment_issued" and not all(body.get(field) for field in ("payment_method", "payment_reference", "payment_effective_on")):
                raise Conflict("Issuance evidence is required")
        self.receipt_runs[batch_id] = run_id
        if item_binding:
            self.receipt_items[item_binding] = item_id
        self.events[key] = copy.deepcopy(body)
        return self.envelope({"accepted": True, "duplicate": False})

    def dispatch(self, method, path, query, headers, body):
        self.authenticate(headers)
        with self.lock:
            if method == "GET" and path == "/api/v1/payroll/time_summary":
                return 200, self.envelope({"start_date": query.get("start_date", [""])[0], "end_date": query.get("end_date", [""])[0], "employees": []})
            if method == "POST" and path == "/__fixture/advance_to_cutoff":
                if not self.calendars:
                    raise Conflict("Publish a calendar first")
                self.clock = max(timestamp(row["payload"]["cutoff_at"]) for row in self.calendars.values()) + timedelta(seconds=1)
                self.freeze_due()
                return 200, self.envelope({"clock": self.clock.isoformat(), "batch_count": len(self.batches)})
            if method == "GET" and path == "/__fixture/evidence":
                return 200, self.envelope({"calendars": list(self.calendars.values()), "batches": list(self.batches.values()), "events": list(self.events.values())})
            prefix = "/api/v1/payroll/calendar_periods/"
            if path.startswith(prefix):
                external_id = path[len(prefix):]
                if method == "PUT":
                    return 200, self.publish(external_id, body, headers.get("Idempotency-Key"))
                if method == "GET":
                    return 200, self.calendar_response(self.calendars[external_id])
            if method == "GET" and path == "/api/v1/payroll/batches":
                rows = [{"id": row["batch_id"], "start_date": row["start_date"], "end_date": row["end_date"], "cutoff_at": row["cutoff_at"], "checksum": row["export"]["checksum"]} for row in self.batches.values() if all(row[key] == query.get(key, [row[key]])[0] for key in ("start_date", "end_date"))]
                return 200, self.envelope({"payroll_batches": rows})
            prefix = "/api/v1/payroll/batches/"
            if path.startswith(prefix):
                remainder = path[len(prefix):]
                if method == "POST" and remainder.endswith("/processing_events"):
                    return 201, self.receipt(remainder[:-len("/processing_events")], body)
                if method == "GET":
                    return 200, self.batches[remainder]
            raise KeyError("Unknown producer endpoint")


def serve(producer, port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass  # Never log credentials, query identities or receipt bodies.

        def request(self):
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if size < 0 or size > 1_048_576:
                    raise ValueError("Request too large")
                body = json.loads(self.rfile.read(size)) if size else {}
                url = urlsplit(self.path)
                status, result = producer.dispatch(self.command, url.path, parse_qs(url.query), self.headers, body)
            except PermissionError as error:
                status, result = 403, {"error": str(error)}
            except Conflict as error:
                status, result = 409, {"error": str(error)}
            except KeyError:
                status, result = 404, {"error": "Unknown producer record or endpoint"}
            except (ValueError, TypeError, AttributeError, StopIteration):
                status, result = 422, {"error": "Invalid producer request"}
            encoded = json.dumps(result, ensure_ascii=False, allow_nan=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        do_GET = do_POST = do_PUT = request

    return ThreadingHTTPServer(("127.0.0.1", port), Handler)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    if os.environ.get("CONNECTOR_CERTIFICATION") != "disposable_test_only":
        parser.error("CONNECTOR_CERTIFICATION=disposable_test_only is required")
    if not 1024 <= args.port <= 65535:
        parser.error("Use an unprivileged loopback port")
    with serve(Producer(json.loads(args.config.read_text())), args.port) as server:
        server.serve_forever()
