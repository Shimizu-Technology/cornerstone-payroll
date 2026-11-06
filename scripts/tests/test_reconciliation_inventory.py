import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("inventory", Path(__file__).parents[1] / "reconciliation_inventory.py")
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)

UUID = "11111111-1111-4111-8111-111111111111"
INSTANCE = "22222222-2222-4222-8222-222222222222"


class InventoryTest(unittest.TestCase):
    def setUp(self):
        metadata = {"read_only": "on", "captured_at": "2026-10-03T12:00:00Z", "revision": "a" * 40, "missing_tables": []}
        self.payroll = {
            "metadata": metadata, "company": [{"id": "2", "name": "Example Air"}],
            "source": [{"id": "1", "company_id": "2", "expected_source_instance_id": INSTANCE, "source_type": "aire_services", "active": "t", "connection_uuid": UUID}],
            "employees": [{"id": "10", "company_id": "2", "name": "Alex Example", "status": "active"}],
            "mappings": [], "allocations": [], "manual_allocations": [], "standalone_checks": [], "check_events": [],
            "payroll_items": [{"id": "20", "company_id": "2", "employee_id": "10", "pay_period_id": "30", "check_number": "1001", "net_pay": "100.00", "regular_hours": "8.00", "overtime_hours": "0.00", "period_status": "committed", "voided_at": None}],
        }
        self.source = {
            "metadata": copy.deepcopy(metadata), "installation": [{"source_instance_id": INSTANCE}],
            "users": [{"id": "4", "uuid": UUID, "name": "Alex Example", "is_active": "t", "time_tracking_enabled": "t"}],
            "events": [], "manual_allocations": [], "payment_attestations": [],
            "entries": [{"id": "100", "user_id": "4", "source_user_uuid": UUID, "work_date": "2026-08-01", "hours": "8.00", "lock_version": "3", "category_name": "Flight", "status": "completed", "approval_status": "approved", "overtime_status": "none"}],
        }
        self.manifest = {
            "company_id": 2, "company_name": "Example Air", "source_id": 1,
            "source_instance_id": INSTANCE, "capture_binding": {"connection_uuid": UUID},
            "identity_links": [{"employee_id": 10, "employee_name": "Alex Example", "employee_status": "active", "source_user_id": "4", "source_user_uuid": UUID}],
            "issued_entries": [{"source_time_entry_id": "100", "payroll_item_id": 20, "source_user_uuid": UUID, "original_work_date": "2026-08-01", "regular_hours": "8.00", "overtime_hours": "0.00", "source_time_entry_version": 3, "category_name": "Flight"}],
            "classification_cases": [], "finalized_batch_entries": [],
            "delivered_checks": [{"payroll_item_id": 20, "employee_id": 10, "pay_period_id": 30, "check_number": "1001", "net_pay": "100.00", "regular_hours": "8.00", "overtime_hours": "0.00", "delivered_on": "2026-08-15"}],
        }

    def report(self):
        return inventory.build_inventory(self.payroll, self.source, self.manifest)

    def codes(self):
        return {row["code"] for row in self.report()["exceptions"]}

    def test_matching_candidates_do_not_infer_payment_or_approve_apply(self):
        report = self.report()
        self.assertEqual(report["summary"]["exceptions"], 0)
        self.assertFalse(report["apply_allowed"])
        self.assertTrue(report["entries"][0]["requires_owner_review"])
        self.assertFalse(report["entries"][0]["recorded_delivery"])

    def test_existing_delivery_is_distinct_from_candidate_attestation(self):
        self.payroll["check_events"] = [{"payroll_item_id": "20", "event_type": "delivered", "check_number": "1001", "effective_on": "2026-08-15"}]
        self.assertTrue(self.report()["entries"][0]["recorded_delivery"])
        self.payroll["check_events"][0]["effective_on"] = "2026-08-16"
        self.assertIn("candidate_delivery_date_conflict", self.codes())

    def test_cross_company_numeric_id_collision_is_rejected(self):
        self.payroll["employees"][0].update(company_id="9", name="Different Person")
        self.assertIn("payroll_identity_wrong_company_or_missing", self.codes())

    def test_wrong_installation_is_rejected(self):
        self.source["installation"][0]["source_instance_id"] = UUID
        self.assertIn("source_installation_changed", self.codes())

    def test_missing_pin_is_explicit(self):
        self.payroll["source"][0]["expected_source_instance_id"] = None
        self.assertIn("source_installation_not_pinned", self.codes())

    def test_source_revision_date_category_and_hours_drift_are_explicit(self):
        self.source["entries"][0].update(lock_version="4", work_date="2026-08-02", category_name="Ground", hours="9")
        self.assertTrue({"source_entry_version_changed", "source_entry_date_or_hours_changed", "source_entry_category_changed"}.issubset(self.codes()))

    def test_check_void_or_changed_amount_is_not_accepted(self):
        self.payroll["payroll_items"][0]["voided_at"] = "2026-09-01"
        self.assertIn("candidate_check_changed", self.codes())

    def test_mapping_conflict_is_not_replaced(self):
        self.payroll["mappings"] = [{"company_id": "2", "employee_id": "11", "source_user_id": "4", "source_user_uuid": UUID}]
        self.assertIn("existing_mapping_conflict", self.codes())

    def test_duplicate_entries_across_paths_fail_closed(self):
        self.manifest["finalized_batch_entries"] = [self.manifest["issued_entries"][0]]
        with self.assertRaises(ValueError):
            self.report()

    def test_existing_legacy_allocation_checks_owner_and_exact_hours(self):
        self.manifest["finalized_batch_entries"] = [{**self.manifest["issued_entries"].pop(), "source_user_uuid": None}]
        self.payroll["allocations"] = [{"company_id": "2", "employee_id": "10", "payroll_item_id": "20", "source_time_entry_id": "100", "source_user_uuid": None, "regular_hours": "8", "overtime_hours": "0"}]
        self.assertEqual(self.codes(), {"legacy_identity_binding_required"})
        self.payroll["allocations"][0]["employee_id"] = "11"
        self.assertIn("existing_integration_allocation_changed", self.codes())

    def test_classification_cases_always_require_review(self):
        row = self.manifest["issued_entries"].pop()
        self.manifest["classification_cases"] = [{"payroll_item_id": 20, "source_user_uuid": UUID, "source_time_entry_ids": ["100"], "source_entries": [row]}]
        self.payroll["check_events"] = [{"payroll_item_id": "20", "event_type": "delivered", "check_number": "1001", "effective_on": "2026-08-15"}]
        self.assertTrue(self.report()["entries"][0]["requires_owner_review"])

    def test_unlisted_source_entries_remain_visible(self):
        self.source["entries"].append({**self.source["entries"][0], "id": "101"})
        self.assertEqual(self.report()["source_entries_outside_candidate_inventory"], ["101"])

    def test_standalone_check_overlap_is_flagged_without_claiming_double_payment(self):
        self.payroll["standalone_checks"] = [{"id": "50", "check_number": "1001", "voided_at": None}]
        self.assertIn("active_standalone_payroll_check_overlap", self.codes())

    def test_capture_requires_read_only_metadata(self):
        self.source["metadata"]["read_only"] = "off"
        with self.assertRaises(ValueError):
            self.report()

    def test_private_reports_are_exclusive_and_not_written_in_git(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "private" / "report.json"
            inventory.private_write(report, self.report())
            self.assertEqual(report.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                inventory.private_write(report, {})
            (root / ".git").mkdir()
            with self.assertRaises(ValueError):
                inventory.private_write(root / "new.json", {})

    def test_source_receipt_for_another_payroll_item_is_not_ignored(self):
        self.source["events"] = [{"id": "1", "source_time_entry_id": "100", "external_payroll_item_id": "999", "status": "payment_issued", "occurred_at": "2026-08-15T07:00:00Z"}]
        self.assertIn("source_payment_receipt_conflict", self.codes())

    def test_source_manual_claim_and_evidence_hold_are_not_ignored(self):
        self.source["manual_allocations"] = [{"source_time_entry_id": "100", "external_payroll_item_id": "999", "source_user_uuid": UUID, "status": "issued", "regular_hours": "8", "overtime_hours": "0"}]
        self.source["payment_attestations"] = [{"source_time_entry_id": "100", "source_user_uuid": UUID, "status": "pending_evidence"}]
        self.assertTrue({"source_manual_payment_conflict", "source_payment_evidence_hold"}.issubset(self.codes()))

    def test_voided_check_and_delivery_conflict_still_require_review(self):
        self.payroll["check_events"] = [{"payroll_item_id": "20", "event_type": "delivered", "check_number": "1001", "effective_on": "2026-08-16"}]
        self.payroll["payroll_items"][0]["voided_at"] = "2026-09-01"
        row = self.report()["entries"][0]
        self.assertTrue(row["recorded_delivery"])
        self.assertFalse(row["valid_current_delivery"])
        self.assertTrue(row["requires_owner_review"])

    def test_orphan_entries_and_missing_tables_are_explicit(self):
        self.source["entries"].append({**self.source["entries"][0], "id": "101", "user_id": None, "source_user_uuid": None})
        self.source["metadata"]["missing_tables"] = ["payroll_payment_attestations"]
        self.assertTrue({"source_entry_owner_missing", "source_payment_evidence_schema_missing"}.issubset(self.codes()))
        self.assertIn("101", self.report()["source_entries_outside_candidate_inventory"])

    def test_pending_approval_is_visible_even_when_candidate_hours_match(self):
        self.source["entries"][0]["approval_status"] = "pending"
        self.assertIn("source_entry_approval_review", self.codes())

    def test_event_order_uses_instants_and_status_rank_including_legacy_overlap(self):
        events = [
            {"id": "2", "payroll_batch_id": "1", "source_line_key": None, "status": "committed", "occurred_at": "2026-08-15T17:00:00+10:00"},
            {"id": "1", "payroll_batch_id": "1", "source_line_key": "flight", "status": "payment_voided", "occurred_at": "2026-08-15T07:00:00Z"},
        ]
        self.assertEqual(inventory.latest_source_events(events)[0]["status"], "payment_voided")

    def test_multiple_finalized_lines_keep_exact_identity_and_unique_entry_count(self):
        original = self.manifest["issued_entries"].pop()
        self.manifest["finalized_batch_entries"] = [{**original, "regular_hours": "4", "source_line_key": key} for key in ("flight", "ground")]
        self.payroll["allocations"] = [{"company_id": "2", "employee_id": "10", "payroll_item_id": "20", "source_time_entry_id": "100", "source_user_uuid": UUID, "regular_hours": "4", "overtime_hours": "0", "line_key": key} for key in ("flight", "ground")]
        report = self.report()
        self.assertEqual(report["summary"]["exceptions"], 0)
        self.assertEqual(report["summary"]["candidate_entries"], 1)
        self.assertEqual(report["summary"]["candidate_lines"], 2)

    def test_latest_committed_regular_scope_cannot_be_silently_omitted(self):
        self.payroll["pay_periods"] = [{"end_date": "2026-09-15", "status": "committed", "cycle": "regular", "run_purpose": "regular", "correction_status": None, "parallel_run": "f"}]
        self.source["entries"].append({**self.source["entries"][0], "id": "101", "work_date": "2026-09-01"})
        self.assertIn("historical_scope_incomplete", self.codes())
        self.assertEqual(self.report()["uncovered_historical_entries"], ["101"])

    def test_aggregate_source_hours_cannot_exceed_the_check(self):
        self.source["entries"].append({**self.source["entries"][0], "id": "101"})
        self.manifest["issued_entries"].append({**self.manifest["issued_entries"][0], "source_time_entry_id": "101"})
        self.assertIn("candidate_check_source_hours_incomplete", self.codes())

    def test_finalized_manifest_cannot_omit_other_payable_lines_on_the_same_check(self):
        original = self.manifest["issued_entries"].pop()
        self.manifest["finalized_batch_entries"] = [{**original, "source_line_key": "flight"}]
        self.payroll["allocations"] = [{"company_id": "2", "employee_id": "10", "payroll_item_id": "20", "source_time_entry_id": "100", "source_user_uuid": UUID, "regular_hours": "8", "overtime_hours": "0", "line_key": key} for key in ("flight", "ground")]
        self.assertIn("finalized_check_allocation_omitted", self.codes())

    def test_explicit_source_employee_name_is_used(self):
        self.manifest["identity_links"][0]["source_employee_name"] = "Different Person"
        self.assertIn("source_employee_name_review", self.codes())

    def test_check_padding_does_not_hide_standalone_overlap(self):
        self.payroll["standalone_checks"] = [{"id": "50", "check_number": "001001", "voided_at": None}]
        self.assertIn("active_standalone_payroll_check_overlap", self.codes())


if __name__ == "__main__":
    unittest.main()
