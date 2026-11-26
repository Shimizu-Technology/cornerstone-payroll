# Track B demo shape migration runbook

**What this is:** the operator runbook for converting existing production old-shape demo companies (`payroll_environment = 'migration_rehearsal'`, `test_workspace_purpose = 'demo'`, `demo = false`) to the new Track B shape (`payroll_environment = 'live'`, `demo = true`, test-workspace columns cleared, `employee_account_links.payroll_environment = 'live'`).

**Target production companies:** discover all old-shape demo companies from the live read-only inventory query in §2 (`payroll_environment = 'migration_rehearsal'` AND `test_workspace_purpose = 'demo'`) — **never** rely on a hard-coded ID list. On production, the old-shape demo companies are **`14`** and **`15`**. Convert **one company at a time**: **`14`**, then run the full before/after verification gate, then **`15`**, then run the full before/after verification gate. Non-demo `migration_rehearsal` workspaces (`test_workspace_purpose` in `migration_rehearsal`, `backup_snapshot`, `sandbox`, `training_replay`) are **not** demos and are refused by `demo:convert_to_flag`.

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
2. **Code deployed everywhere:** the revision containing `20261127170000_prepare_demo_company_shape_migration.rb`, `DemoShapeConversion`, `DemoCompany::ConvertToFlag`, `DemoCompany::RevertToLegacyShape`, `DemoCompany::VerifyShapeMigration`, and PR #648 (`DemoCompany::RenameFixture`) is deployed to Payroll web, Solid Queue worker, and the Employee API.
   - Verify the pre-conversion migration applied cleanly via the normal owner-backed deploy path (`bin/rails db:safe_prepare`). This migration is dual-shape safe and makes no data changes on deploy; it creates the append-only `demo_shape_conversions` table, makes `fk_employee_account_links_live_company` `DEFERRABLE INITIALLY IMMEDIATE`, installs the owner-only `SECURITY DEFINER` functions `convert_demo_company_to_flag` and `revert_demo_company_to_legacy_shape` (revoked from `PUBLIC` and never granted to `payroll_app`), hardens `prevent_demo_company_conversion()`, and adds `FOR KEY SHARE` company-row locking to `prevent_demo_company_external_records()`.
3. **Owner shell ready for `APPLY=true`:** read-only snapshots (`demo:verify_shape_snapshot`) and dry runs (`demo:convert_to_flag` with `APPLY=false`) run on the normal runtime connection. Applying (`APPLY=true`) or reverting (`demo:revert_to_legacy_shape APPLY=true`) requires the secured owner shell with `RLS_CONTEXT_GUARD_MODE=off` and the direct non-pooler `MIGRATION_DATABASE_URL` (the runtime `payroll_app` role cannot execute the conversion functions or pass the owner check in the trigger).
4. **No concurrent demo jobs or payroll work on the target demos:** confirm no `demo:seed` or `demo:rename_fixture` run is active.
5. **Operator actor ready:** identify the active organization-administrator `ACTOR_ID` (and `ORGANIZATION_ID`, optional when it matches the actor's organization).

---

## 1. Take a Neon recovery branch first (and decide on write fencing)

1. Create a named Neon recovery branch (or point-in-time snapshot) from the production primary right before the window (for example `pre-track-b-demo-migrate-YYYYMMDD-HHMMZ`). Record the branch name, UTC recovery timestamp, and deployed commit SHA in the private rollout record. Keep the branch isolated from live services and outbound integrations.
2. **Understand rollback scope:**
   - **Primary rollback (no data loss for real clients):** §8a enables **Write Maintenance** briefly and runs `demo:revert_to_legacy_shape` with the recorded `CONVERSION_ID` from `demo_shape_conversions` to restore only that company's exact recorded before-state and `employee_account_links.payroll_environment`, without touching unrelated production writes.
   - **Last-resort whole-DB Neon restore (not lossless under Write Maintenance alone):** restoring a whole-database Neon backup discards **every** write committed after the recovery point. Per [Payroll write maintenance](../runbooks/WRITE_MAINTENANCE.md), even with `WRITE_MAINTENANCE=true`, read requests can still write sign-in activity and access logs, and direct database sessions or Rake tasks bypass the HTTP switch. Do **not** treat a whole-DB Neon restore as lossless unless all non-migration writers are stopped before the recovery branch is created through verification (see §8b). Rely on the targeted per-company rollback in §8a as the primary rollback and keep the Neon branch strictly as a disaster-recovery last resort with an approved recovery plan for any post-checkpoint writes.

---

## 2. Inventory old-shape demo companies (read-only)

**You MUST discover target IDs by querying `test_workspace_purpose = 'demo'`, never from a hard-coded list.** Other `payroll_environment = 'migration_rehearsal'` rows can be real-client test workspaces (`migration_rehearsal`, `backup_snapshot`, `sandbox`, or `training_replay`), which are **not** demos and will be refused by `demo:convert_to_flag`.

Run this read-only check from `api/` to discover every old-shape demo company (on production, expected IDs are **`14`** and **`15`**):

```sh
bundle exec rails runner '
  TenantScope.as_system(reason: "Inventory old-shape demo companies") do
    demos = Company.where(payroll_environment: "migration_rehearsal", test_workspace_purpose: "demo")
      .order(:id)
      .pluck(:id, :organization_id, :demo, :payroll_environment, :test_workspace_purpose, :migration_rehearsal_status)
    demos.each { |r| puts "OLD_SHAPE_DEMO id=#{r[0]} org=#{r[1]} demo=#{r[2]} env=#{r[3]} purpose=#{r[4]} status=#{r[5]}" }
    puts "DEMO_COUNT=#{demos.size}"

    non_demo_rehearsals = Company.where(payroll_environment: "migration_rehearsal")
      .where.not(test_workspace_purpose: "demo")
      .order(:id)
      .pluck(:id, :test_workspace_purpose)
    non_demo_rehearsals.each { |id, purpose| puts "EXCLUDED_NON_DEMO id=#{id} purpose=#{purpose}" }
  end
'
```

Verify every `OLD_SHAPE_DEMO` ID is an intended demo company and confirm every `EXCLUDED_NON_DEMO` row (`migration_rehearsal`, `backup_snapshot`, `sandbox`, etc.) is left untouched. Process **one discovered demo company ID at a time** (**`14`** first, verify with `unexpected_diffs=0`, then **`15`**, verify with `unexpected_diffs=0`) so a failure or diff mismatch on one company stops immediately before the next company is touched.

```sh
export ACTOR_ID=<org-admin-user-id>
export TAX_YEAR=2026
```

---

## 3. Convert and verify ONE company at a time (`14`, then verify, then `15`, then verify)

Set `COMPANY_ID` to the first discovered old-shape demo company from §2 (on production: `14`):

```sh
export COMPANY_ID=14
```

### 3a. Capture the read-only "before" snapshot

Runs inside its own `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY` transaction with strictly read-only predicates (zero window retirements, zero account deactivations, zero job enqueues):

```sh
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" TAX_YEAR="$TAX_YEAR" \
  CHECK_EMPLOYEE_SERVICE=true \
  OUTPUT="/tmp/track-b-before-${COMPANY_ID}.json" \
  bundle exec rails demo:verify_shape_snapshot
```

Expect:

```text
OK    demo:verify_shape_snapshot companies=14 output=/tmp/track-b-before-14.json
```

Keep `/tmp/track-b-before-${COMPANY_ID}.json` intact until the entire window succeeds so §3d can diff against it (and §8a can verify any post-revert state against it).

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
ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" APPLY=false \
  bundle exec rails demo:convert_to_flag
```

Inspect every `PLAN` line:
- Only the single `company` row (`id=$COMPANY_ID`) and its `employee_account_link` rows appear.
- Only field names are printed (no values).
- Expect `OK    demo:convert_to_flag mode=dry_run converted=14 already_converted=none changes=...`.

### 3c. Apply the conversion (owner shell with `MIGRATION_DATABASE_URL`)

Run in the secured owner shell with `MIGRATION_DATABASE_URL` set and `RLS_CONTEXT_GUARD_MODE=off`:

```sh
RLS_CONTEXT_GUARD_MODE=off MIGRATION_DATABASE_URL="$MIGRATION_DATABASE_URL" \
  ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" APPLY=true \
  bundle exec rails demo:convert_to_flag
```

What happens in one atomic transaction for `$COMPANY_ID`:
- Refuses if an outer transaction is open; acquires the per-organization demo advisory lock and locks the company row and its `employee_account_links`.
- Verifies the company is an old-shape demo (`test_workspace_purpose = 'demo'`) and refuses real clients as well as non-demo `migration_rehearsal`, `backup_snapshot`, `sandbox`, and `training_replay` workspaces.
- Verifies the company has zero time-tracking sources or AIRE history approvals.
- Calls the owner-only `SECURITY DEFINER` function `convert_demo_company_to_flag(...)`, which verifies the table-owner role, locks the company row `FOR UPDATE`, records the exact pre-conversion shape and link environments in the append-only `demo_shape_conversions` table, defers `fk_employee_account_links_live_company`, sets `demo = true` and `payroll_environment = 'live'`, clears all test-workspace/rehearsal columns while keeping `test_workspace_manifest` byte-identical, updates `employee_account_links.payroll_environment` to `'live'`, and immediately re-validates `fk_employee_account_links_live_company`.
- Writes an `AuditLog` row (`demo_company#converted_to_flag` with `conversion_id`) inside the same transaction.
- Invalidates `TenantSubdomainRegistry` in this process after commit.

Expect:

```text
OK    demo:convert_to_flag mode=applied converted=14 already_converted=none conversions=14:<conversion-id> changes=...
```

Record `<conversion-id>` in the private rollout record — §8a uses `CONVERSION_ID` if a targeted rollback is ever required.

Optional idempotency check (re-running the exact same command writes nothing):

```sh
RLS_CONTEXT_GUARD_MODE=off MIGRATION_DATABASE_URL="$MIGRATION_DATABASE_URL" \
  ACTOR_ID="$ACTOR_ID" COMPANY_IDS="$COMPANY_ID" APPLY=true \
  bundle exec rails demo:convert_to_flag
```

Expect `converted=none already_converted=14 conversions=none changes=0`.

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
OK    demo:verify_shape_diff companies=14 unexpected_diffs=0
```

`demo:verify_shape_diff` fails closed if:
- either snapshot is empty, missing fields/link maps, or uses an unsupported schema version;
- `before` was not a valid legacy-shape demo or `after` is not a valid flag-shape demo;
- any non-shape field, login access, link status, subdomain resolution, switch state, counter, EIN check, or payroll/payment/document checksum differs;
- any external time-tracking source or AIRE history review exists on the company.

**If `demo:verify_shape_diff` exits non-zero or reports ANY `DIFF` line, STOP immediately and execute §8 (Targeted Rollback) for `$COMPANY_ID`.** Do not convert the next company and do not proceed to Track D.

### 3e. Repeat §3a–§3d for the next discovered demo company (`15`)

Once company `14` passes §3d with `unexpected_diffs=0`, set `export COMPANY_ID=15` and repeat §3a–§3d (including the strict `unexpected_diffs=0` diff gate) for company `15` (and any additional `OLD_SHAPE_DEMO` ID returned by the §2 query).

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
3. **Target IDs for Track D:** `rake demo:rename_fixture` only accepts the two Harbor Finch fixture keys (`harbor-finch-kitchen` and `harbor-finch-catering`, discovered in §2 as production companies **`14`** and **`15`**). Confirm the IDs from the §2 inventory query; if another non-fixture old-shape demo was also converted in Track B, do **not** pass it in `COMPANY_IDS` for `demo:rename_fixture`.
4. **Run Track D after §5 passes (optionally take a quick post-Track-B Neon checkpoint first):**

```sh
# 1. Dry run: inspect PLAN lines (record IDs and field names only)
ORGANIZATION_ID=<org-id> ACTOR_ID="$ACTOR_ID" COMPANY_IDS=14,15 APPLY=false \
  bundle exec rails demo:rename_fixture

# 2. Apply (pass EMPLOYEE_MAP / CLIENT_USER_MAP only if dry run reports unmatched/ambiguous rows)
ORGANIZATION_ID=<org-id> ACTOR_ID="$ACTOR_ID" COMPANY_IDS=14,15 APPLY=true \
  bundle exec rails demo:rename_fixture
```

5. **Clean up temporary snapshot files** (after archiving pass/fail summaries privately, and if Write Maintenance was enabled in §1, disable it per [WRITE_MAINTENANCE.md](../runbooks/WRITE_MAINTENANCE.md)):

```sh
rm -f /tmp/track-b-before-*.json /tmp/track-b-after-*.json
```

---

## 7. Handling partial apply

- If a multi-company run ever fails partway through (for example company `14` committed and company `15` raised midway), company `15`'s transaction rolled back completely while company `14` stayed converted.
- **Recommended workflow:** convert one company at a time (§3) so partial multi-company runs do not occur.
- If a prior company already converted cleanly and a later company failed:
  - Inspect why the later company failed.
  - Either fix and retry only the failed company, OR roll back the already-converted company with §8a (`demo:revert_to_legacy_shape`) without touching unrelated production data.

---

## 8. Rollback

### 8a. Primary rollback: targeted per-company revert (bound to `CONVERSION_ID`, fenced with Write Maintenance)

Use this whenever `demo:verify_shape_diff` reports any unexpected difference or a post-conversion smoke check fails before any post-conversion filing/liability/non-employee-check rows have been created on the company. Revert reads the exact before-state strictly from the append-only `demo_shape_conversions` record (never from an external snapshot file) and **refuses to run unless `WRITE_MAINTENANCE=true` is enabled** so no concurrent filing/liability/check insert can race the revert:

1. **Stop the window immediately.** Do not convert further companies and do not run `demo:rename_fixture`.
2. **Enable Write Maintenance** per [Payroll write maintenance](../runbooks/WRITE_MAINTENANCE.md) (`WRITE_MAINTENANCE=true` on web + suspend the worker) and wait for in-flight requests/jobs to drain.
3. **Dry-run the targeted revert** using the `CONVERSION_ID` printed by §3c:

```sh
WRITE_MAINTENANCE=true ACTOR_ID="$ACTOR_ID" CONVERSION_ID=<conversion-id> APPLY=false \
  bundle exec rails demo:revert_to_legacy_shape
```

4. **Apply the targeted revert** via the owner shell (`MIGRATION_DATABASE_URL`, `RLS_CONTEXT_GUARD_MODE=off`, `WRITE_MAINTENANCE=true`):

```sh
WRITE_MAINTENANCE=true RLS_CONTEXT_GUARD_MODE=off MIGRATION_DATABASE_URL="$MIGRATION_DATABASE_URL" \
  ACTOR_ID="$ACTOR_ID" CONVERSION_ID=<conversion-id> APPLY=true \
  bundle exec rails demo:revert_to_legacy_shape
```

This locks the company row `FOR UPDATE`, verifies the recorded conversion has not already been reverted and the company's current shape still matches what conversion wrote, verifies zero post-conversion filing/liability/non-employee-check rows exist, atomically restores the exact recorded pre-conversion `companies` shape columns and `employee_account_links.payroll_environment`, marks the conversion record reverted, records an `AuditLog` (`demo_company#reverted_to_legacy_shape`), and leaves every real client's data untouched.

5. **Wait at least 50 seconds** (past `TenantSubdomainRegistry::CACHE_TTL`) or restart serving web and employee-API instances, re-capture `demo:verify_shape_snapshot`, and confirm the restored state matches `/tmp/track-b-before-${COMPANY_ID}.json`.
6. **Disable Write Maintenance** (re-enable web writes and resume the worker per [WRITE_MAINTENANCE.md](../runbooks/WRITE_MAINTENANCE.md)) once verification passes.

### 8b. Last-resort rollback: Neon recovery branch restore

Use the §1 Neon recovery branch **only** if the primary targeted per-company revert (§8a) is impossible (for example database corruption or post-conversion state that cannot be cleanly reverted):

1. **Residual data-loss risk:** a whole-DB Neon restore discards **all** writes committed after the recovery point — including real-client payroll/documents, operational metadata still written during read requests under `WRITE_MAINTENANCE=true` (sign-in activity, access logs), and any writes from direct database sessions or Rails/Rake tasks that bypass the HTTP switch (per [WRITE_MAINTENANCE.md](../runbooks/WRITE_MAINTENANCE.md)). Never treat a whole-DB restore as lossless under `WRITE_MAINTENANCE=true` alone.
2. **Full-writer fence (if preparing a clean whole-DB recovery point ahead of time):** before creating the recovery branch and continuously through post-migration verification, stop or scale to zero the Solid Queue worker **and** all three web services (Payroll API web, Employee API web, and any remaining web service attached to the primary database), and confirm no other database sessions remain via `pg_stat_activity`:

```sql
SELECT pid, usename, application_name, state, client_addr
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid();
```

   Confirm zero other active or idle application/operator sessions before creating the recovery branch, and keep those services stopped until verification completes.
3. **Approved post-checkpoint recovery plan:** if any services or direct DB sessions were active after the §1 recovery point, obtain owner approval on a written recovery/reconciliation plan for every write committed after the recovery timestamp **before** restoring or promoting the Neon branch.
4. Stop (or scale to zero) the worker and all three web services and verify `pg_stat_activity` shows no other DB sessions before restoring or promoting the §1 Neon recovery branch to the recorded UTC timestamp.
5. Bring services back up so caches reload pre-migration state, re-verify against `/tmp/track-b-before-${COMPANY_ID}.json`, and execute the approved post-checkpoint recovery plan if any post-checkpoint writes were affected.

---

## 9. Follow-up (separate Contract phase)

Do **not** drop legacy-shape reads or legacy-demo database constraints in this release window. Once all production old-shape demo companies discovered by the §2 query (`14` and `15`) have been converted, verified with `unexpected_diffs=0`, and observed cleanly through normal operation, a separate Contract PR can:
- switch `DemoCompany::Create` to create new-shape demos directly;
- drop `convert_demo_company_to_flag` and `revert_demo_company_to_legacy_shape` and remove legacy-demo (`test_workspace_purpose = 'demo'`) branches from `Company`, `companies_test_workspace_shape_check`, `company_subdomain_requires_live_payroll`, `employee_account_links_live_or_demo_company`, `prevent_demo_company_conversion()`, and the retired `20261125180000`/`20261125210000` external-record triggers (keeping `time_tracking_sources_refuse_demo_company` keyed on `demo = true`).
