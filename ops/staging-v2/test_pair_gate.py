"""Run the real poller/verifier against isolated CLI mocks; never contact services."""

import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parent
PAYROLL_SHA = "1" * 40
AIRE_SHA = "2" * 40
WORKFLOW_SHA = "3" * 40
PUBLISH_JOBS = {
    "cornerstone-payroll": ["backend", "frontend", "browser", "Staging v2 configuration",
        "Publish staging v2 images (cornerstone-payroll-api, api, api/Dockerfile)",
        "Publish staging v2 images (cornerstone-payroll-web, web, web/Dockerfile)"],
    "aire-services": ["backend", "frontend", "staging-configuration", "publish-gate",
        "publish (aire-services-api, backend, backend/Dockerfile)",
        "publish (aire-services-web, frontend, frontend/Dockerfile)"],
}


class PairGateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="connected-payroll-gate-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.ops = self.root / "ops/staging-v2"
        self.ops.mkdir(parents=True)
        for name in ("common.sh", "poll-once.sh", "verify-pair-certificate.sh", "deploy.sh", "pair_evidence.py"):
            shutil.copy2(SOURCE / name, self.ops / name)
        self.actual_deploy = self.ops / "direct-deploy.sh"
        shutil.copy2(self.ops / "deploy.sh", self.actual_deploy)
        (self.ops / "deploy.sh").write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$MOCK_DEPLOY_LOG"\n')
        (self.ops / "deploy.sh").chmod(0o755)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.model_file = self.root / "model.json"
        self.deploy_log = self.root / "deployment.log"
        self.mutation_log = self.root / "unexpected-mutation.log"
        self.model = {
            "runs": [],
            "run": {
                "id": 101, "status": "completed", "conclusion": "success",
                "event": "workflow_dispatch", "head_branch": "staging-v2",
                "name": f"Connected payroll {PAYROLL_SHA} + {AIRE_SHA}", "path": ".github/workflows/quality.yml",
                "display_title": f"Connected payroll {PAYROLL_SHA} + {AIRE_SHA}",
                "head_sha": WORKFLOW_SHA, "run_attempt": 1,
            },
            "certificate": {
                "schema_version": 2, "certification": "passed", "lane": "real-http-synthetic-v2",
                "payroll_sha": PAYROLL_SHA, "aire_sha": AIRE_SHA, "workflow_sha": WORKFLOW_SHA,
                "run_id": 101, "run_attempt": 1,
            },
        }
        self.model["result"] = {
            "schema_version": 1, "source": "neutral_weekly_time", "passed": True,
            "payroll_sha": PAYROLL_SHA, "synthetic_only": True, "actual_operator_acceptance": False,
            "actual_http_transport": True, "hours": {"total": 45, "regular": 40, "overtime": 5},
            "gross": "1187.5", "exact_issued_lines": 5,
            "fixture_sha256": hashlib.sha256(b"fixture").hexdigest(),
            "driver_sha256": hashlib.sha256(b"driver").hexdigest(),
            "capabilities": ["time_summary_v1", "payroll_calendar_v2", "finalized_batch_v2", "exact_line_receipts_v2"],
            "independent_policy": {"schema_version": "2.0", "start_date": "2026-10-05", "end_date": "2026-10-11", "pay_date": "2026-10-16",
                "cutoff_at": "2026-10-14T17:00:00Z", "time_zone": "UTC", "cutoff_rule": "before_pay_date", "cutoff_days": 2, "schedule_version": 1,
                "overtime_policy": {"schema_version": "2.0", "calculation": "weekly_only", "weekly_threshold_hours": 40.0, "workweek_start": "monday", "time_zone": "UTC"}}
        }
        self.model["certificate"].update(independent_producer="passed",
            independent_result_sha256=hashlib.sha256(json.dumps(self.model["result"]).encode()).hexdigest())
        self.model["candidates"] = {}
        for repo, sha, run_id, workflow, name in (
                ("cornerstone-payroll", PAYROLL_SHA, 201, "quality.yml", "Quality staging-v2"),
                ("aire-services", AIRE_SHA, 202, "staging-v2.yml", "Staging v2 images")):
            self.model["candidates"][repo] = {
                "runs": [{"databaseId": run_id, "headSha": sha, "createdAt": "2026-10-03T09:00:00Z"}],
                "run": {"id": run_id, "status": "completed", "conclusion": "success", "event": "push",
                        "head_branch": "staging-v2", "head_sha": sha, "name": name,
                        "path": ".github/workflows/" + workflow, "run_attempt": 1},
                "jobs": [{"name": job, "status": "completed", "conclusion": "success"} for job in PUBLISH_JOBS[repo]],
            }
        self.install_mock("gh", '''#!/usr/bin/env python3
import base64, json, os, sys
from pathlib import Path
model = json.load(open(os.environ["MOCK_MODEL"]))
args = sys.argv[1:]
def run_pages(rows, run):
    values = [{**run, "id": row["databaseId"], "head_sha": row.get("headSha", run["head_sha"]),
        "display_title": row.get("displayTitle", run.get("display_title")), "created_at": row["createdAt"]} for row in rows]
    return [{"total_count": len(values), "workflow_runs": values[n:n+100]} for n in range(0, max(1,len(values)),100)]
def job_pages(candidate):
    run=candidate["run"]
    def pin(job,n):
        return {"id": n+1, "run_id":run["id"], "run_attempt":run["run_attempt"], "head_sha":run["head_sha"], "head_branch":run["head_branch"], **job}
    jobs = [pin(job,n) for n,job in enumerate(candidate["jobs"][:4])]
    jobs += [pin({"name":"unrelated"+str(n),"status":"completed","conclusion":"success"},n+4) for n in range(96)]
    jobs += [pin(job,n+100) for n,job in enumerate(candidate["jobs"][4:])]
    return [{"total_count":len(jobs),"jobs":jobs[n:n+100]} for n in range(0,len(jobs),100)]
if args[:2] == ["run", "list"]:
    # Only latest-success discovery still uses the CLI abstraction.
    assert "--commit" not in args
    workflow = args[args.index("--workflow") + 1]
    print("1" * 40 if workflow == "quality.yml" else "2" * 40)
elif args[0] == "api":
    endpoint = next(arg for arg in args if arg.startswith("repos/"))
    repo=endpoint.split("/")[2]
    candidate=model["candidates"].get(repo)
    if "/contents/" in endpoint:
        assert "ref="+model["run"]["head_sha"] in endpoint
        value=b"fixture" if "producer.py?" in endpoint else b"driver"
        print(json.dumps({"type":"file","encoding":"base64","size":len(value),"content":base64.b64encode(value).decode()}))
    elif "/workflows/" in endpoint and "event=push" in endpoint:
        assert "--paginate" in args and "--slurp" in args
        assert "branch=staging-v2" in endpoint
        if candidate["runs"]: assert "head_sha="+candidate["runs"][0]["headSha"] in endpoint
        if model.get("candidate_lookup_failure"): sys.exit(1)
        counter=Path(os.environ["MOCK_MODEL"]+"."+repo+".inventory.reads")
        reads=int(counter.read_text()) if counter.exists() else 0
        counter.write_text(str(reads+1))
        pages=run_pages(candidate["runs"],candidate["run"])
        if reads and model.get("new_candidate_during_verification"):
            pages[0]["total_count"]+=1
            pages[0]["workflow_runs"].append({**pages[0]["workflow_runs"][0],"id":999,"created_at":"2026-10-04T09:00:00Z","status":"queued","conclusion":None})
        if reads and model.get("new_attempt_during_verification"):
            pages[0]["workflow_runs"][0]["run_attempt"]=2
        print(json.dumps(model.get("candidate_pages",pages)))
    elif "/workflows/" in endpoint:
        assert "event=workflow_dispatch" in endpoint and "branch=staging-v2" in endpoint
        if model.get("lookup_failure"): sys.exit(1)
        counter=Path(os.environ["MOCK_MODEL"]+".certificate.reads")
        reads=int(counter.read_text()) if counter.exists() else 0
        counter.write_text(str(reads+1))
        pages=run_pages(model["runs"],model["run"])
        if reads and model.get("new_certificate_during_verification"):
            pages[0]["total_count"]+=1
            pages[0]["workflow_runs"].append({**pages[0]["workflow_runs"][0],"id":999,"created_at":"2026-10-04T09:00:00Z","status":"queued","conclusion":None})
        if reads and model.get("certificate_attempt_during_verification"):
            pages[0]["workflow_runs"][0]["run_attempt"]=2
        print(json.dumps(pages))
    elif candidate and f"/runs/{candidate['run']['id']}" in endpoint:
        if "/jobs?" in endpoint:
            assert "--paginate" in args and "--slurp" in args
            assert f"/attempts/{candidate['run']['run_attempt']}/" in endpoint
            if model.get("candidate_jobs_failure"): sys.exit(1)
            print(json.dumps(job_pages(candidate)))
        else:
            counter=Path(os.environ["MOCK_MODEL"]+"."+repo+".reads")
            reads=int(counter.read_text()) if counter.exists() else 0
            counter.write_text(str(reads+1))
            print(json.dumps({**candidate["run"], **(model.get("recheck_change",{}) if reads else {})}))
    else:
        print(json.dumps(model["run"]))
elif args[:2] == ["run", "download"]:
    if model.get("artifact_missing"): sys.exit(1)
    destination=Path(args[args.index("--dir")+1]); destination.mkdir(parents=True)
    name=args[args.index("--name")+1]
    if name == f"connected-payroll-pair-{model['run']['id']}-{model['run']['run_attempt']}":
        (destination/"pair-certificate.json").write_text(json.dumps(model["certificate"]))
    else:
        assert name == f"independent-payroll-producer-{model['run']['id']}-{model['run']['run_attempt']}"
        if model.get("independent_missing"): sys.exit(1)
        (destination/"independent-producer-result.json").write_text(json.dumps(model["result"]))
else:
    sys.exit(90)
''')
        self.install_mock("git", '''#!/bin/bash
case "$*" in
  *"rev-parse --is-inside-work-tree"*) echo true ;;
  *"status --porcelain"*) : ;;
  *"fetch --quiet"*|*"cat-file -e"*|*"checkout --quiet"*) : ;;
  *) exit 90 ;;
esac
''')
        for command in ("security", "docker"):
            self.install_mock(command, '#!/bin/bash\necho unexpected >> "$MOCK_MUTATION_LOG"\nexit 90\n')
        self.environment = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "AIRE_PAYROLL_STAGING_V2_SERVICE_DIR": str(self.root),
            "AIRE_PAYROLL_STAGING_V2_RUNTIME_ENV": str(self.root / "absent.env"),
            "TMPDIR": str(self.root),
            "MOCK_MODEL": str(self.model_file),
            "MOCK_DEPLOY_LOG": str(self.deploy_log),
            "MOCK_MUTATION_LOG": str(self.mutation_log),
        }

    def install_mock(self, name, contents):
        path = self.bin / name
        path.write_text(contents)
        path.chmod(0o755)

    def certify(self):
        self.model["runs"] = [{
            "databaseId": 101, "displayTitle": self.model["run"]["display_title"],
            "createdAt": "2026-10-03T10:00:00Z",
        }]

    def execute(self, name="poll-once.sh", arguments=()):
        self.model_file.write_text(json.dumps(self.model))
        for counter in self.root.glob("model.json.*.reads"):
            counter.unlink()
        result = subprocess.run([str(self.ops / name), *arguments], env=self.environment,
                                capture_output=True, text=True, timeout=10)
        self.assertFalse(self.mutation_log.exists(), result.stderr)
        return result

    def assert_held(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.deploy_log.exists())

    def enable_public_reader(self):
        self.environment["AIRE_ACTIONS_PUBLIC_READ"] = "true"
        # Public reader runs in a separate process without touching GH token-backed API.
        gh_script=(self.bin/"gh").read_text()
        helper=gh_script[gh_script.index("def run_pages"):gh_script.index("if args[:2]")]
        (self.ops / "public_aire_actions.py").write_text("import json, os, sys\nmodel=json.load(open(os.environ['MOCK_MODEL']))\n" + helper + """
row=model['candidates']['aire-services']
if model.get('public_read_failure'): sys.exit(1)
if sys.argv[1] == 'runs': print(json.dumps(run_pages(row['runs'],row['run'])))
elif sys.argv[1] == 'run': print(json.dumps(row['run']))
else: print(json.dumps(job_pages(row)))
""")

    def test_missing_independent_artifact_is_held(self):
        self.certify(); self.model["independent_missing"]=True
        self.assert_held()

    def test_tampered_independent_result_is_held(self):
        self.certify(); self.model["result"]["hours"]["overtime"]=4
        self.assert_held()

    def test_foreign_current_attempt_job_is_held(self):
        self.model["candidates"]["cornerstone-payroll"]["jobs"][-1]["run_attempt"]=9
        self.assertNotEqual(self.execute("verify-pair-certificate.sh", ("--candidate-workflows-only", PAYROLL_SHA, AIRE_SHA)).returncode,0)

    def test_new_candidate_or_attempt_during_verification_is_held(self):
        for flag in ("new_candidate_during_verification","new_attempt_during_verification"):
            self.model[flag]=True
            self.assertNotEqual(self.execute("verify-pair-certificate.sh", ("--candidate-workflows-only", PAYROLL_SHA, AIRE_SHA)).returncode,0)
            self.model[flag]=False

    def test_automatic_certificate_change_during_verification_is_held(self):
        for flag in ("new_certificate_during_verification","certificate_attempt_during_verification"):
            self.certify();self.model[flag]=True
            self.assert_held()
            self.model[flag]=False

    def test_explicit_certificate_retains_deliberate_operator_selection(self):
        self.model["new_certificate_during_verification"]=True
        self.assertEqual(self.execute("verify-pair-certificate.sh", (PAYROLL_SHA,AIRE_SHA,"101")).returncode,0)

    def test_attempt_change_during_verification_is_held(self):
        self.model["recheck_change"]={"run_attempt":2}
        self.assertNotEqual(self.execute("verify-pair-certificate.sh", ("--candidate-workflows-only", PAYROLL_SHA, AIRE_SHA)).returncode,0)

    def test_inventory_error_names_the_repository(self):
        self.model["candidate_lookup_failure"]=True
        result=self.execute("verify-pair-certificate.sh", ("--candidate-workflows-only", PAYROLL_SHA, AIRE_SHA))
        self.assertNotEqual(result.returncode,0)
        self.assertIn("Candidate cornerstone-payroll: workflow inventory unavailable",result.stderr)

    def test_legacy_certificate_cannot_certify_a_new_pair(self):
        self.certify(); self.model["certificate"]["schema_version"]=1
        self.assert_held()

    def test_public_aire_evidence_preserves_exact_pair_and_image_checks(self):
        self.enable_public_reader()
        self.certify()
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.deploy_log.exists())
        self.deploy_log.unlink()
        self.model['candidates']['aire-services']['jobs'][-1]['conclusion'] = 'failure'
        self.assert_held()

    def test_public_aire_read_failure_holds_deployment(self):
        self.enable_public_reader()
        self.certify()
        self.model['public_read_failure'] = True
        self.assert_held()

    def test_independently_green_repositories_without_certificate_are_held(self):
        self.assert_held()

    def test_pending_certificate_is_held(self):
        self.certify()
        self.model["run"].update(status="in_progress", conclusion=None)
        self.assert_held()

    def test_failed_certificate_is_held(self):
        self.certify()
        self.model["run"]["conclusion"] = "failure"
        self.assert_held()

    def test_newest_pending_run_does_not_reuse_old_success(self):
        self.certify()
        self.model["runs"].append({**self.model["runs"][0], "databaseId": 102,
                                  "createdAt": "2026-10-03T11:00:00Z"})
        self.model["run"].update(id=102, status="queued", conclusion=None)
        self.assert_held()

    def test_certificate_for_different_pair_is_held(self):
        self.certify()
        self.model["certificate"]["aire_sha"] = "4" * 40
        self.assert_held()

    def test_wrong_workflow_is_held(self):
        self.certify()
        self.model["run"]["path"] = ".github/workflows/connected-payroll.yml"
        self.assert_held()

    def test_task_branch_certificate_is_evidence_only_and_cannot_deploy(self):
        self.certify()
        self.model["run"]["head_branch"] = "codex/pair-gate-test"
        self.assert_held()

    def test_artifact_from_prior_run_attempt_is_held(self):
        self.certify()
        self.model["run"]["run_attempt"] = 2
        self.assert_held()

    def test_missing_artifact_is_held(self):
        self.certify()
        self.model["artifact_missing"] = True
        self.assert_held()

    def test_lookup_failure_is_held(self):
        self.model["lookup_failure"] = True
        self.assert_held()

    def test_successful_exact_pair_deploys_with_verified_run_id(self):
        self.certify()
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.deploy_log.read_text().splitlines(), [PAYROLL_SHA, AIRE_SHA, "101"])

    def test_dynamic_run_titles_are_not_workflow_identity(self):
        for public_read in (False, True):
            with self.subTest(public_read=public_read):
                if public_read:
                    self.enable_public_reader()
                self.certify()
                result = self.execute()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.deploy_log.read_text().splitlines(), [PAYROLL_SHA, AIRE_SHA, "101"])
                self.deploy_log.unlink()

    def test_explicit_certificate_rejects_wrong_pair_title(self):
        self.model["run"]["display_title"] = f"Connected payroll {PAYROLL_SHA} + {'f' * 40}"
        self.assertNotEqual(self.execute("verify-pair-certificate.sh", (PAYROLL_SHA, AIRE_SHA, "101")).returncode, 0)

    def test_direct_deploy_cannot_bypass_missing_certificate(self):
        result = self.execute("direct-deploy.sh", (PAYROLL_SHA, AIRE_SHA))
        self.assertNotEqual(result.returncode, 0)

    def test_explicit_manual_bootstrap_certificate_is_verified(self):
        result = self.execute("verify-pair-certificate.sh", (PAYROLL_SHA, AIRE_SHA, "101"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "101")

    def test_explicit_manual_bootstrap_rejects_mismatched_certificate(self):
        self.model["certificate"]["workflow_sha"] = "5" * 40
        result = self.execute("verify-pair-certificate.sh", (PAYROLL_SHA, AIRE_SHA, "101"))
        self.assertNotEqual(result.returncode, 0)

    def test_existing_deployed_pair_is_left_untouched(self):
        state = self.root / ".staging-v2-state"
        state.mkdir()
        (state / "deployed-payroll-sha").write_text(PAYROLL_SHA)
        (state / "deployed-aire-sha").write_text(AIRE_SHA)
        self.assert_held()

    def test_direct_deploy_rejects_failed_or_pending_exact_candidate_workflow(self):
        for repo in PUBLISH_JOBS:
            for status, conclusion in (("completed", "failure"), ("queued", None), ("in_progress", None)):
                with self.subTest(repo=repo, status=status):
                    self.model["candidates"][repo]["run"].update(status=status, conclusion=conclusion)
                    result = self.execute("direct-deploy.sh", (PAYROLL_SHA, AIRE_SHA, "101"))
                    self.assertNotEqual(result.returncode, 0)
            self.model["candidates"][repo]["run"].update(status="completed", conclusion="success")

    def test_direct_deploy_rejects_missing_or_wrong_head_candidate(self):
        for repo in PUBLISH_JOBS:
            original = self.model["candidates"][repo]["runs"]
            self.model["candidates"][repo]["runs"] = []
            self.assertNotEqual(self.execute("direct-deploy.sh", (PAYROLL_SHA, AIRE_SHA, "101")).returncode, 0)
            self.model["candidates"][repo]["runs"] = original
            candidate_run = self.model["candidates"][repo]["run"]
            original_sha = candidate_run["head_sha"]
            candidate_run["head_sha"] = "f" * 40
            self.assertNotEqual(self.execute("direct-deploy.sh", (PAYROLL_SHA, AIRE_SHA, "101")).returncode, 0)
            candidate_run["head_sha"] = original_sha

    def test_direct_deploy_requires_both_image_jobs_not_just_overall_success(self):
        for repo in PUBLISH_JOBS:
            for position in (-2, -1):
                job = self.model["candidates"][repo]["jobs"][position]
                for conclusion in ("skipped", "failure", None):
                    with self.subTest(repo=repo, image=job["name"], conclusion=conclusion):
                        job["conclusion"] = conclusion
                        self.assertNotEqual(self.execute("direct-deploy.sh", (PAYROLL_SHA, AIRE_SHA, "101")).returncode, 0)
                job["conclusion"] = "success"

    def test_candidate_workflow_proof_rejects_wrong_workflow_event_or_branch(self):
        for repo in PUBLISH_JOBS:
            for key, wrong in (("path", ".github/workflows/untrusted.yml"), ("event", "workflow_dispatch"), ("head_branch", "main")):
                with self.subTest(repo=repo, field=key):
                    run = self.model["candidates"][repo]["run"]
                    original = run[key]
                    run[key] = wrong
                    self.assertNotEqual(self.execute("verify-pair-certificate.sh", ("--candidate-workflows-only", PAYROLL_SHA, AIRE_SHA)).returncode, 0)
                    run[key] = original

    def test_candidate_mode_for_ci_requires_quality_and_published_images(self):
        result = self.execute("verify-pair-certificate.sh", ("--candidate-workflows-only", PAYROLL_SHA, AIRE_SHA))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.model["candidates"]["aire-services"]["jobs"] = self.model["candidates"]["aire-services"]["jobs"][:-1]
        self.assertNotEqual(self.execute("verify-pair-certificate.sh", ("--candidate-workflows-only", PAYROLL_SHA, AIRE_SHA)).returncode, 0)

    def test_candidate_lookup_or_paginated_jobs_error_holds_direct_deployment(self):
        for key in ("candidate_lookup_failure", "candidate_jobs_failure"):
            self.model[key] = True
            self.assertNotEqual(self.execute("direct-deploy.sh", (PAYROLL_SHA, AIRE_SHA, "101")).returncode, 0)
            self.model[key] = False

    def test_superseded_image_gate_and_missing_normal_quality_job_are_held(self):
        candidate = self.model["candidates"]["aire-services"]
        candidate["jobs"][3]["conclusion"] = "skipped"
        self.assertNotEqual(self.execute("direct-deploy.sh", (PAYROLL_SHA, AIRE_SHA, "101")).returncode, 0)
        candidate["jobs"][3]["conclusion"] = "success"
        payroll = self.model["candidates"]["cornerstone-payroll"]
        payroll["jobs"] = payroll["jobs"][1:]
        self.assertNotEqual(self.execute("direct-deploy.sh", (PAYROLL_SHA, AIRE_SHA, "101")).returncode, 0)

    def test_latest_exact_candidate_attempt_pending_does_not_reuse_prior_success(self):
        candidate = self.model["candidates"]["cornerstone-payroll"]
        candidate["runs"].append({"databaseId": 208, "headSha": PAYROLL_SHA, "createdAt": "2026-10-03T10:00:00Z"})
        candidate["run"].update(id=208, status="queued", conclusion=None)
        self.assertNotEqual(self.execute("direct-deploy.sh", (PAYROLL_SHA, AIRE_SHA, "101")).returncode, 0)


if __name__ == "__main__":
    unittest.main()
