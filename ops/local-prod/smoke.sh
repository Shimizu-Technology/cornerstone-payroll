#!/usr/bin/env bash
# Smoke checks for a running local production copy. Exit 0 only if all pass.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s  (%s)\n' "$1" "$2"; failures=$((failures + 1)); }
fetch() { clean_env curl -sS --cacert "$STATE/certs/ca-bundle.pem" --max-time 20 "$@"; }

expect_status() {
  local name="$1" want="$2" url="$3"
  local got; got="$(fetch -o /dev/null -w '%{http_code}' "$url" || true)"
  [[ "$got" == "$want" ]] && pass "$name" || fail "$name" "HTTP $got, wanted $want"
}

expect_header() {
  local name="$1" url="$2" pattern="$3"
  fetch -o /dev/null -D - "$url" | grep -qiE "$pattern" && pass "$name" || fail "$name" "no header matching $pattern"
}

tenant="https://${TENANT_HOSTS[0]}.$ROOT_DOMAIN:$HTTPS_PORT"

echo "== HTTPS through Caddy"
expect_status "staff site serves the app shell" 200 "$STAFF_ORIGIN/"
expect_status "staff site falls back to the shell for app routes" 200 "$STAFF_ORIGIN/companies"
expect_header "staff site sends its report-only CSP" "$STAFF_ORIGIN/" '^content-security-policy-report-only: .*api\.cornerstone\.localhost:8443'
expect_status "employee address serves the employee app" 200 "$tenant/"
expect_header "employee address is never cached" "$tenant/" '^cache-control: no-store'
expect_header "employee address sends the enforcing CSP" "$tenant/" "^content-security-policy: .*employee-api\\.cornerstone\\.localhost:8443"
expect_status "employee address serves the draft terms" 200 "$tenant/terms"
expect_status "staff API is up" 200 "$API_ORIGIN/up"
expect_header "staff API forces TLS (HSTS)" "$API_ORIGIN/up" '^strict-transport-security:'
expect_status "employee API is up" 200 "$EMPLOYEE_API_ORIGIN/up"
body="$(fetch "$EMPLOYEE_API_ORIGIN/health/dependencies" || true)"
[[ "$body" == *'"status":"ok"'* ]] && pass "employee API dependencies are healthy" || fail "employee API dependencies are healthy" "${body:0:160}"
expect_status "employee API has no payroll routes" 404 "$EMPLOYEE_API_ORIGIN/api/v1/admin/companies"
expect_status "employee API has no Cable" 404 "$EMPLOYEE_API_ORIGIN/cable"

echo "== Database"
rls="$(cd "$API_DIR" && with_env "$ENVS/staff.env" bundle exec rails rls:status 2>/dev/null | sed -n '/^{/,$p')"
role="$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["role"]["rolname"], d["role"]["rolsuper"], d["role"]["rolbypassrls"], d["kill_switch"])' "$rls" 2>/dev/null || true)"
[[ "$role" == "payroll_app False False False" || "$role" == "payroll_app false false false" ]] && pass "staff web runs as payroll_app (no superuser, no BYPASSRLS, kill switch off)" || fail "staff web runs as payroll_app" "$role"
phase="$(cat "$STATE/phase" 2>/dev/null || echo unknown)"
summary="$(python3 -I -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["enforcement"]))' "$rls" 2>/dev/null || true)"
if [[ "$phase" == enforced ]]; then
  [[ "$summary" == *'"enforced"'* ]] && pass "RLS is enforced on every protected table" || fail "RLS is enforced" "$summary"
else
  [[ "$summary" == *'"shadow"'* ]] && pass "RLS is staged in shadow" || fail "RLS is staged in shadow" "$summary"
fi

echo "== Employee app switch readiness (computed by staff web)"
if out="$(cd "$API_DIR" && with_env "$ENVS/staff.env" bundle exec rails runner "$LP_DIR/readiness.rb" 2>"$LOGS/smoke-readiness.err")"; then
  pass "no readiness check fails for any demo company"
else
  fail "readiness checks" "see below"
fi
python3 -I -c '
import json, sys
for line in sys.argv[1].splitlines():
    if not line.startswith("READINESS "):
        continue
    row = json.loads(line[len("READINESS "):])
    print("   ", row["company"] + ":", " ".join(f"{c['"'"'key'"'"']}={c['"'"'status'"'"']}" for c in row["checks"]))
    for c in row["checks"]:
        if c["status"] != "passed" and c.get("detail"):
            print("      ", c["key"] + ":", c["detail"])
' "$out" || true

echo "== Browser (real Clerk sign-in)"
if clean_env node "$LP_DIR/smoke_browser.mjs" "$WEB_DIR" "$SECRETS" "$STATE/clerk.json" "$STAFF_ORIGIN" "$API_ORIGIN" "$tenant"; then :; else failures=$((failures + 1)); fi

echo
if ((failures == 0)); then echo "All smoke checks passed."; else echo "$failures smoke check group(s) failed."; exit 1; fi
