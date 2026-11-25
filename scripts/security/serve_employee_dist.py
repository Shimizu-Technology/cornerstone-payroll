#!/usr/bin/env python3
"""Static HTTP server for local OWASP ZAP baseline scans of web/dist.

Applies the Netlify `_headers` and `_redirects` rules produced by
`web/scripts/finalize-surface-dist.mjs` so local scans verify the real
production security headers (CSP, HSTS, X-Frame-Options, nosniff,
Referrer-Policy, Permissions-Policy, COOP, X-Robots-Tag, Cache-Control).
"""

from __future__ import annotations

import argparse
import os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


def parse_netlify_headers(headers_path: Path) -> list[tuple[str, str]]:
    """Parse the single `/*` block emitted by web/deploy/employee/_headers.template."""
    if not headers_path.exists():
        return []
    headers: list[tuple[str, str]] = []
    in_wildcard_block = False
    for raw_line in headers_path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not raw_line[0].isspace():
            in_wildcard_block = stripped == "/*"
            continue
        if in_wildcard_block and ":" in stripped:
            name, value = stripped.split(":", 1)
            headers.append((name.strip(), value.strip()))
    return headers


def make_handler(dist_dir: Path, extra_headers: list[tuple[str, str]]):
    resolved_root = dist_dir.resolve()

    class EmployeeDistHandler(SimpleHTTPRequestHandler):
        # Hide Python's version banner so ZAP does not report a false-positive
        # server version leak from the local harness.
        server_version = "static"
        sys_version = ""

        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(resolved_root), **kwargs)

        def send_header(self, keyword: str, value: str) -> None:
            # Suppress Python's default Server header to avoid false-positive version banners.
            if keyword.lower() == "server":
                return
            super().send_header(keyword, value)

        def end_headers(self) -> None:
            for name, value in extra_headers:
                super().send_header(name, value)
            super().end_headers()

        def translate_path(self, path: str) -> str:
            candidate = Path(super().translate_path(path))
            if candidate.exists():
                return str(candidate)
            # Mirror `/* /index.html 200` SPA fallback in _redirects.
            parsed = urlsplit(path)
            if not parsed.path.startswith("/assets/"):
                index_file = resolved_root / "index.html"
                if index_file.exists():
                    return str(index_file)
            return str(candidate)

        def log_message(self, format: str, *args) -> None:
            pass

    return EmployeeDistHandler


def write_ready_file(path: Path) -> None:
    """Record this process's PID once the port is bound (the harness's per-run marker)."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(f"{os.getpid()}\n", encoding="utf-8")
    tmp.replace(path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, required=True, help="Path to built employee web/dist")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=4173)
    parser.add_argument("--ready-file", type=Path, help="Write this process's PID here after the port is bound")
    args = parser.parse_args()

    dist_dir = args.dir.resolve()
    if not (dist_dir / "index.html").exists():
        raise SystemExit(f"Missing {dist_dir / 'index.html'}; build the employee surface first.")

    headers = parse_netlify_headers(dist_dir / "_headers")
    # Binds now; a port already in use raises before any ready file is written.
    server = ThreadingHTTPServer((args.host, args.port), make_handler(dist_dir, headers))
    if args.ready_file:
        write_ready_file(args.ready_file)
    print(f"Serving {dist_dir} on http://{args.host}:{args.port} with {len(headers)} _headers rules", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
