"""Fictional fixtures only; never load captured employee or payroll data."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "render_reconciliation_review.py"
SPEC = importlib.util.spec_from_file_location("render_reconciliation_review", SCRIPT)
review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review)


def fixture():
    payroll = {
        "metadata": {"read_only": "on", "captured_at": "2026-10-03T01:00:00Z", "revision": "a" * 40},
        "employees": [{"id": "9", "company_id": "99", "name": "Other company private person"}],
        "payroll_items": [{"id": "20", "period_status": "committed"}],
        "check_events": [{"payroll_item_id": "20", "event_type": "delivered", "check_number": "F001", "effective_on": "2026-09-30"}],
        "connection_secret": "DO_NOT_RENDER_THIS_SECRET",
    }
    source = {
        "metadata": {"read_only": "on", "captured_at": "2026-10-03T01:01:00Z", "revision": "b" * 40, "missing_tables": []},
        "users": [{"id": "4", "name": "Fictional <script>alert('owner')</script>"}],
        "entries": [{"id": "10", "user_id": "4", "work_date": "2026-09-15", "category_name": None, "hours": "8", "status": "completed", "approval_status": "approved", "overtime_status": "none", "lock_version": "2"},
                    {"id": "11", "user_id": "4", "work_date": "2026-10-01", "category_name": "Office", "hours": "3", "status": "completed", "approval_status": "pending", "overtime_status": "pending", "lock_version": "3"}],
        "payment_attestations": [{"source_time_entry_id": "11", "status": "pending_evidence", "private_note": "OWNER_NOTE_NOT_INFERRED"}],
    }
    manifest = {
        "company_id": 1,
        "identity_links": [{"employee_id": "9", "source_user_id": "4", "source_user_uuid": "fictional-uuid", "employee_name": "Planned Fictional & Person"}],
        "issued_entries": [{"source_time_entry_id": "10", "payroll_item_id": "20", "source_user_uuid": "fictional-uuid", "source_time_entry_version": 1, "original_work_date": "2026-09-15", "regular_hours": "8", "overtime_hours": "0", "category_name": "Expected <Field>"}],
        "classification_cases": [], "finalized_batch_entries": [],
        "delivered_checks": [{"payroll_item_id": "20", "employee_id": "9", "check_number": "F001", "pay_period_id": 2, "regular_hours": "8", "overtime_hours": "0", "net_pay": "80", "delivered_on": "2026-09-30"}],
    }
    report = {
        "format": review.FORMAT, "approval_status": "unapproved_review_packet", "apply_allowed": False,
        "generated_at": "2026-10-03T01:02:00Z",
        "captures": {"payroll": payroll["metadata"], "source": source["metadata"]},
        "summary": {"candidate_entries": 1, "candidate_checks": 1, "exceptions": 2, "entries_requiring_owner_review": 1, "source_entries_outside_candidate_inventory": 1},
        "exceptions": [{"code": "source_entry_category_changed", "source_time_entry_id": "10", "expected_category": "Expected <Field>", "actual_category": None, "arbitrary_secret": "DO_NOT_RENDER_EXCEPTION_SECRET"}, {"code": "payroll_identity_wrong_company_or_missing", "employee_id": "9", "source_user_id": "4"}],
        "entries": [{"source_time_entry_id": "10", "payroll_item_id": "20", "recorded_delivery": True, "valid_current_delivery": False, "requires_owner_review": True, "blockers": ["source_entry_category_changed"]}],
        "source_entries_outside_candidate_inventory": ["11"],
    }
    rehash(report, payroll, source, manifest)
    return report, payroll, source, manifest


def rehash(report, payroll, source, manifest):
    report["hashes"] = {"payroll_snapshot": review.fingerprint(payroll), "source_snapshot": review.fingerprint(source), "candidate_manifest": review.fingerprint(manifest)}


class ReconciliationReviewTest(unittest.TestCase):
    def test_escaped_static_review_and_expected_actual_evidence(self):
        report, payroll, source, manifest = fixture()
        output = review.render(report, payroll, source, manifest)
        self.assertIn("Fictional &lt;script&gt;", output)
        self.assertIn("Expected &lt;Field&gt;", output)
        self.assertIn("Planned Fictional &amp; Person", output)
        self.assertNotIn("<script", output)
        self.assertNotIn("<form", output)
        self.assertNotIn("https://", output)
        self.assertIn("default-src 'none'", output)
        self.assertIn("Captured entry version", output)
        self.assertIn("a" * 40, output)
        self.assertIn(report["hashes"]["candidate_manifest"], output)

    def test_cross_company_collision_never_discloses_other_person(self):
        output = review.render(*fixture())
        self.assertIn("belongs to company 99", output)
        self.assertIn("Planned Fictional", output)
        self.assertNotIn("Other company private person", output)

    def test_no_secrets_raw_json_or_attested_note_inferred(self):
        output = review.render(*fixture())
        for hidden in ("DO_NOT_RENDER_THIS_SECRET", "DO_NOT_RENDER_EXCEPTION_SECRET", "OWNER_NOTE_NOT_INFERRED"):
            self.assertNotIn(hidden, output)
        self.assertIn("pending_evidence", output)
        self.assertIn("does not create or infer them", output)

    def test_delivery_events_never_claim_payment_or_approval(self):
        output = review.render(*fixture())
        self.assertIn("Recorded delivery event present", output)
        self.assertIn("does not establish payment", output)
        self.assertIn("UNAPPROVED EVIDENCE PACKET", output)
        self.assertIn("apply_allowed: false", output)
        self.assertNotIn("Confirmed paid", output)
        self.assertIn("Reviewers: Leon and Chels", output)

    def test_missing_source_owner_and_missing_target_are_explicit(self):
        report, payroll, source, manifest = fixture()
        source["entries"][1]["user_id"] = None
        payroll["payroll_items"] = []
        report["exceptions"].append({"code": "source_entry_owner_missing", "source_time_entry_id": "11"})
        rehash(report, payroll, source, manifest)
        output = review.render(report, payroll, source, manifest)
        self.assertIn("Missing captured owner", output)
        self.assertIn("Missing item", output)
        self.assertIn("source_entry_owner_missing", output)

    def test_absent_delivery_and_conflicting_date_are_explicit(self):
        report, payroll, source, manifest = fixture()
        payroll["check_events"][0]["effective_on"] = "2026-09-29"
        rehash(report, payroll, source, manifest)
        self.assertIn("dates conflict with candidate", review.render(report, payroll, source, manifest))
        payroll["check_events"] = []
        rehash(report, payroll, source, manifest)
        self.assertIn("No recorded delivery event", review.render(report, payroll, source, manifest))

    def test_rejects_each_digest_mismatch(self):
        for key in ("payroll_snapshot", "source_snapshot", "candidate_manifest"):
            report, payroll, source, manifest = fixture()
            report["hashes"][key] = "0" * 64
            with self.assertRaises(ValueError):
                review.render(report, payroll, source, manifest)

    def test_requires_unapproved_false_and_capture_evidence(self):
        for key, value in (("apply_allowed", True), ("apply_allowed", 0), ("approval_status", "approved"), ("format", "future/2")):
            report, payroll, source, manifest = fixture()
            report[key] = value
            with self.assertRaises(ValueError):
                review.render(report, payroll, source, manifest)
        for key, value in (("read_only", "off"), ("revision", None), ("captured_at", None)):
            report, payroll, source, manifest = fixture()
            source["metadata"][key] = value
            rehash(report, payroll, source, manifest)
            with self.assertRaises(ValueError):
                review.render(report, payroll, source, manifest)

    def test_capture_metadata_cannot_be_substituted(self):
        report, payroll, source, manifest = fixture()
        report["captures"] = copy.deepcopy(report["captures"])
        report["captures"]["payroll"]["revision"] = "substituted"
        with self.assertRaises(ValueError):
            review.render(report, payroll, source, manifest)

    def test_private_exclusive_output_and_git_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "private" / "review.html"
            review.private_write(target, "private evidence")
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o700)
            with self.assertRaises(FileExistsError):
                review.private_write(target, "replacement")
            self.assertEqual(target.read_text(), "private evidence")
            repo = Path(directory) / "repo"
            repo.mkdir()
            (repo / ".git").write_text("gitdir: somewhere")
            with self.assertRaises(ValueError):
                review.private_write(repo / "nested" / "review.html", "private")
            link = Path(directory) / "review-link.html"
            link.symlink_to(Path(directory) / "not-yet-created.html")
            with self.assertRaises(ValueError):
                review.private_write(link, "private")
            self.assertFalse((Path(directory) / "not-yet-created.html").exists())

    def test_cli_uses_matching_snapshot_siblings_and_no_private_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            report, payroll, source, manifest = fixture()
            inventory = Path(directory) / "inventory.json"
            for path, value in ((inventory, report), (Path(str(inventory) + ".payroll.json"), payroll), (Path(str(inventory) + ".source.json"), source), (Path(directory) / "manifest.json", manifest)):
                path.write_text(json.dumps(value))
            output = Path(directory) / "review.html"
            result = subprocess.run([sys.executable, str(SCRIPT), "--inventory", str(inventory), "--candidate-manifest", str(Path(directory) / "manifest.json"), "--output", str(output)], capture_output=True, text=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertNotIn("Fictional", result.stdout)
            self.assertNotIn(directory, result.stdout)
            self.assertIn("unapproved, apply_allowed=false", result.stdout)


if __name__ == "__main__":
    unittest.main()
