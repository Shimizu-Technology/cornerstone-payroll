"""Write the Caddyfile for the local production copy to standard output.

Each web surface is served from its built dist with the same headers and
rewrites Netlify applies: the dist's own _headers and _redirects (written by
web/scripts/finalize-surface-dist.mjs) are translated, not restated, so a
change to either file reaches the local copy on the next build.

usage: caddyfile.py STATE ROOT_DOMAIN HTTPS_PORT STAFF_PORT EMPLOYEE_PORT ADMIN
"""

import os
import sys


def parse_headers(path):
    """Netlify _headers: a path line, then indented "Name: value" lines."""
    rules, current = [], None
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if not line[0].isspace():
                current = (line.strip(), [])
                rules.append(current)
            elif current is not None:
                name, _, value = line.strip().partition(":")
                current[1].append((name.strip(), value.strip()))
    return rules


def parse_redirects(path):
    """Netlify _redirects: "from to [status][!]"; host-specific rules are skipped."""
    rules = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            parts = raw.split("#", 1)[0].split()
            if len(parts) < 2 or "://" in parts[0]:
                continue
            status = parts[2] if len(parts) > 2 else "301"
            rules.append((parts[0], parts[1], status.rstrip("!"), status.endswith("!")))
    return rules


def quote(value):
    if "`" in value:
        raise SystemExit("header value contains a backtick")
    return f"`{value}`"


def site_body(dist):
    lines = [f"\troot * {dist}"]
    headers = os.path.join(dist, "_headers")
    for index, (pattern, values) in enumerate(parse_headers(headers) if os.path.exists(headers) else []):
        matcher = "" if pattern == "/*" else f"@h{index}"
        if matcher:
            lines.append(f"\t{matcher} path {pattern}")
        for name, value in values:
            lines.append(f"\theader {matcher + ' ' if matcher else ''}{name} {quote(value)}")
    lines.append("\troute {")
    redirects = os.path.join(dist, "_redirects")
    for index, (source, target, status, force) in enumerate(parse_redirects(redirects) if os.path.exists(redirects) else []):
        if status == "200":
            if source == target:
                continue
            if source == "/*":
                # Real files win over the shell, as on Netlify.
                lines.append(f"\t\ttry_files {{path}} {target}")
                continue
            lines.append(f"\t\t@r{index} {{\n\t\t\tpath {source}\n" + ("" if force else "\t\t\tnot file\n") + "\t\t}")
            lines.append(f"\t\trewrite @r{index} {target}")
        else:
            lines.append(f"\t\tredir {source} {target} {status}")
    lines.append("\t\tfile_server")
    lines.append("\t}")
    return "\n".join(lines)


def main():
    state, root, port, staff_port, employee_port, admin = sys.argv[1:7]
    certs = os.path.join(state, "certs")
    tls = f"\ttls {certs}/site.pem {certs}/site-key.pem"
    blocks = [
        "{\n"
        f"\tadmin {admin}\n"
        "\tdefault_bind 127.0.0.1 [::1]\n"
        "\tauto_https disable_redirects\n"
        "\tskip_install_trust\n"
        f"\tstorage file_system {state}/caddy\n"
        "}",
        f"https://payroll.{root}:{port} {{\n{tls}\n{site_body(os.path.join(state, 'web', 'staff'))}\n}}",
        f"https://api.{root}:{port} {{\n{tls}\n\treverse_proxy 127.0.0.1:{staff_port}\n}}",
        f"https://employee-api.{root}:{port} {{\n{tls}\n\treverse_proxy 127.0.0.1:{employee_port}\n}}",
        # Every other name is a client's employee address, as on the employee site.
        f"https://*.{root}:{port} {{\n{tls}\n{site_body(os.path.join(state, 'web', 'employee'))}\n}}",
    ]
    print("\n\n".join(blocks))


if __name__ == "__main__":
    main()
