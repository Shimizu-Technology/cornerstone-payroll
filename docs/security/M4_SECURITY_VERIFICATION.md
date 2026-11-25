# Milestone 4 Security Verification Record (WISP Evidence)

**Slice:** M4-11 (Security verification)  
**Plan reference:** [Milestone 4 build plan](../MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md) §3 Gate G9, §4 "M4-11"  
**Verification date:** November 25, 2026  
**Scope:** Employee API (`APP_PROCESS_ROLE=employee_web` and `/api/v1/employee/*`), view-only support access (`ViewAsGrant` / `/api/v1/auth/view_as`), row-level security (`RLS_CONTEXT_GUARD_MODE=raise`), and the employee web surface (`VITE_APP_SURFACE=employee`).

This document records the automated security verification controls, findings fixed during verification, how to rerun every check locally and in production before inviting employees, and the known residuals tracked under the Written Information Security Program (WISP).

---

## 1. Findings Fixed During Verification

Two real security gaps and one CI test-isolation deadlock were identified during M4-11 verification and fixed in this slice:

1. **Header enumeration oracle across employee 404 paths (fixed)**  
   `Api::V1::EmployeePortal::BaseController` previously returned `head :not_found` from `authenticate_employee_user!` and `require_employee_link!` *before* subclasses set `Cache-Control: no-store`. As a result, a 404 caused by an invalid/revoked/cross-company link lacked `Cache-Control: no-store`, while a 404 caused by a valid link with a sub-feature off or another employee's record ID included `Cache-Control: no-store`.  
   **Fix:** Set `Cache-Control: no-store` as the first `before_action` in `Api::V1::EmployeePortal::BaseController` and `Api::V1::EmployeePortal::ActivationsController`. Every employee failure response now emits identical status, body, and caching headers.

2. **Locked active/former links were not blocked on direct employee routes (fixed)**  
   `ViewAsEmployeeContext.resolve` refused any link with `activation_locked_until > now`, but `EmployeeAccountLink.portal_eligible`, `EmployeeLinks.openable?`, `ProfileBaseController#writable_link?`, and `DeliveryConsentsController#writable_link?`/`#withdrawable_link?` did not check `activation_locked?`.  
   **Fix:** Excluded locked links in `EmployeeAccountLink.portal_eligible`, `EmployeeLinks.openable?`, and both profile and consent write guards so locked links are uniformly hidden from `GET /api/v1/employee/links` and return an empty 404 on every link-scoped endpoint.

3. **Flaky `contact_details_enforced_rls_spec` deadlock (fixed)**  
   In CI, three parallel RSpec shards share one PostgreSQL 16 cluster (`pg_authid` is cluster-wide, not per-database). `contact_details_enforced_rls_spec.rb` created `payroll_app` then `payroll_owner_sim` while `company_rls_isolation_spec.rb` created `payroll_owner_sim` then `payroll_app`, causing an AB-BA deadlock on `pg_authid`. The spec also ran `ALTER TABLE ... ENABLE/FORCE ROW LEVEL SECURITY` (`ACCESS EXCLUSIVE` across every protected table) inside transactional tests without flushing idle pool connections.  
   **Fix:** Switched `contact_details_enforced_rls_spec.rb` to `use_transactional_tests = false`, flushed idle connections before opening a single explicit rolled-back transaction, acquired table locks in sorted order, and created unique per-process non-bypass/owner roles instead of colliding on cluster-wide `payroll_app` and `payroll_owner_sim`.

---

## 2. Automated Coverage Summary

All backend security specs run with **real RS256-signed Clerk JWT verification** (`ClerkTokenVerifier` against a test JWKS, no auth stubs) and `RLS_CONTEXT_GUARD_MODE=raise` with `AUTH_ENABLED=true` and `REQUIRE_MFA=true`.

### 2.1 Route-Generated Employee Isolation Suite
- **File:** `api/spec/security/employee_endpoint_isolation_spec.rb`
- **Route-completeness guard:** Inspects `Rails.application.routes.routes` dynamically for every route under `/api/v1/employee` or `api/v1/employee_portal/*` (28 mounted verb+path combinations covering links, activation, claim, reactivate, context, help, statements, tax forms, profile, phone/email changes, emergency contacts, address requests, and delivery consents). CI fails automatically if a new employee route is added without isolation coverage.
- **Dimensions verified for every endpoint:**
  1. Positive baseline (proves every link-scoped route reaches its controller under valid real auth rather than passing due to a routing 404).
  2. Cross-company isolation (wrong subdomain `azp`, cross-company resource IDs, cross-organization claim/reactivate, spoofed `X-Company-Id`).
  3. Cross-employee isolation within the same company (resource IDs and collection payloads).
  4. Cross-link isolation (presenting another user's `X-Employee-Link-Id`, mixing links across two companies, routed `claim_user_id` protection).
  5. Former-employee rules (read-only while `former_access_until > now`; statements capped at `former_access_until`; profile closed at `former_profile_access_until` even when W-2GU retention extends `former_access_until`; one-tap delivery consent withdrawal allowed only while the former window is open; empty 404 on every endpoint once expired).
  6. Revoked links (hidden from `/links`, 404 on all link-scoped routes, refused on activation/claim/reactivate).
  7. Locked links (hidden from `/links`, 404 on all link-scoped routes, refused on activation/claim/reactivate).
  8. Feature off (sub-feature flags `stubs`, `tax_forms`, `profile_requests`, `delivery_consent` off -> empty 404; master `employee_portal_enabled: false` -> empty 404 across link routes and refused on activation/claim/reactivate).
  9. Demo versus live identity boundary (demo logins cannot list, open, claim, or reactivate live links; live companies and demo companies cannot share links).
  10. View-only support grant (every write verb returns 403 `view_as_read_only` with zero DB/job side effects; reads scoped strictly to the target employee and ignore spoofed `X-Employee-Link-Id`; audit rows attributed to `real_user_id`).

### 2.2 Enumeration Resistance Checks
- **File:** `api/spec/security/employee_enumeration_spec.rb` (supplemented by `api/spec/requests/employee_link_response_floor_spec.rb` and `api/spec/requests/employee_link_hardening_spec.rb`)
- Verifies **identical HTTP status code, response body, and normalized response headers** (every header except per-request `x-request-id`, `x-runtime`, `date`) across every failure kind:
  - `POST /api/v1/employee/activation` (14 failure kinds -> identical 422 + `Cache-Control: no-store`; 4 sign-in-redirect kinds -> identical 200 + `Cache-Control: no-store`).
  - `POST /api/v1/employee/links/claim` (10 authenticated failure kinds -> identical 404 `claim_failed` + `Cache-Control: no-store`).
  - `POST /api/v1/employee/links/reactivate` (6 authenticated failure kinds -> identical 404 `claim_failed` + `Cache-Control: no-store`).
  - Employee portal 404 paths (14 distinct auth, link, subdomain, revoked, locked, expired, cross-employee, missing-record, feature-off, and portal-off failures -> identical 404 empty body + `Cache-Control: no-store`).

### 2.3 View-Only "Sign in as" Support Access
- **File:** `api/spec/requests/view_as_grants_spec.rb`
- Verifies:
  - **No escalation:** Requires `super_admin` + `view_as_allowed` + verified MFA + fresh step-up + explicit reason + company access. Rejects Clerk impersonation tokens carrying an `act` claim on targets, start, and reads. Rejects all non-`super_admin` roles even if `view_as_allowed` is set. Refuses all staff targets and any employee linked to a staff user. Enforces strict surface isolation (client grants cannot hit employee/admin/finance/Form 500/targets routes; employee grants cannot hit client/admin/auth/links/targets routes). Rejects spoofed `X-Company-Id`, `X-Organization-Id`, and `X-Employee-Link-Id` headers. Closes immediately when company, permission, or portal is deactivated. Gates `ViewAsGrant.ready?` in production on `VIEW_AS_READY=true`, `REQUIRE_MFA=true`, `RLS_CONTEXT_GUARD_MODE=raise`, and `CLERK_AUTHORIZED_PARTIES`.
  - **No writes in view-only:** Refuses all non-GET/HEAD/OPTIONS methods across payroll, admin, client, rollout, approval, signup, profile, consent, and link controllers (`403 view_as_read_only`), prevents DB writes via `ActiveRecord::Base.while_preventing_writes`, and blocks background job enqueueing or stub freezing during reads.
  - **Time limit:** Enforces the 30-minute expiry on both client and employee views (including mid-download PDF expiry) and immediate revocation on `DELETE /api/v1/auth/view_as`.
  - **Audit trail:** Stamps `user_id`, `real_user_id`, and `view_as_grant_id` on `view_as#started`, every audited read/download/failure, and idempotent `view_as#ended`; leaves target login activity and audit trail clean; exposes company-scoped `view_as#started` events (both client and employee views) to client admins via `GET /api/v1/client/support_access_logs` without internal reasons.

### 2.4 Automated OWASP ZAP Baseline Scan
- **Script:** `scripts/security/zap_baseline_employee.sh`
- **Local static header harness:** `scripts/security/serve_employee_dist.py` (serves `web/dist` with the exact Netlify `_headers` and `_redirects` emitted by `web/scripts/finalize-surface-dist.mjs`).
- **Rule files:**
  - `scripts/security/zap_baseline_web_local.conf` / `zap_baseline_web_production.conf`
  - `scripts/security/zap_baseline_api_local.conf` / `zap_baseline_api_production.conf`
- **CI workflow:** `.github/workflows/security-zap-baseline.yml` runs on pull requests touching employee surface/security files, weekly on schedule, and on `workflow_dispatch`. Reports (HTML, JSON, Markdown) are uploaded as the `owasp-zap-baseline-reports` artifact (30-day retention).

---

## 3. How to Rerun

### 3.1 Backend Security Suites (Local, Disposable Test DB)

```bash
DB="cornerstone_payroll_sec_verify_$$_test"
createdb -h 127.0.0.1 "$DB"
trap 'dropdb --if-exists -h 127.0.0.1 "$DB"' EXIT

cd api
TEST_DATABASE_URL="postgres://127.0.0.1:5432/$DB" \
DATABASE_URL="postgres://127.0.0.1:5432/$DB" \
RAILS_ENV=test RLS_CONTEXT_GUARD_MODE=raise \
bundle exec rails db:schema:load db:integrity && \
TEST_DATABASE_URL="postgres://127.0.0.1:5432/$DB" \
DATABASE_URL="postgres://127.0.0.1:5432/$DB" \
RAILS_ENV=test RLS_CONTEXT_GUARD_MODE=raise \
bundle exec rspec \
  spec/security/employee_endpoint_isolation_spec.rb \
  spec/security/employee_enumeration_spec.rb \
  spec/requests/view_as_grants_spec.rb \
  spec/requests/api/v1/contact_details_enforced_rls_spec.rb \
  spec/requests/employee_link_isolation_spec.rb \
  spec/requests/employee_link_hardening_spec.rb \
  spec/requests/employee_link_retirement_hardening_spec.rb \
  spec/requests/demo_identity_boundary_spec.rb
```

Static analysis and lint:

```bash
cd api
bundle exec brakeman -q
bundle exec bundler-audit check --update
bundle exec rubocop
```

### 3.2 Local OWASP ZAP Baseline Scan (Requires Docker)

```bash
bash scripts/security/zap_baseline_employee.sh \
  --mode local \
  --output-dir tmp/zap-reports
```

This builds `VITE_APP_SURFACE=employee`, starts the static server with generated `_headers`, boots the API with `APP_PROCESS_ROLE=employee_web` against a disposable test database, verifies `/api/v1/admin/companies` returns `404`, runs passive ZAP baseline scans against both surfaces, and tears down both servers and the temporary database on exit.

### 3.3 Production Pre-Invite OWASP ZAP Baseline Scan (Gate G9)

Run this **after** Gate G5 deploys the employee Netlify site, Render `employee_web` service, and client subdomains, and **before** any employee is invited. The baseline scan is **passive only** (read-only spidering + header/response inspection; it does not launch active exploits or mutate data).

```bash
DATE_TAG="$(date +%Y-%m-%d)"
OUT_DIR="tmp/zap-production-${DATE_TAG}"

# 1. Scan the pilot client employee site and the employee API:
bash scripts/security/zap_baseline_employee.sh \
  --mode production \
  --web-url "https://<client-subdomain>.shimizu-technology.com" \
  --api-url "https://cornerstone-payroll-employee-api.onrender.com" \
  --output-dir "${OUT_DIR}/client"

# 2. Scan the internal team test address (if separate):
bash scripts/security/zap_baseline_employee.sh \
  --mode production \
  --web-url "https://<team-subdomain>.shimizu-technology.com" \
  --api-url "https://cornerstone-payroll-employee-api.onrender.com" \
  --output-dir "${OUT_DIR}/team"
```

**Acceptance criteria for the production scan:**
- Exit code `0` for both `employee-web-production` and `employee-api-production`.
- Zero `FAIL` findings under `zap_baseline_web_production.conf` and `zap_baseline_api_production.conf` (including HSTS `10035`, `X-Frame-Options` `10020`, `X-Content-Type-Options` `10021`, CSP `10038`, no server version leak `10036`, no wildcard CORS `10098`).
- Confirm the employee API still drops payroll routes (`curl -s -o /dev/null -w '%{http_code}\n' https://cornerstone-payroll-employee-api.onrender.com/api/v1/admin/companies` returns `404`).
- Archive the generated `*-report.html`, `*-report.json`, and `*-report.md` files (with date and deployed commit SHA) in the private WISP evidence folder outside this public repository, and record the pass date and SHA in the M4-12 go-live record.

---

## 4. Known Residuals (Tracked for WISP)

| Residual | Severity / Risk | Current Control & Status | Required Follow-Up |
|---|---|---|---|
| **Email-availability oracle on activation** | Low (accepted, M4-2 review Nov 25, 2026) | `POST /api/v1/employee/activation` returns `200` with either `next: "sign_up"` or `next: "sign_in"`, which distinguishes whether a submitted email already has a Payroll/Clerk account. Reaching either outcome requires a valid invite token/code **plus** the employee's DOB and SSN last 4, gated by the 5-attempt/24-hour lockout, response-time floor, and per-token, per-session, and per-IP `Rack::Attack` limits. | Accepted residual for M4. Re-evaluate only if sign-up changes to not require an invite secret + DOB + SSN-4. |
| **CJK / Hangul PDF font gap** | Low (functional / availability) | `PdfUnicodeFont` embeds Liberation Sans (covering Latin, Chamorro, Vietnamese, Polish, Hawaiian, Turkish, Romanian, Greek, and Cyrillic). Liberation Sans lacks CJK and Hangul glyphs; checks and tax forms fail closed (`PdfUnicodeFont::UnprintableName`) rather than printing unreadable boxes. | Keep Latin-character legal names for checks and tax filings until a CJK fallback font is bundled and verified against IRS/DRT form metrics. |
| **Resend webhook configuration (`RESEND_WEBHOOK_SECRET`)** | Medium before electronic-only W-2GU; Low during paper pilot | `POST /api/v1/integrations/email_events` verifies Svix signatures against `RESEND_WEBHOOK_SECRET`, masks all request parameters from logs, and deduplicates by Svix event ID. Without `RESEND_WEBHOOK_SECRET`, the endpoint fails closed (`404`) and notice delivery stays `unknown`. | Before enabling electronic-only W-2GU delivery (26 CFR 31.6051-1(j)), configure the Resend webhook (`email.delivered`, `email.delivery_delayed`, `email.bounced`, `email.complained`), set `RESEND_WEBHOOK_SECRET` on the Payroll API, and complete the 30-day paper-notice bounce workflow. |
| **Enforced-RLS spec deadlock (`contact_details_enforced_rls_spec.rb`)** | Resolved (fixed in M4-11) | Root cause was cross-shard cluster-wide `pg_authid` contention (`CREATE ROLE payroll_app` / `payroll_owner_sim` in opposite order vs `company_rls_isolation_spec.rb`) plus `ACCESS EXCLUSIVE` locks inside transactional tests. Fixed with per-process unique roles, idle-pool flush, sorted table locks, and explicit single-connection rollback. Note: `company_rls_isolation_spec.rb` still creates the literal `payroll_app` role because it tests `RlsDatabase.verify_runtime!` and `RlsDatabase.login_link_decision_ready?`; local workstations with a persistent `payroll_app` role rely on CI's fresh PostgreSQL container for that suite. | Monitor CI stability across shards; no further code work expected. |
| **Pre-launch operational gates outside M4-11** | Launch gates (G1–G5, G8) | Automated tests pass locally and in CI; live production ZAP scan waits on Gate G5 (`employee_web` + employee Netlify site + subdomains live). Full third-party penetration test is scheduled before onboarding clients outside Cornerstone's current book (M3 plan §5.2). | Complete production ZAP scan (§3.3), independent cross-family adversarial review, G1 counsel review, G2 WISP sign-off, G3 Clerk Pro + `REQUIRE_MFA=true`, and G4 RLS phase 3 enforcement before inviting employees. |
