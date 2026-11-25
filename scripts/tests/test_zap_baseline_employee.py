"""Tests for OUTPUT_DIR and symlink hardening in scripts/security/zap_baseline_employee.sh."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "security" / "zap_baseline_employee.sh"


def extract_helper_functions() -> str:
    """Extract validate_output_dir, safe_copy_file, and require_non_symlink_path."""
    lines = SCRIPT_PATH.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("validate_output_dir()"))
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

    def test_validate_output_dir_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            real_dir = Path(tmp) / "real"
            real_dir.mkdir(mode=0o755)
            link_dir = Path(tmp) / "link"
            link_dir.symlink_to(real_dir)
            result = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(link_dir)})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink", result.stderr)

    def test_validate_output_dir_accepts_private_and_standard_directories(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for name, mode in [("private", 0o700), ("standard", 0o755)]:
                target = Path(tmp) / name
                target.mkdir()
                os.chmod(target, mode)
                result = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(target)})
                self.assertEqual(result.returncode, 0, result.stderr)

            created = Path(tmp) / "nested" / "new-reports"
            result = run_bash('validate_output_dir "$TARGET"', env={"TARGET": str(created)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(created.is_dir())
            self.assertEqual(os.stat(created).st_mode & 0o002, 0)

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


if __name__ == "__main__":
    unittest.main()
