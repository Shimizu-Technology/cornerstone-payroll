"""Run the real poller/verifier against isolated CLI mocks; never contact services."""

import json
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


class PairGateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="connected-payroll-gate-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.ops = self.root / "ops/staging-v2"
        self.ops.mkdir(parents=True)
        for name in ("common.sh", "poll-once.sh", "verify-pair-certificate.sh", "deploy.sh"):
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
                "name": "Quality", "path": ".github/workflows/quality.yml",
                "display_title": f"Connected payroll {PAYROLL_SHA} + {AIRE_SHA}",
                "head_sha": WORKFLOW_SHA, "run_attempt": 1,
            },
            "certificate": {
                "schema_version": 1, "certification": "passed", "lane": "real-http-synthetic-v1",
                "payroll_sha": PAYROLL_SHA, "aire_sha": AIRE_SHA, "workflow_sha": WORKFLOW_SHA,
                "run_id": 101, "run_attempt": 1,
            },
        }
        self.install_mock("gh", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
model = json.load(open(os.environ["MOCK_MODEL"]))
args = sys.argv[1:]
if args[:2] == ["run", "list"]:
    workflow = args[args.index("--workflow") + 1]
    if workflow == "quality.yml" and args[args.index("--event") + 1] == "workflow_dispatch":
        if model.get("lookup_failure"):
            sys.exit(1)
        print(json.dumps(model["runs"]))
    else:
        print("1" * 40 if workflow == "quality.yml" else "2" * 40)
elif args[0] == "api":
    print(json.dumps(model["run"]))
elif args[:2] == ["run", "download"]:
    if model.get("artifact_missing"):
        sys.exit(1)
    expected_name = f"connected-payroll-pair-{model['run']['id']}-{model['run']['run_attempt']}"
    assert args[args.index("--name") + 1] == expected_name
    destination = Path(args[args.index("--dir") + 1])
    destination.mkdir(parents=True)
    (destination / "pair-certificate.json").write_text(json.dumps(model["certificate"]))
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
        result = subprocess.run([str(self.ops / name), *arguments], env=self.environment,
                                capture_output=True, text=True, timeout=10)
        self.assertFalse(self.mutation_log.exists(), result.stderr)
        return result

    def assert_held(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.deploy_log.exists())

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


if __name__ == "__main__":
    unittest.main()
