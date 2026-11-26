#!/usr/bin/env bash
# Smoke checks for a running local production copy. Exit 0 only if all pass.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# -eq 0 ]] || die "smoke.sh takes no arguments"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s  (%s)\n' "$1" "$2"; failures=$((failures + 1)); }
fetch() { clean_env curl -sS --cacert "$STATE/certs/ca-bundle.pem" --max-time 20 "$@"; }

expect_status() {
  local name="$1" want="$2" url="$3" got
  got="$(fetch -o /dev/null -w '%{http_code}' "$url" || true)"
  [[ "$got" == "$want" ]] && pass "$name" || fail "$name" "HTTP $got, wanted $want"
}

expect_header() {
  local name="$1" url="$2" pattern="$3" headers
  headers="$(fetch -o /dev/null -D - "$url" || true)"
  if grep -iE "$pattern" <<<"$headers" >/dev/null; then pass "$name"; else fail "$name" "no header matching $pattern"; fi
}

expect_body() {
  local name="$1" url="$2" want="$3" refuse="$4" body
  body="$(fetch "$url" || true)"
  if [[ "$body" == *"$want"* && "$body" != *"$refuse"* ]]; then pass "$name"; else fail "$name" "body is not the expected page"; fi
}

tenant="https://${TENANT_HOSTS[0]}.$ROOT_DOMAIN:$HTTPS_PORT"

echo "== HTTPS through Caddy"
expect_status "staff site serves the app shell" 200 "$STAFF_ORIGIN/"
expect_status "staff site falls back to the shell for app routes" 200 "$STAFF_ORIGIN/companies"
expect_header "staff site sends its report-only CSP" "$STAFF_ORIGIN/" '^content-security-policy-report-only: .*api\.cornerstone\.localhost:8443'
expect_header "staff site uses Netlify's default caching" "$STAFF_ORIGIN/" '^cache-control: public, max-age=0, must-revalidate'
expect_status "employee address serves the employee app" 200 "$tenant/"
expect_header "employee address is never cached" "$tenant/" '^cache-control: no-store'
expect_header "employee address sends the enforcing CSP" "$tenant/" "^content-security-policy: .*employee-api\\.cornerstone\\.localhost:8443"
expect_body "employee address serves the draft terms page" "$tenant/terms" "<title>Employee App Terms of Use" 'id="root"'
expect_status "the build's _headers file is not served" 404 "$tenant/_headers"
expect_status "the build stamp is not served" 404 "$STAFF_ORIGIN/.built-from"
expect_status "staff API is up" 200 "$API_ORIGIN/up"
expect_header "staff API forces TLS (HSTS)" "$API_ORIGIN/up" '^strict-transport-security:'
expect_status "employee API is up" 200 "$EMPLOYEE_API_ORIGIN/up"
body="$(fetch "$EMPLOYEE_API_ORIGIN/health/dependencies" || true)"
[[ "$body" == *'"status":"ok"'* ]] && pass "employee API dependencies are healthy" || fail "employee API dependencies are healthy" "${body:0:160}"
expect_status "employee API has no payroll routes" 404 "$EMPLOYEE_API_ORIGIN/api/v1/admin/companies"
expect_status "employee API has no Cable" 404 "$EMPLOYEE_API_ORIGIN/cable"

echo "== Database (rls:status as staff web)"
phase="$(cat "$STATE/phase" 2>/dev/null || echo unknown)"
report="$(cd "$API_DIR" && with_env "$ENVS/staff.env" bundle exec rails rls:status 2>/dev/null | sed -n '/^{/,$p' || true)"
if verdicts="$(python3 -I - "$report" "$phase" <<'PY'
import json, sys
report, phase = sys.argv[1], sys.argv[2]
if phase not in ("enforced", "shadow"):
    sys.exit(f"unknown phase {phase!r} in the state directory")
data = json.loads(report)
role, summary = data["role"], data["enforcement"]
expected_guard = "raise" if phase == "enforced" else "log"
checks = [
    ("staff web's guard mode is " + expected_guard, data["guard_mode"] == expected_guard),
    ("staff web runs as payroll_app without superuser or BYPASSRLS",
     role["rolname"] == "payroll_app" and role["rolsuper"] is False and role["rolbypassrls"] is False),
    ("the RLS kill switch is off", data["kill_switch"] is False),
    (f"the database phase is {phase}", summary["phase"] == phase),
    ("no table is enabled without being forced (or the reverse)", summary["enabled_xor_forced"] == []),
    ("every protected table is enforced" if phase == "enforced" else "no protected table is enforced yet",
     summary["enforced_tables"] == (summary["protected_tables"] if phase == "enforced" else 0)),
]
for name, ok in checks:
    print(("PASS" if ok else "FAIL") + "\t" + name)
PY
)"; then
  while IFS=$'\t' read -r verdict name; do
    [[ "$verdict" == PASS ]] && pass "$name" || fail "$name" "rls:status disagrees"
  done <<<"$verdicts"
else
  fail "rls:status report" "unreadable or unknown phase"
fi

echo "== Employee app switch readiness (computed by staff web)"
if out="$(cd "$API_DIR" && with_env "$ENVS/staff.env" bundle exec rails runner "$LP_DIR/readiness.rb" 2>"$LOGS/smoke-readiness.err")"; then
  pass "every readiness check passes for every demo company (only mfa may be waived)"
else
  fail "readiness checks" "see below and $LOGS/smoke-readiness.err"
fi
python3 -I - "$out" <<'PY' || true
import json, sys
for line in sys.argv[1].splitlines():
    if not line.startswith("READINESS "):
        continue
    row = json.loads(line[len("READINESS "):])
    print("   ", row["company"] + ":", " ".join(f"{c['key']}={c['status']}" for c in row["checks"]))
    for c in row["checks"]:
        if c["status"] != "passed" and c.get("detail"):
            print("      ", c["key"] + ":", c["detail"])
PY

echo "== Browser (real Clerk sign-in)"
clean_env node "$LP_DIR/smoke_browser.mjs" "$WEB_DIR" "$SECRETS" "$STATE/clerk.json" "$STAFF_ORIGIN" "$API_ORIGIN" "$tenant" || failures=$((failures + 1))

echo
if ((failures == 0)); then echo "All smoke checks passed."; else echo "$failures smoke check(s) failed."; exit 1; fi
