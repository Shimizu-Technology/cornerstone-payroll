# Track B demo shape migration runbook

**What this is:** the operator runbook for converting existing production old-shape demo companies (`payroll_environment = 'migration_rehearsal'`, `test_workspace_purpose = 'demo'`, `demo = false`) to the new Track B shape (`payroll_environment = 'live'`, `demo = true`, test-workspace columns cleared, `employee_account_links.payroll_environment = 'live'`).

**Target production companies:** companies `7` and `8`, plus any other old-shape demo company discovered in the pre-flight inventory (for example `14`). Convert **one company at a time**, with a full before/after verification gate before moving to the next.

**Related PRs and docs:**
- Track B Expand & D-3 markers: PRs #644, #645, and #653.
- Track D simple demo names & invented addresses: PR #648 (`rake demo:rename_fixture`).
- [Postgres RLS enforcement runbook](RLS_ENFORCEMENT_RUNBOOK.md).
- [Payroll write maintenance](../runbooks/WRITE_MAINTENANCE.md).

This repo is public. Never commit real client names, person names, email addresses, EINs, tokens, or raw snapshot JSON files into git, a PR, or a ticket. Keep snapshot outputs and rollout logs in the access-controlled rollout evidence location.

---

## 0. Preconditions

Confirm every item before opening the release window:

1. **Owner approval:** Leon's explicit go-ahead for the release window and target company IDs.
2. **Code deployed everywhere:** the revision containing `20261127170000_prepare_demo_company_shape_migration.rb`, `DemoCompany::ConvertToFlag`, `DemoCompany::RevertToLegacyShape`, `DemoCompany::VerifyShapeMigration`, and PR #648 (`DemoCompany::RenameFixture`) is deployed to Payroll web, Solid Queue worker, and the Employee API.
   - Verify the pre-conversion migration applied cleanly via the normal owner-backed deploy path (`bin/rails db:safe_prepare`). This migration is dual-shape safe and makes no data changes on deploy; it makes `fk_employee_account_links_live_company` `DEFERRABLE INITIALLY IMMEDIATE`, installs the owner-only `SECURITY DEFINER` functions `convert_demo_company_to_flag` and `revert_demo_company_to_legacy_shape` (revoked from `PUBLIC` and never granted to `payroll_app`), and hardens `prevent_demo_company_conversion()`.
3. **Owner shell ready for `APPLY=true`:** read-only snapshots (`demo:verify_shape_snapshot`) and dry runs (`demo:convert_to_flag` without `APPLY=true`) run on the normal runtime connection. Applying (`APPLY=true`) or reverting (`demo:revert_to_legacy_shape APPLY=true`) requires the secured owner shell with `RLS_CONTEXT_GUARD_MODE=off` and the direct non-pooler `MIGRATION_DATABASE_URL` (the runtime `payroll_app` role cannot execute the conversion functions or pass the owner check in the trigger).
4. **No concurrent demo jobs or payroll work on the target demos:** confirm no `demo:seed` or `demo:rename_fixture` run is active.
5. **Operator actor ready:** identify the active organization-administrator `ACTOR_ID` (and `ORGANIZATION_ID`, optional when it matches the actor's organization).

---

## 1. Take a Neon recovery branch first (and decide on write fencing)

1. Create a named Neon recovery branch (or point-in-time snapshot) from the production primary right before the window (for example `pre-track-b-demo-migrate-YYYYMMDD-HHMMZ`). Record the branch name, UTC recovery timestamp, and deployed commit SHA in the private rollout record. Keep the branch isolated from live services and outbound integrations.
2. **Understand rollback scope:**
   - **Primary rollback (no data loss for real clients):** §8 uses `demo:revert_to_legacy_shape` with each company's captured before snapshot to restore only that company's exact shape columns and `employee_account_links.payroll_environment`, without touching unrelated production writes.
   - **Last-resort whole-DB Neon restore:** restoring a whole-database Neon backup discards any unrelated production writes committed after the recovery point (such as a real client's payroll or posted documents). If you want the option to perform a lossless whole-DB Neon restore, enable **Write Maintenance** ([Payroll write maintenance](../runbooks/WRITE_MAINTENANCE.md) — `WRITE_MAINTENANCE=true` on web + suspend the worker) **before** creating the Neon recovery branch and keep it enabled until the verification gate passes. Otherwise, rely on the targeted per-company rollback in §8 and keep the Neon branch strictly as a disaster-recovery last resort.

---

## 2. Inventory old-shape demo companies (read-only)

Run a read-only check from `api/` to confirm the exact IDs of all old-shape demo companies (expected: `7`, `8`, and check whether any additional demo such as `14` exists):

```sh
bundle exec rails runner '
  TenantScope.as_system(reason: "Inventory old-shape demo companies") do
    rows = Company.where(payroll_environment: "migration_rehearsal", test_workspace_purpose: "demo")
      .order(:id)
      .pluck(:id, :organization_id, :demo, :payroll_environment, :test_workspace_purpose, :migration_rehearsal_status)
    rows.each { |r| puts "OLD_SHAPE id=#{r[0]} org=#{r[1]} demo=#{r[2]} env=#{r[3]} purpose=#{r[4]} status=#{r[5]}" }
    puts "COUNT=#{rows.size}"
  end
'
```

Verify every returned ID is an intended demo company. Process **one company ID at a time** (for example `7` first, then `8`, then `14` if present) so a failure or diff mismatch on one company stops immediately before the next company is touched.

```sh
export ACTOR_ID=<org-admin-user-id>
export TAX_YEAR=2026
```

---

## 3. Convert and verify ONE company at a time (repeat for `7`, then `8`, then any other old-shape demo such as `14`)

Set `COMPANY_ID` to the single target company for this iteration:

```sh
export COMPANY_ID=7
```

### 3a. Capture the read-only "before" snapshot

Runs inside its own `SET TRANSACTION READ ONLY` transaction with strictly read-only predicates (zero window retirements, zero account deactivations, zero job enqueues):

```sh
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" TAX_YEAR="$TAX_YEAR" \
  CHECK_EMPLOYEE_SERVICE=true \
  OUTPUT="/tmp/track-b-before-${COMPANY_ID}.json" \
  bundle exec rails demo:verify_shape_snapshot
```

Expect:

```text
OK    demo:verify_shape_snapshot companies=7 output=/tmp/track-b-before-7.json
```

Keep `/tmp/track-b-before-${COMPANY_ID}.json` intact until the entire window succeeds — it also supplies the exact pre-conversion shape metadata for targeted rollback (§8).

This snapshot captures per company (without PII or raw error text):
- exact shape columns (`demo`, `payroll_environment`, `test_workspace_purpose`, `migration_rehearsal_status`, `migration_rehearsal_created_by_id`, `migration_rehearsal_created_at`, `migration_rehearsal_completed_at`, presence + digest of `migration_rehearsal_error`, source/lifecycle flags, and `employee_account_links` environments);
- logins and their access (`accessible_company_ids`, assignments, read-only `payroll_access_allowed`, active/access flags);
- employee-app links and their statuses (`portal_eligible`, lock/reset/profile state);
- subdomain resolution (`enabled_origin_company_id`, branding digest, `demo` flag);
- employee app readiness and switch state (`stored_values`, `switched_on_values`, read-only `effective_values`, open activations, readiness checks);
- firm counters (Client Inbox summary and rows, Year-End counts/hidden counts/listing, `InvoiceServiceFeeRevenue` live-client exclusion, `SharedEmailReport` exclusion, organization `client_limit` / live counts);
- EIN uniqueness (`index_live_companies_on_ein` exclusion and live-company sharing check);
- payroll figure checksums (`PayPeriod`, `PayrollItem` + earnings/deductions/field entries, `PayrollReview::CalculationSnapshot`, `PayrollItemLegacyDispositionService`, paid-correction financial links & payment evidence, time-tracking history inventory asserting zero sources/reviews/receipts, YTD totals, historical paychecks/balances, `EmployeeDocument` rows, and `PayStubGenerator` fingerprint match for every posted stub).

### 3b. Dry run the conversion (read-only)

```sh
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" \
  bundle exec rails demo:convert_to_flag
```

Inspect every `PLAN` line:
- Only the single `company` row (`id=$COMPANY_ID`) and its `employee_account_link` rows appear.
- Only field names are printed (no values).
- Expect `OK    demo:convert_to_flag mode=dry_run converted=7 already_converted=none changes=...`.

### 3c. Apply the conversion (owner shell with `MIGRATION_DATABASE_URL`)

Run in the secured owner shell with `MIGRATION_DATABASE_URL` set and `RLS_CONTEXT_GUARD_MODE=off`:

```sh
RLS_CONTEXT_GUARD_MODE=off MIGRATION_DATABASE_URL="$MIGRATION_DATABASE_URL" \
  ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" APPLY=true \
  bundle exec rails demo:convert_to_flag
```

What happens in one atomic transaction for `$COMPANY_ID`:
- Refuses if an outer transaction is open; acquires the per-organization demo advisory lock and locks the company row and its `employee_account_links`.
- Verifies the company has zero time-tracking sources or AIRE history approvals.
- Calls the owner-only `SECURITY DEFINER` function `convert_demo_company_to_flag(...)`, which verifies the table-owner role, defers `fk_employee_account_links_live_company`, sets `demo = true` and `payroll_environment = 'live'`, clears all test-workspace/rehearsal columns while keeping `test_workspace_manifest` byte-identical, updates `employee_account_links.payroll_environment` to `'live'`, and immediately re-validates `fk_employee_account_links_live_company`.
- Writes an `AuditLog` row (`demo_company#converted_to_flag`) inside the same transaction.
- Invalidates `TenantSubdomainRegistry` in this process after commit.

Expect:

```text
OK    demo:convert_to_flag mode=applied converted=7 already_converted=none changes=...
```

Optional idempotency check (re-running the exact same command writes nothing):

```sh
RLS_CONTEXT_GUARD_MODE=off MIGRATION_DATABASE_URL="$MIGRATION_DATABASE_URL" \
  ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" APPLY=true \
  bundle exec rails demo:convert_to_flag
```

Expect `converted=none already_converted=7 changes=0`.

### 3d. Capture the "after" snapshot and run the strict diff gate

```sh
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" TAX_YEAR="$TAX_YEAR" \
  CHECK_EMPLOYEE_SERVICE=true \
  OUTPUT="/tmp/track-b-after-${COMPANY_ID}.json" \
  bundle exec rails demo:verify_shape_snapshot

COMPANY_IDS="$COMPANY_ID" \
  BEFORE="/tmp/track-b-before-${COMPANY_ID}.json" \
  AFTER="/tmp/track-b-after-${COMPANY_ID}.json" \
  bundle exec rails demo:verify_shape_diff
```

**Gate:** require:

```text
OK    demo:verify_shape_diff companies=7 unexpected_diffs=0
```

`demo:verify_shape_diff` fails closed if:
- either snapshot is empty, missing fields/link maps, or uses an unsupported schema version;
- `before` was not a valid legacy-shape demo or `after` is not a valid flag-shape demo;
- any non-shape field, login access, link status, subdomain resolution, switch state, counter, EIN check, or payroll/payment/document checksum differs;
- any external time-tracking source or AIRE history review exists on the company.

**If `demo:verify_shape_diff` exits non-zero or reports ANY `DIFF` line, STOP immediately and execute §8 (Targeted Rollback) for `$COMPANY_ID`.** Do not convert the next company and do not proceed to Track D.

### 3e. Repeat §3a–§3d for each remaining company

Once company `7` passes §3d with `unexpected_diffs=0`, repeat §3a–§3d for `COMPANY_ID=8` (and then any other verified old-shape demo such as `COMPANY_ID=14`).

---

## 4. Wait past the process-local subdomain cache TTL before smoke checks

`TenantSubdomainRegistry.invalidate!` only clears the cache inside the one-off Rake process. Serving web and employee-API processes cache subdomain lookups for `TenantSubdomainRegistry::CACHE_TTL` (**45 seconds**).

Before running subdomain or employee-app smoke checks:
- **Wait at least 50 seconds** after the final conversion commit (or restart the serving web and employee-API services if an immediate cache flush is required).

---

## 5. Smoke checks before Track D

1. **Staff app:** select each converted demo company; confirm the grey **Demo** chip appears in the switcher, lists, Year-End queue, and Client Inbox, and that firm client counts, inbox counters, and finance/billing screens are unchanged.
2. **Containment check:** with a converted demo selected, verify shared settings (tax configs, filing submitter, retirement limits), finance/invoicing, AIRE/time tracking, and production e-file downloads are still refused.
3. **Employee app & posted stubs:** open a converted demo employee login on its subdomain (`harborfinch` / `harborfinch-catering`); confirm the **Demo** pill appears, existing pay stubs open normally, and the next `PostEmployeePayStubsJob` sweep does **not** create replacement revisions (`revision` count stays unchanged).
4. **Lifted workflows:** confirm Year-End queue, Form 500, and register list behave normally for the converted demo.

---

## 6. Sequencing Track D (`rake demo:rename_fixture`, PR #648) in the same release window

Run **Track B first, Track D second** in the same release window:

1. **Why Track B goes first:** Track D (`rake demo:rename_fixture`) intentionally updates demo employee names (`Employee 01` … `Employee 11`), company addresses, QuickBooks historical worker/paycheck names and keys, and login labels. Because `PayrollReview::CalculationSnapshot` includes employee names and `PayStubGenerator#employee_payroll_facts_sha256` includes `employee.legal_name`, running Track D before Track B would invalidate Track B's zero-payroll-diff invariant. Running Track B first proves with `unexpected_diffs=0` that the shape migration itself altered zero payroll figures, checksums, or access rules.
2. **Compatibility across Track B → Track D:** `DemoCompany::ConvertToFlag` preserves `test_workspace_manifest` byte-identically (including `demo_fixture_key`), and `DemoCompany::RenameFixture` selects companies via `Company.demo` + `demo_fixture_key`, so `rake demo:rename_fixture` works identically on converted new-shape demos.
3. **Target IDs for Track D:** `rake demo:rename_fixture` only accepts the two Harbor Finch fixture keys (`harbor-finch-kitchen` and `harbor-finch-catering`, i.e., companies `7` and `8`). If another non-fixture old-shape demo (such as `14`) was converted in Track B, do **not** pass it in `COMPANY_IDS` for `demo:rename_fixture`.
4. **Run Track D after §5 passes (optionally take a quick post-Track-B Neon checkpoint first):**

```sh
# 1. Dry run (default): inspect PLAN lines (record IDs and field names only)
ORGANIZATION_ID=<org-id> ACTOR_ID="$ACTOR_ID" COMPANY_IDS=7,8 \
  bundle exec rails demo:rename_fixture

# 2. Apply (pass EMPLOYEE_MAP / CLIENT_USER_MAP only if dry run reports unmatched/ambiguous rows)
ORGANIZATION_ID=<org-id> ACTOR_ID="$ACTOR_ID" COMPANY_IDS=7,8 APPLY=true \
  bundle exec rails demo:rename_fixture
```

5. **Clean up temporary snapshot files** (after archiving pass/fail summaries privately, and if Write Maintenance was enabled in §1, disable it per [WRITE_MAINTENANCE.md](../runbooks/WRITE_MAINTENANCE.md)):

```sh
rm -f /tmp/track-b-before-*.json /tmp/track-b-after-*.json
```

---

## 7. Handling partial apply

- If a multi-company run ever fails partway through (for example company `7` committed and company `8` raised midway), company `8`'s transaction rolled back completely while company `7` stayed converted.
- **Recommended workflow:** convert one company at a time (§3) so partial multi-company runs do not occur.
- If a prior company already converted cleanly and a later company failed:
  - Inspect why the later company failed.
  - Either fix and retry only the failed company, OR roll back the already-converted company with §8a (`demo:revert_to_legacy_shape`) without touching unrelated production data.

---

## 8. Rollback

### 8a. Primary rollback: targeted per-company revert (preserves all unrelated production writes)

Use this whenever `demo:verify_shape_diff` reports any unexpected difference or a post-conversion smoke check fails before any post-conversion filing/liability/non-employee-check rows have been created on the company:

1. **Stop the window immediately.** Do not convert further companies and do not run `demo:rename_fixture`.
2. **Dry-run the targeted revert** for each converted company using its captured before snapshot:

```sh
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" \
  BEFORE="/tmp/track-b-before-${COMPANY_ID}.json" \
  bundle exec rails demo:revert_to_legacy_shape
```

3. **Apply the targeted revert** via the owner shell (`MIGRATION_DATABASE_URL`, `RLS_CONTEXT_GUARD_MODE=off`):

```sh
RLS_CONTEXT_GUARD_MODE=off MIGRATION_DATABASE_URL="$MIGRATION_DATABASE_URL" \
  ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" \
  BEFORE="/tmp/track-b-before-${COMPANY_ID}.json" APPLY=true \
  bundle exec rails demo:revert_to_legacy_shape
```

This atomically restores the exact pre-conversion `companies` shape columns and `employee_account_links.payroll_environment = 'migration_rehearsal'`, records an `AuditLog` (`demo_company#reverted_to_legacy_shape`), and leaves every real client's data untouched.

4. **Wait at least 50 seconds** (past `TenantSubdomainRegistry::CACHE_TTL`) or restart serving web and employee-API instances, then re-capture `demo:verify_shape_snapshot` and verify the restored state matches `/tmp/track-b-before-${COMPANY_ID}.json`.

### 8b. Last-resort rollback: Neon recovery branch restore

Use the §1 Neon recovery branch **only** if targeted revert is impossible (for example database corruption or post-conversion state that cannot be cleanly reverted):

1. **Warning:** a whole-DB Neon restore discards any unrelated production writes committed after the recovery point unless Write Maintenance ([WRITE_MAINTENANCE.md](../runbooks/WRITE_MAINTENANCE.md)) fenced all production writes from before the Neon branch was taken.
2. Enable Write Maintenance and suspend the worker if not already active.
3. Restore or promote the §1 Neon recovery branch to the recorded UTC timestamp.
4. Restart web, worker, and employee API so caches reload pre-migration state, re-verify against `/tmp/track-b-before-*.json`, and then lift Write Maintenance.

---

## 9. Follow-up (separate Contract phase)

Do **not** drop legacy-shape reads or legacy-demo database constraints in this release window. Once all production old-shape demo companies (`7`, `8`, and any others such as `14`) have been converted, verified with `unexpected_diffs=0`, and observed cleanly through normal operation, a separate Contract PR can:
- switch `DemoCompany::Create` to create new-shape demos directly;
- drop `convert_demo_company_to_flag` and `revert_demo_company_to_legacy_shape` and remove legacy-demo (`test_workspace_purpose = 'demo'`) branches from `Company`, `companies_test_workspace_shape_check`, `company_subdomain_requires_live_payroll`, `employee_account_links_live_or_demo_company`, `prevent_demo_company_conversion()`, and the retired `20261125180000`/`20261125210000` external-record triggers (keeping `time_tracking_sources_refuse_demo_company` keyed on `demo = true`).
