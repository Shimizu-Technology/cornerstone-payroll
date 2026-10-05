"""Protocol fixture checks over real loopback HTTP; no deployed services."""
import copy
import json
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import uuid

from producer import Producer, checksum, serve


class IndependentProducerTest(unittest.TestCase):
    def setUp(self):
        self.secret = "synthetic-certification-secret"
        self.producer = Producer({"shared_secret": self.secret,
                                  "source_instance_id": str(uuid.uuid4()),
                                  "employee_uuid": str(uuid.uuid4()), "clock": "2026-10-01T00:00:00Z"})
        self.server = serve(self.producer, 0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.external_id = str(uuid.uuid4())
        self.publication = {"schema_version": "2.0", "schedule_version": 1,
                            "publication_id": str(uuid.uuid4()), "start_date": "2026-10-05",
                            "end_date": "2026-10-11", "pay_date": "2026-10-16",
                            "cutoff_at": "2026-10-14T17:00:00+00:00", "time_zone": "UTC",
                            "cutoff_rule": "before_pay_date", "cutoff_days": 2,
                            "overtime_policy": {"schema_version": "2.0", "calculation": "weekly_only",
                                                "weekly_threshold_hours": 40.0, "workweek_start": "monday", "time_zone": "UTC"}}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, method, path, body=None, headers=None):
        auth = {"X-Payroll-Shared-Secret": self.secret,
                "X-Payroll-Source-Instance-Id": self.producer.installation,
                "Content-Type": "application/json", **(headers or {})}
        req = Request(f"http://127.0.0.1:{self.server.server_port}{path}",
                      data=json.dumps(body).encode() if body is not None else None, headers=auth, method=method)
        try:
            response = urlopen(req, timeout=2)
        except HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)

    def publish(self, body=None):
        body = body or self.publication
        return self.request("PUT", "/api/v1/payroll/calendar_periods/" + self.external_id, body,
                            {"Idempotency-Key": body["publication_id"]})

    def frozen(self):
        self.assertEqual(self.publish()[0], 200)
        self.assertEqual(self.request("POST", "/__fixture/advance_to_cutoff", {})[0], 200)
        return next(iter(self.producer.batches.values()))

    def event(self, batch):
        return {"event_id": str(uuid.uuid4()), "external_system": "cornerstone_payroll",
                "external_pay_period_id": "21", "external_payroll_item_id": "88",
                "status": "payment_issued", "occurred_at": "2026-10-16T09:00:00Z",
                "source_time_entry_id": "5", "source_line_key": "operations:2500", "source_kind": "current",
                "source_user_uuid": self.producer.employee_uuid, "contract_version": "2.0",
                "total_hours": "9.0", "regular_hours": "4.0", "overtime_hours": "5.0",
                "payment_method": "check", "payment_reference": "CERT-100",
                "payment_effective_on": "2026-10-16", "metadata": {"pay_period_start": batch["start_date"],
                "pay_period_end": batch["end_date"], "pay_date": self.publication["pay_date"]}}

    def receipt(self, batch, event):
        return self.request("POST", f"/api/v1/payroll/batches/{batch['batch_id']}/processing_events", event)

    def test_authentication_and_pinned_installation(self):
        for headers in ({"X-Payroll-Shared-Secret": "wrong"}, {"X-Payroll-Source-Instance-Id": str(uuid.uuid4())}):
            self.assertEqual(self.request("GET", "/api/v1/payroll/time_summary", headers=headers)[0], 403)
        status, body = self.request("GET", "/api/v1/payroll/time_summary")
        self.assertEqual(status, 200)
        self.assertEqual(body["integration"]["source_type"], "neutral_weekly_time")
        self.assertNotIn("manual_settlement_v1", body["integration"]["capabilities"])

    def test_policy_rejects_aire_workweek_and_unconfirmed_dimensions(self):
        for change in ({"time_zone": "Pacific/Guam"}, {"cutoff_rule": "after_previous_regular_payday"}, {"schedule_version": True}):
            body = copy.deepcopy(self.publication)
            body.update(change)
            self.assertEqual(self.publish(body)[0], 409)

    def test_publication_replay_and_post_cutoff_revision(self):
        self.frozen()
        self.assertEqual(self.publish()[0], 200)
        changed = {**self.publication, "schedule_version": 2}
        self.assertEqual(self.publish(changed)[0], 409)
        changed["publication_id"] = str(uuid.uuid4())
        self.assertEqual(self.publish(changed)[0], 409)

    def test_ruby_utc_z_calendar_freezes_on_supported_python(self):
        self.publication["cutoff_at"] = "2026-10-14T17:00:00Z"
        batch = self.frozen()
        self.assertEqual(batch["generated_at"], "2026-10-14T17:00:00Z")

    def test_frozen_export_checksum_and_weekly_overtime(self):
        batch = self.frozen()
        payload = {key: value for key, value in batch.items() if key != "export"}
        self.assertEqual(batch["export"]["checksum"], checksum(payload))
        self.assertEqual(batch["summary"]["regular_hours"], 40.0)
        self.assertEqual(batch["summary"]["overtime_hours"], 5.0)
        self.assertEqual(batch["employees"][0]["source_user_id"], "2")
        status, fetched = self.request("GET", "/api/v1/payroll/batches/" + batch["batch_id"])
        self.assertEqual(status, 200)
        self.assertEqual(fetched, batch)

    def test_receipt_replay_and_changed_idempotency(self):
        batch = self.frozen()
        event = self.event(batch)
        self.assertEqual(self.receipt(batch, event)[0], 201)
        self.assertTrue(self.receipt(batch, event)[1]["duplicate"])
        event["payment_reference"] = "CHANGED"
        self.assertEqual(self.receipt(batch, event)[0], 409)
        self.assertEqual(len(self.producer.events), 1)

    def test_receipt_identity_dimensions_and_issuance_evidence(self):
        batch = self.frozen()
        for change in ({"source_user_uuid": str(uuid.uuid4())}, {"source_kind": "correction"},
                       {"overtime_hours": "0.0"}, {"payment_reference": None},
                       {"occurred_at": "2026-10-16T09:00:00"}, {"external_payroll_item_id": ""}):
            event = {**self.event(batch), **change}
            self.assertEqual(self.receipt(batch, event)[0], 409, change)
        self.assertEqual(len(self.producer.events), 0)

    def test_receipts_cannot_move_a_line_to_another_run_or_item(self):
        batch = self.frozen()
        event = self.event(batch)
        self.assertEqual(self.receipt(batch, event)[0], 201)
        for change in ({"external_pay_period_id": "22"}, {"external_payroll_item_id": "89"},
                       {"metadata": {"pay_period_start": "2026-09-01"}}):
            next_event = {**event, "event_id": str(uuid.uuid4()), **change}
            self.assertEqual(self.receipt(batch, next_event)[0], 409)


if __name__ == "__main__":
    unittest.main()
