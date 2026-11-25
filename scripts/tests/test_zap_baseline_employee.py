"""Tests for OUTPUT_DIR, ancestor, and publishing hardening in scripts/security/zap_baseline_employee.sh."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "security" / "zap_baseline_employee.sh"


def extract_helper_functions() -> str:
    """Extract output validation and publishing helpers from zap_baseline_employee.sh."""
    lines = SCRIPT_PATH.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("stat_mode_and_uid()"))
    end = next(i for i, line in enumerate(lines[start:], start) if line.startswith('validate_output_dir "$OUTPUT_DIR"'))
    return "\n".join(lines[start:end])


HELPER_BASH = extract_helper_functions()


def run_bash(snippet: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        ["bash", "-euo", "pipefail", "-c", f"{HELPER_BASH}\n{snippet}"],
        capture_output=True,
        text=True,
        env=merged_env,
        check=False,
    )


class ZapBaselineEmployeeScriptTest(unittest.TestCase):
    def test_validate_output_dir_rejects_world_writable_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            insecure = Path(tmp) / "reports"
            insecure.mkdir()
            os.chmod(insecure, 0o777)
            result = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(insecure)})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("world-writable", result.stderr)

    def test_validate_output_dir_rejects_group_writable_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for mode in (0o775, 0o770):
                insecure = Path(tmp) / f"reports-{oct(mode)}"
                insecure.mkdir()
                os.chmod(insecure, mode)
                result = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(insecure)})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("group-writable", result.stderr)

    def test_validate_output_dir_rejects_group_writable_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bad_parent = Path(tmp) / "group-writable-parent"
            bad_parent.mkdir()
            os.chmod(bad_parent, 0o775)
            existing_child = bad_parent / "reports"
            existing_child.mkdir()
            os.chmod(existing_child, 0o755)

            result = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(existing_child)})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("group-writable ancestor", result.stderr)

            missing_child = bad_parent / "nested" / "new-reports"
            result_missing = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(missing_child)})
            self.assertNotEqual(result_missing.returncode, 0)
            self.assertIn("group-writable ancestor", result_missing.stderr)
            self.assertFalse((bad_parent / "nested").exists())

    def test_validate_output_dir_rejects_world_writable_ancestor_without_sticky_bit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bad_parent = Path(tmp) / "world-writable-parent"
            bad_parent.mkdir()
            os.chmod(bad_parent, 0o777)
            child = bad_parent / "reports"
            child.mkdir()
            os.chmod(child, 0o755)

            result = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(child)})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("world-writable ancestor", result.stderr)

    def test_validate_output_dir_accepts_sticky_writable_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for mode in (0o1777, 0o1775):
                sticky_parent = Path(tmp) / f"sticky-{oct(mode)}"
                sticky_parent.mkdir()
                os.chmod(sticky_parent, mode)
                child = sticky_parent / "reports"
                child.mkdir()
                os.chmod(child, 0o755)

                result = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(child)})
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_validate_output_dir_stops_ancestor_check_at_home_or_repo_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            outer = Path(tmp) / "outer-group-writable"
            outer.mkdir()
            os.chmod(outer, 0o775)
            boundary = outer / "boundary"
            boundary.mkdir()
            os.chmod(boundary, 0o755)
            target = boundary / "tmp" / "zap-reports"

            for var_name in ("ROOT_DIR", "HOME"):
                result = run_bash(
                    'validate_output_dir "$TARGET"',
                    env={"TARGET": str(target), var_name: str(boundary)},
                )
                self.assertEqual(result.returncode, 0, result.stderr)

            # A group-writable boundary directory itself is still rejected.
            os.chmod(boundary, 0o775)
            bad_boundary = run_bash(
                'validate_output_dir "$TARGET"',
                env={"TARGET": str(target), "ROOT_DIR": str(boundary)},
            )
            self.assertNotEqual(bad_boundary.returncode, 0)
            self.assertIn("group-writable ancestor", bad_boundary.stderr)

    def test_validate_output_dir_rejects_symlink_leaf_and_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            real_dir = Path(tmp) / "real"
            real_dir.mkdir(mode=0o755)
            link_dir = Path(tmp) / "link"
            link_dir.symlink_to(real_dir)

            for target in (str(link_dir), f"{link_dir}/"):
                result = run_bash('validate_output_dir "$TARGET"', env={"TARGET": target})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("symlink", result.stderr)

            nested_through_link = link_dir / "reports"
            result_ancestor = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(nested_through_link)})
            self.assertNotEqual(result_ancestor.returncode, 0)
            self.assertIn("symlink", result_ancestor.stderr)
            self.assertFalse((real_dir / "reports").exists())

    def test_validate_output_dir_accepts_private_and_standard_directories(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for name, mode in [("private", 0o700), ("standard", 0o755)]:
                target = Path(tmp) / name
                target.mkdir()
                os.chmod(target, mode)
                result = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(target)})
                self.assertEqual(result.returncode, 0, result.stderr)

            created = Path(tmp) / "nested" / "new-reports"
            result = run_bash('umask 0002; validate_output_dir "$TARGET"', env={"TARGET": str(created)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(created.is_dir())
            self.assertEqual(os.stat(created).st_mode & 0o022, 0)
            self.assertEqual(os.stat(created.parent).st_mode & 0o022, 0)

    def test_safe_copy_file_rejects_destination_symlink_without_modifying_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "out"
            out_dir.mkdir(mode=0o755)
            src = Path(tmp) / "report.html"
            src.write_text("new report", encoding="utf-8")
            victim = Path(tmp) / "victim.txt"
            victim.write_text("original", encoding="utf-8")
            dest = out_dir / "report.html"
            dest.symlink_to(victim)

            result = run_bash(
                'OUTPUT_DIR="$OUT" safe_copy_file "$SRC" "$DEST"',
                env={"OUT": str(out_dir), "SRC": str(src), "DEST": str(dest)},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("destination symlink", result.stderr)
            self.assertEqual(victim.read_text(encoding="utf-8"), "original")

    def test_safe_copy_file_rejects_source_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "out"
            out_dir.mkdir(mode=0o755)
            secret = Path(tmp) / "secret.txt"
            secret.write_text("secret", encoding="utf-8")
            src_link = Path(tmp) / "report.html"
            src_link.symlink_to(secret)
            dest = out_dir / "report.html"

            result = run_bash(
                'OUTPUT_DIR="$OUT" safe_copy_file "$SRC" "$DEST"',
                env={"OUT": str(out_dir), "SRC": str(src_link), "DEST": str(dest)},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink source", result.stderr)
            self.assertFalse(dest.exists())

    def test_safe_copy_file_copies_regular_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "out"
            out_dir.mkdir(mode=0o755)
            src = Path(tmp) / "report.html"
            src.write_text("<h1>ZAP Report</h1>", encoding="utf-8")
            dest = out_dir / "report.html"

            result = run_bash(
                'OUTPUT_DIR="$OUT" safe_copy_file "$SRC" "$DEST"',
                env={"OUT": str(out_dir), "SRC": str(src), "DEST": str(dest)},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(dest.read_text(encoding="utf-8"), "<h1>ZAP Report</h1>")

    def test_publish_outputs_publishes_staged_reports_and_logs_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "out"
            stage_dir = Path(tmp) / "stage"
            logs_dir = Path(tmp) / "logs"
            stage_dir.mkdir(mode=0o700)
            logs_dir.mkdir(mode=0o700)
            (stage_dir / "employee-web-local-report.html").write_text("<h1>OK</h1>", encoding="utf-8")
            (logs_dir / "web-server.log").write_text("listening\n", encoding="utf-8")

            result = run_bash(
                'publish_outputs "$OUT" "$STAGE" "$LOGS"',
                env={"OUT": str(out_dir), "STAGE": str(stage_dir), "LOGS": str(logs_dir)},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((out_dir / "employee-web-local-report.html").read_text(encoding="utf-8"), "<h1>OK</h1>")
            self.assertEqual((out_dir / "web-server.log").read_text(encoding="utf-8"), "listening\n")

    def test_publish_outputs_refuses_group_writable_ancestor_and_symlink_dest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            stage_dir = Path(tmp) / "stage"
            logs_dir = Path(tmp) / "logs"
            stage_dir.mkdir(mode=0o700)
            logs_dir.mkdir(mode=0o700)
            (stage_dir / "employee-web-local-report.md").write_text("# Report\n", encoding="utf-8")

            bad_parent = Path(tmp) / "bad-parent"
            bad_parent.mkdir()
            os.chmod(bad_parent, 0o775)
            bad_out = bad_parent / "reports"
            bad_out.mkdir()
            os.chmod(bad_out, 0o755)

            result = run_bash(
                'publish_outputs "$OUT" "$STAGE" "$LOGS"',
                env={"OUT": str(bad_out), "STAGE": str(stage_dir), "LOGS": str(logs_dir)},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("group-writable ancestor", result.stderr)
            self.assertFalse((bad_out / "employee-web-local-report.md").exists())

            good_out = Path(tmp) / "good-out"
            good_out.mkdir(mode=0o755)
            victim = Path(tmp) / "victim.md"
            victim.write_text("untouched", encoding="utf-8")
            (good_out / "employee-web-local-report.md").symlink_to(victim)

            result_link = run_bash(
                'publish_outputs "$OUT" "$STAGE" "$LOGS"',
                env={"OUT": str(good_out), "STAGE": str(stage_dir), "LOGS": str(logs_dir)},
            )
            self.assertNotEqual(result_link.returncode, 0)
            self.assertIn("destination symlink", result_link.stderr)
            self.assertEqual(victim.read_text(encoding="utf-8"), "untouched")

    def test_publish_outputs_stops_when_errexit_is_disabled(self) -> None:
        # The cleanup trap calls publish_outputs with `|| true`, which disables
        # errexit inside it, so each validation failure must stop on its own.
        with tempfile.TemporaryDirectory() as tmp:
            stage_dir = Path(tmp) / "stage"
            logs_dir = Path(tmp) / "logs"
            stage_dir.mkdir(mode=0o700)
            logs_dir.mkdir(mode=0o700)
            (stage_dir / "employee-web-local-report.md").write_text("# Report\n", encoding="utf-8")

            bad_parent = Path(tmp) / "bad-parent"
            bad_parent.mkdir()
            os.chmod(bad_parent, 0o775)
            bad_out = bad_parent / "reports"
            bad_out.mkdir()
            os.chmod(bad_out, 0o755)

            result = run_bash(
                'publish_outputs "$OUT" "$STAGE" "$LOGS" || echo "refused=$?"',
                env={"OUT": str(bad_out), "STAGE": str(stage_dir), "LOGS": str(logs_dir)},
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("refused=1", result.stdout)
            self.assertFalse((bad_out / "employee-web-local-report.md").exists())

            target = Path(tmp) / "link-target"
            target.mkdir(mode=0o755)
            link_out = Path(tmp) / "link-out"
            link_out.symlink_to(target)

            result_link = run_bash(
                'publish_outputs "$OUT" "$STAGE" "$LOGS" || echo "refused=$?"',
                env={"OUT": str(link_out), "STAGE": str(stage_dir), "LOGS": str(logs_dir)},
            )
            self.assertIn("refused=1", result_link.stdout)
            self.assertFalse((target / "employee-web-local-report.md").exists())

    def test_script_keeps_server_logs_inside_private_run_dir(self) -> None:
        script = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertNotIn('>"${OUTPUT_DIR}/web-server.log"', script)
        self.assertNotIn('>"${OUTPUT_DIR}/api-server.log"', script)
        self.assertIn('>"${RUN_LOGS}/web-server.log"', script)
        self.assertIn('>"${RUN_LOGS}/api-server.log"', script)
        self.assertIn('publish_outputs "$OUTPUT_DIR" "$RUN_STAGE" "$RUN_LOGS"', script)


if __name__ == "__main__":
    unittest.main()
