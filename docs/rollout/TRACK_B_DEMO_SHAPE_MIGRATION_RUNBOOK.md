# Track B demo shape migration runbook

**What this is:** the operator runbook for converting existing production old-shape demo companies (`payroll_environment = 'migration_rehearsal'`, `test_workspace_purpose = 'demo'`, `demo = false`) to the new Track B shape (`payroll_environment = 'live'`, `demo = true`, test-workspace columns cleared, `employee_account_links.payroll_environment = 'live'`).

**Target production companies:** companies `7` and `8`, plus any other old-shape demo company discovered in the pre-flight inventory (for example `14`).

**Related PRs and docs:**
- Track B Expand & D-3 markers: PRs #644, #645 (and follow-up #653).
- Track D simple demo names & invented addresses: PR #648 (`rake demo:rename_fixture`).
- [Postgres RLS enforcement runbook](RLS_ENFORCEMENT_RUNBOOK.md).

This repo is public. Never commit real client names, person names, email addresses, EINs, tokens, or raw snapshot JSON files into git, a PR, or a ticket. Keep snapshot outputs and rollout logs in the access-controlled rollout evidence location.

---

## 0. Preconditions

Confirm every item before opening the maintenance window:

1. **Owner approval:** Leon's explicit go-ahead for the release window and target company IDs.
2. **Code deployed everywhere:** the revision containing `20261127170000_prepare_demo_company_shape_migration.rb`, `DemoCompany::ConvertToFlag`, `DemoCompany::VerifyShapeMigration`, and PR #648 (`DemoCompany::RenameFixture`) is deployed to Payroll web, Solid Queue worker, and the Employee API.
   - Verify the pre-conversion migration applied cleanly via the normal owner-backed deploy path (`bin/rails db:safe_prepare`). This migration is dual-shape safe and makes no data changes on deploy; it makes `fk_employee_account_links_live_company` `DEFERRABLE INITIALLY IMMEDIATE` and opens the guarded `app.allow_demo_shape_migration` one-way transition inside `prevent_demo_company_conversion()`.
3. **No concurrent demo jobs or payroll work on the target demos:** confirm no `demo:seed` or `demo:rename_fixture` run is active.
4. **Operator actor ready:** identify the active organization-administrator `ACTOR_ID` (and `ORGANIZATION_ID`, optional when it matches the actor's organization).

---

## 1. Create a Neon backup / recovery branch first

Before running any command that writes to production:

1. Create a named Neon recovery branch (or point-in-time snapshot) from the production primary right before the window (for example `pre-track-b-demo-migrate-YYYYMMDD-HHMMZ`).
2. Record the exact branch name, UTC recovery timestamp, and deployed commit SHA in the private rollout record.
3. Keep the recovery branch isolated from live services and outbound integrations, and confirm the direct owner connection string can restore or promote it if rollback is required.

---

## 2. Inventory old-shape demo companies (read-only)

Run a read-only check from the Render shell in `api/` (or a read-only `psql` session) to confirm the exact IDs of all old-shape demo companies (expected: `7`, `8`, and check whether any additional demo such as `14` exists):

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

Verify every returned ID is an intended demo company (for example `7,8` or `7,8,14`). Set `TARGET_IDS` in your shell to the verified comma-separated list:

```sh
export ACTOR_ID=<org-admin-user-id>
export TARGET_IDS=7,8          # add any other verified old-shape demo IDs, e.g. 7,8,14
export TAX_YEAR=2026
```

---

## 3. Capture the read-only "before" verification snapshot

Run `demo:verify_shape_snapshot` (executes inside `SET TRANSACTION READ ONLY` with no job enqueues or window mutations):

```sh
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$TARGET_IDS" TAX_YEAR="$TAX_YEAR" \
  CHECK_EMPLOYEE_SERVICE=true \
  OUTPUT=/tmp/track-b-before.json \
  bundle exec rails demo:verify_shape_snapshot
```

Expect:

```text
OK    demo:verify_shape_snapshot companies=7,8 output=/tmp/track-b-before.json
```

This snapshot captures per company (without PII):
- logins and their access (`accessible_company_ids`, assignments, active/access flags);
- employee-app links and their statuses (`portal_eligible`, lock/reset/profile state);
- subdomain resolution (`enabled_origin_company_id`, branding digest, `demo` flag);
- employee app readiness and switch state (`stored_values`, `switched_on_values`, `effective_values`, open activations, readiness checks);
- firm counters (Client Inbox summary and rows, Year-End counts/hidden counts/listing, `InvoiceServiceFeeRevenue` live-client exclusion, `SharedEmailReport` exclusion, organization `client_limit` / live counts);
- EIN uniqueness (`index_live_companies_on_ein` exclusion and live-company sharing check);
- payroll figure checksums (`PayPeriod`, `PayrollItem` + earnings/deductions/field entries, `PayrollReview::CalculationSnapshot`, `PayrollItemLegacyDispositionService`, YTD totals, historical paychecks/balances, `EmployeeDocument` rows, and `PayStubGenerator` fingerprint match for every posted stub).

---

## 4. Dry run the conversion

Run `demo:convert_to_flag` without `APPLY=true` (dry-run is the default and runs inside `SET TRANSACTION READ ONLY`):

```sh
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$TARGET_IDS" \
  bundle exec rails demo:convert_to_flag
```

Inspect every `PLAN` line:
- Only `company` rows for `$TARGET_IDS` and their `employee_account_link` rows appear.
- Only field names are printed (no values).
- Expect `OK    demo:convert_to_flag mode=dry_run converted=7,8 already_converted=none changes=...`.

If any unexpected ID or refusal appears, stop and investigate before applying.

---

## 5. Apply the conversion

Run with `APPLY=true`:

```sh
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$TARGET_IDS" APPLY=true \
  bundle exec rails demo:convert_to_flag
```

What happens per company, in one atomic transaction:
- Acquires the per-organization demo advisory lock and locks the company row and its `employee_account_links`.
- Sets `SET LOCAL lock_timeout = '5s'`, `SET LOCAL app.allow_demo_shape_migration = 'on'`, and `SET CONSTRAINTS fk_employee_account_links_live_company DEFERRED`.
- Sets `companies.demo = true`, `companies.payroll_environment = 'live'`, clears all test-workspace/migration-rehearsal columns (`test_workspace_purpose`, `migration_rehearsal_*`, `migration_source_*`, `test_workspace_expires_at/archived_at/sealed_at`), and keeps `test_workspace_manifest` (`demo_fixture_key`) untouched.
- Updates the company's `employee_account_links.payroll_environment` to `'live'`.
- Immediately re-checks `SET CONSTRAINTS fk_employee_account_links_live_company IMMEDIATE` before commit.
- Writes an `AuditLog` row (`demo_company#converted_to_flag`) inside the same transaction.
- Invalidates `TenantSubdomainRegistry` after commit.

Expect:

```text
OK    demo:convert_to_flag mode=applied converted=7,8 already_converted=none changes=...
```

Optional idempotency check (re-running the exact same command writes nothing):

```sh
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$TARGET_IDS" APPLY=true \
  bundle exec rails demo:convert_to_flag
```

Expect `converted=none already_converted=7,8 changes=0`.

---

## 6. Capture the "after" snapshot and run the diff

```sh
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$TARGET_IDS" TAX_YEAR="$TAX_YEAR" \
  CHECK_EMPLOYEE_SERVICE=true \
  OUTPUT=/tmp/track-b-after.json \
  bundle exec rails demo:verify_shape_snapshot

BEFORE=/tmp/track-b-before.json AFTER=/tmp/track-b-after.json \
  bundle exec rails demo:verify_shape_diff
```

**Gate:** require:

```text
OK    demo:verify_shape_diff companies=7,8 unexpected_diffs=0
```

Only `companies.<id>.shape.*` fields (`demo`, `payroll_environment`, cleared test-workspace columns, and `employee_account_links_payroll_environments.*`) are allowed to differ.

**If `demo:verify_shape_diff` exits non-zero or reports ANY `DIFF` line, STOP immediately and execute §9 (Rollback).** Do not proceed to Track D.

---

## 7. Smoke checks before Track D

1. **Staff app:** select each converted demo company; confirm the grey **Demo** chip appears in the switcher, lists, Year-End queue, and Client Inbox, and that firm client counts, inbox counters, and finance/billing screens are unchanged.
2. **Containment check:** with a converted demo selected, verify shared settings (tax configs, filing submitter, retirement limits), finance/invoicing, AIRE/time tracking, and production e-file downloads are still refused.
3. **Employee app & posted stubs:** open a converted demo employee login on its subdomain (`harborfinch` / `harborfinch-catering`); confirm the **Demo** pill appears, existing pay stubs open normally, and the next `PostEmployeePayStubsJob` sweep does **not** create replacement revisions (`revision` count stays unchanged).
4. **Lifted workflows:** confirm Year-End queue, Form 500, and register list behave normally for the converted demo.

---

## 8. Sequencing Track D (`rake demo:rename_fixture`, PR #648) in the same release window

Run **Track B first, Track D second** in the same release window:

1. **Why Track B goes first:** Track D (`rake demo:rename_fixture`) intentionally updates demo employee names (`Employee 01` … `Employee 11`), company addresses, QuickBooks historical worker/paycheck names and keys, and login labels. Because `PayrollReview::CalculationSnapshot` includes employee names and `PayStubGenerator#employee_payroll_facts_sha256` includes `employee.legal_name`, running Track D before Track B would invalidate Track B's zero-payroll-diff invariant. Running Track B first proves with `unexpected_diffs=0` that the shape migration itself altered zero payroll figures, checksums, or access rules.
2. **Compatibility across Track B → Track D:** `DemoCompany::ConvertToFlag` preserves `test_workspace_manifest["demo_fixture_key"]`, and `DemoCompany::RenameFixture` selects companies via `Company.demo` + `demo_fixture_key`, so `rake demo:rename_fixture` works identically on converted new-shape demos.
3. **Target IDs for Track D:** `rake demo:rename_fixture` only accepts the two Harbor Finch fixture keys (`harbor-finch-kitchen` and `harbor-finch-catering`, i.e., companies `7` and `8`). If another non-fixture old-shape demo (such as `14`) was converted in Track B, do **not** pass it in `COMPANY_IDS` for `demo:rename_fixture`.
4. **Run Track D after §6 passes (optionally take a quick post-Track-B Neon checkpoint first):**

```sh
# 1. Dry run (default): inspect PLAN lines (record IDs and field names only)
ORGANIZATION_ID=<org-id> ACTOR_ID="$ACTOR_ID" COMPANY_IDS=7,8 \
  bundle exec rails demo:rename_fixture

# 2. Apply (pass EMPLOYEE_MAP / CLIENT_USER_MAP only if dry run reports unmatched/ambiguous rows)
ORGANIZATION_ID=<org-id> ACTOR_ID="$ACTOR_ID" COMPANY_IDS=7,8 APPLY=true \
  bundle exec rails demo:rename_fixture
```

5. **Clean up temporary snapshot files** after recording pass/fail summaries privately:

```sh
rm -f /tmp/track-b-before.json /tmp/track-b-after.json
```

---

## 9. Rollback

`companies_demo_shape_immutable` intentionally enforces a one-way transition (legacy demo → live+demo) so converted demos can never be silently downgraded by SQL.

If `demo:verify_shape_diff` reports any unexpected difference or a post-conversion smoke check fails:

1. **Stop the window immediately.** Do not run `demo:rename_fixture` or any Contract migration.
2. **Pause writes** on the staff web, worker, and employee API services (or put the window in maintenance mode).
3. **Restore from the §1 Neon backup / recovery branch** (point-in-time restore to the recorded pre-window UTC timestamp, or promote the pre-window Neon branch).
4. **Invalidate caches and restart web/worker/employee API** so `TenantSubdomainRegistry` and request caches reload pre-migration state.
5. **Re-run `demo:verify_shape_snapshot`** and confirm the pre-window state matches `/tmp/track-b-before.json` before reopening normal traffic.

---

## 10. Follow-up (separate Contract phase)

Do **not** drop legacy-shape reads or legacy-demo database constraints in this release window. Once all production old-shape demo companies (`7`, `8`, and any others such as `14`) have been converted, verified with `unexpected_diffs=0`, and observed cleanly through normal operation, a separate Contract PR can:
- switch `DemoCompany::Create` to create new-shape demos directly;
- remove legacy-demo (`test_workspace_purpose = 'demo'`) branches from `Company`, `companies_test_workspace_shape_check`, `company_subdomain_requires_live_payroll`, `employee_account_links_live_or_demo_company`, `prevent_demo_company_conversion()`, and the retired `20261125180000`/`20261125210000` external-record triggers (keeping `time_tracking_sources_refuse_demo_company` keyed on `demo = true`).
