"""Tests for scripts/security/serve_employee_dist.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest

MODULE_PATH = Path(__file__).resolve().parents[1] / "security" / "serve_employee_dist.py"
SPEC = importlib.util.spec_from_file_location("serve_employee_dist", MODULE_PATH)
assert SPEC and SPEC.loader
serve_employee_dist = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(serve_employee_dist)


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


if __name__ == "__main__":
    unittest.main()
