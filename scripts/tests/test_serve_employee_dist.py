"""Tests for scripts/security/serve_employee_dist.py."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

MODULE_PATH = Path(__file__).resolve().parents[1] / "security" / "serve_employee_dist.py"
SPEC = importlib.util.spec_from_file_location("serve_employee_dist", MODULE_PATH)
assert SPEC and SPEC.loader
serve_employee_dist = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(serve_employee_dist)

HOOK_PATH = Path(__file__).resolve().parents[1] / "security" / "zap_api_seed_hook.py"
HOOK_SPEC = importlib.util.spec_from_file_location("zap_api_seed_hook", HOOK_PATH)
assert HOOK_SPEC and HOOK_SPEC.loader
zap_api_seed_hook = importlib.util.module_from_spec(HOOK_SPEC)
HOOK_SPEC.loader.exec_module(zap_api_seed_hook)


class FakeZap:
    def __init__(self) -> None:
        self.urls: list[str] = []

    def urlopen(self, url: str) -> str:
        self.urls.append(url)
        return ""


class ServeEmployeeDistTest(unittest.TestCase):
    def test_parse_netlify_headers_reads_wildcard_block_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            headers_file = Path(tmp) / "_headers"
            headers_file.write_text(
                "# Comment\n"
                "/*\n"
                "  Content-Security-Policy: default-src 'self'\n"
                "  X-Frame-Options: DENY\n"
                "  Cache-Control: no-store\n"
                "/other\n"
                "  X-Ignored: yes\n",
                encoding="utf-8",
            )
            parsed = serve_employee_dist.parse_netlify_headers(headers_file)
            self.assertEqual(
                parsed,
                [
                    ("Content-Security-Policy", "default-src 'self'"),
                    ("X-Frame-Options", "DENY"),
                    ("Cache-Control", "no-store"),
                ],
            )

    def test_write_ready_file_records_own_pid(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ready = Path(tmp) / "web.pid"
            serve_employee_dist.write_ready_file(ready)
            self.assertEqual(ready.read_text(encoding="utf-8").strip(), str(os.getpid()))
            self.assertFalse((Path(tmp) / "web.pid.tmp").exists())

    def test_zap_api_seed_hook_seeds_employee_and_404_paths(self) -> None:
        zap = FakeZap()
        zap_api_seed_hook.zap_started(zap, "http://127.0.0.1:3011/up")
        zap_api_seed_hook.zap_tuned(zap)
        self.assertIn("http://127.0.0.1:3011/health/dependencies", zap.urls)
        self.assertIn("http://127.0.0.1:3011/api/v1/auth/me", zap.urls)
        self.assertIn("http://127.0.0.1:3011/api/v1/employee/context", zap.urls)
        self.assertIn("http://127.0.0.1:3011/api/v1/employee/statements", zap.urls)
        self.assertIn("http://127.0.0.1:3011/api/v1/public/tenant_branding?host=unknown.example.test", zap.urls)


if __name__ == "__main__":
    unittest.main()
