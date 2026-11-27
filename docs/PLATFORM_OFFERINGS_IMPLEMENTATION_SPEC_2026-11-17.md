# Platform offerings: implementation spec

**Status:** Planned.
**Date:** November 17, 2026.
**Code read:** Payroll `main` at `162dd2ec`, AIRE `main` at `9ace66e5`.
**Builds on:** [Employee portal and platform plan](EMPLOYEE_PORTAL_AND_PLATFORM_PLAN_2026-11-17.md) and [W-2GU and 1099 year-end plan](W2GU_1099_YEAR_END_FILING_RESEARCH_2026-11-17.md).

Leon has approved the direction:
- client offerings are **settings**, not code;
- Payroll is the **one HR engine**;
- **sensitive changes are approved in Payroll**, whichever app submits them.

This document says exactly what to build, in what order, and what has to be true before each step ships. Unless marked "inferred", each claim was read in the code.

## 1. The three offerings

| Offering | Example today | Client admin uses | Employees use | Hours come from |
|---|---|---|---|---|
| **Payroll service** | Spike | Nothing; they email or send files to Cornerstone | Paper stubs, as today | An intake adapter or manual entry |
| **Payroll + portals** | MoSa's | The Cornerstone client portal | The Cornerstone employee portal | An intake adapter (Revel PDF + workbook, the universal workbook) or manual entry |
| **Workforce suite** | AIRE | The client's own branded time app, plus the client portal if wanted | The client's time app: clock-in, time, pay and HR | The connected time app (finalized batches) |

These rules apply to every offering:

1. **Profile settings, not code branches.** An offering is a named preset of settings in the client's operating profile (§3). Moving a client from one offering to another means changing its profile, with an effective date. No code may test a client's name, company id or source type to decide what a feature does.
2. **Payroll owns the records.** People, pay, tax, W-2GU/1099, deductions, benefits, PTO balances and HR documents all live in Payroll. Time apps own punches, schedules, time approvals and leave requests, and they never calculate pay.
3. **One HR engine, two front doors.** The Cornerstone employee portal and each time app read and write through the same Payroll services, so the numbers cannot disagree.
4. **Sensitive changes are approved in Payroll.** Bank account, W-4, SSN, legal name and classification changes always go through Payroll's approval queue, whichever app they come from. Pay and address changes from employees or time apps always do too. From client admins, they follow the client's review settings (§6). Payroll does its own verification and never trusts another app's login for these.
5. **AIRE keeps working byte for byte.** Nothing changes AIRE's My Pay, batches, calendar or cockpit unless a contract test in both repos proves it (§5).

## 2. Findings that shape the plan

1. **PR #139 (settings consolidation) should be closed.**
   - It is 1,594 commits behind `main` and conflicts in 25 files.
   - Its role checks are older than `StaffRolePolicy`.
   - It stores no per-client feature settings.
   - Only two ideas are worth keeping, by hand: grouping settings by scope and the readiness overview.
2. **Per-client settings are scattered and many have no UI.**
   - `payroll_intake_source_types` and `payroll_intake_settings` can only be set from the console. They are not audited and have no permitted parameters.
   - There is no client-portal on/off switch, no "Cornerstone reviews first" switch, no per-company document defaults, no tip or overtime-mode settings, and no year-end employer fields.
3. **Hard-coded gates:**

   | Gate | Where |
   |---|---|
   | `'mosa_revel'` / `'spike_email'` | About 10 places in the API and 6 in the web app |
   | `import_source == "mosa_revel"`, meaning "imported" | 5 places |
   | `source_type == "aire_services"` | About 25 branches |
   | `company_id == 2` | 1 place (`aire_category_setup.rb:6`) |

4. **Adding a capability to AIRE breaks its connection.**
   - Once a source's contract is pinned, any change to the capabilities AIRE advertises raises "integration contract changed; test the connection before continuing" (`time_tracking/client.rb:1036-1040`).
   - Until an operator re-tests, this blocks summaries, batches and cockpit calls.
   - So new employee-API permissions must be **grants stored in Payroll**, not capabilities AIRE advertises.
5. **AIRE's My Pay contract is unwritten and fails silently.**
   - AIRE allowlists about 40 response fields and validates their formats (`my_pay_presenter.rb`).
   - When one drifts, data quietly disappears. An earnings, tax or deduction line whose amount doesn't match `/\A-?\d{1,9}\.\d{2}\z/` is dropped. A summary amount that doesn't match becomes blank.
   - The test fakes have already drifted from real responses.
   - An unmapped worker must keep returning **404**. AIRE shows "not linked" for that, and shows "unavailable" for 401 or 403.
6. **The change-request queue is a good base but too narrow.**
   - It has only `pending/approved/rejected`.
   - The requester must be a staff or client `User`.
   - There is **one pending request per employee** across all channels (`idx_employee_change_requests_one_pending`).
   - There is no bank-change path at all.
   - Pay changes overwrite right away; effective dating was audit PR 5, not built.
7. **Employee identity needs a second Clerk application.**
   - The API verifies one Clerk issuer and auto-provisions any `User` with a matching verified email (`clerk_authenticatable.rb:148-183`). With a shared instance, an employee could sign in as a staff or client user.
   - `ApplicationController` also has a development bypass that falls back to an admin.
   - The employee namespace needs its own verifier and its own base controller.
8. **Security gaps that must close before employees are invited:**
   - **MFA is not enforced.** `REQUIRE_MFA: false` in `api/config/deploy.yml:65` is only an attestation that `production_readiness.rb` reads; nothing enforces it. No code reads Clerk's `fva` claim. Enforcing MFA needs three things: Clerk's "Require MFA" setting, an `fva` check in the API, and the identity cutover runbook.
   - **No SMS provider** exists in Payroll or AIRE. AIRE's `.env.example` lists ClickSend variables, but no code sends SMS.
   - **Employee actions can't be audited yet.** `AuditLog` has `user_id` plus actor email, name, role and metadata, which the worker-statement endpoint already uses for source actors. But `Auditable` skips logging when there is no `current_user`, so an `employee/*` controller would log nothing until that changes.
   - **Practice copies.** The client pay-stub scope (`PayPeriod.client_finished`, `pay_period.rb:330`) includes the baseline runs that exist only in practice-copy companies. An employee link must never point at a test or practice workspace, and the employee scope uses committed runs only.
   - **Minor:** Payroll's server-to-server statement PDF (`worker_statements_controller.rb:49`) is sent `inline` with no `Cache-Control`. AIRE's own browser response already sends it as an attachment with `no-store` (`my_pay_controller.rb:39,58`), so this is tidying, not a gap.
9. **Client portal plan status:**
   - Done: boundary fixes, Unicode PDFs, notifications, reports (6a/6b), most document and messaging work.
   - **Not built:** effective-dated pay (audit PR 5), the change policy with direct edits and terminations (PR 6), readable change diffs, record-view and sign-out events, and letting all of a company's client users see its requests.

## 3. Workstream A: the client operating profile

### Data model

**`client_operating_profiles`** keeps one row per version. It is effective-dated like `company_pay_schedules`.

| Column | Type | Notes |
|---|---|---|
| `company_id` | FK | |
| `effective_on`, `ends_on` | date | Versions may not overlap (exclusion constraint) |
| `version`, `lock_version` | int | |
| `offering` | string, check | `payroll_service`, `payroll_portals`, `workforce_suite` |
| `hours_source` | string, check | `connected_app`, `intake_adapter`, `manual`, `salaried_only` |
| `intake_adapter` | string, null | Must be a registered adapter key (§4) |
| `client_portal_enabled` | bool | |
| `employee_portal_enabled` | bool | |
| `options` | jsonb | Validated against the catalog. Unknown keys are rejected. |
| `changed_by_id`, `reason`, `confirmed_at` | | |

The `options` keys, each defined in the catalog:

- **Intake:** `intake.required_sources`, `tips.default` (`paid_in_check` or `already_paid_out`), `overtime.mode` (`source_reports`, `weekly_split`, `total_as_regular_warn_over_80`, `daily_records`), `workweek.alignment` (`aligned` or `warn_if_offset`).
- **Client portal:** `client_portal.review_first` (a map of field group to boolean, using the same groups as §6: profile, contact, address, pay, termination; bank, w4 and identity are always reviewed and have no switch), `client_portal.uploaders` (`all_client_users` or a named list), `client_portal.sensitive_documents_visible` (bool, default false).
- **Employee portal:** `employee_portal.features` (stubs, tax_forms, profile_requests, documents, pto, bank_requests, w4_requests) and `employee_portal.former_access_years` (default 6).
- **Year-end:** `year_end.kind_of_employer` (default `N`), `year_end.contact` (name, phone, email).

**`OperatingProfileCatalog`** is a Ruby class copied from AIRE's `SettingsCatalog` pattern (`settings_catalog.rb`). Each entry has:
- `id`, `label`, `section`, `type`, `default`, `allowed`
- `capability` (a `StaffRolePolicy` capability)
- `what`, `example`, `effect`
- `requires`, for example `employee_portal.features.bank_requests` requires the SMS provider and `employee_portal_enabled`

A spec fails when any key is missing a catalog entry, as AIRE's `settings_catalog_spec.rb` does.

### Who changes what

| Setting group | Capability |
|---|---|
| Offering, portals, client-portal options | `manage_client_administration`. An offering preset that would change the hours source also needs `manage_organization`; without it, the preset leaves the hours source alone and says so. |
| Hours source, connected app | `manage_organization` |
| Intake, tips, overtime | `manage_client_configuration` |
| Year-end fields | `manage_filing_review` |

### Reading it

- **`CompanyFeatures.for(company, on: date)`** is the only way code asks. Examples: `client_portal?`, `review_first?(:bank)`, `intake_adapter`, `overtime_mode`, `employee_portal_feature?(:stubs)`. Past pay periods resolve the profile in effect on the period's end date.
- **API:**
  - `GET /admin/companies/:id/operating_profile?on=` returns `{ effective, history, catalog, editable_keys }`.
  - `PATCH` takes `{ effective_on, changes, reason }` and inserts a new version. Old rows are never edited.
  - Each change writes an `AuditLog` before/after diff.
  - `effective_on` must be the start date of a pay period that hasn't been calculated, approved or committed. A change can't take effect partway through a period.
- **`/auth/me`** adds a compact `features` summary, so routes and the sidebar don't need extra calls.
- **Web:** a "How this client runs" settings page. It has one section per catalog group, (i) help on every setting, an offering preset picker that fills in defaults, and a readiness panel that flags mismatches (for example "Workforce suite, but no active connected source").

### Migration

1. Backfill one version per company, dated at its earliest live pay period:
   - `aire_services` source → `workforce_suite` / `connected_app`
   - `mosa_revel` → `payroll_portals` / `intake_adapter`
   - `spike_email` → `payroll_service` / `intake_adapter`
   - anything else → `payroll_service` / `manual`

   Copy `payroll_intake_settings` into `options`.
2. **Dual-read for one release.** `CompanyFeatures` reads the profile, and a spec checks it agrees with the old columns for every company.
3. Replace each hard-coded gate from §2.3 with `CompanyFeatures`, one PR per area (§9).
4. Stop writing the old columns, but keep them until a later cleanup.
5. Test-workspace and practice-copy creation (`test_workspace/create.rb`, `training_replay/create.rb`) copy profile versions.

## 4. Workstream B: intake for any client

### Adapter descriptors

Every intake adapter declares a descriptor. MoSa's example:

```ruby
descriptor(
  key: "mosa_revel", label: "Revel hours + Cornerstone workbook", parser_version: "mosa_revel:v1",
  files: [
    { role: "revel_hours", label: "Revel hours PDF", accept: [".pdf"], max: 1,
      provides: %i[regular_hours overtime_hours] },
    { role: "supplemental_workbook", label: "Tips & loans workbook", accept: [".xlsx", ".xls"], max: 1,
      waivable: "No tips or loans this period",
      provides: %i[reported_tips tips_already_paid loan_one_time loan_installment one_time_earnings owner_pay] } ],
  extraction: :deterministic, employee_match: :name_fuzzy, idempotency: :files_roster_loans,
  portal: { submittable: true, role_map: { "revel_payroll" => "revel_hours", "changes_workbook" => "supplemental_workbook" } })
```

- **Endpoints:** `GET /admin/companies/:id/intake_profile`, plus a client-scoped version, return the enabled descriptors with the client's settings.
- **Rendering:** the staff import menu, the `ImportModal` file pickers, `importSources.ts` and the client `SubmissionForm` all render from the descriptor. `CreateRevision`, `FileSet` and `ImportBridge` validate against the same descriptor.
- **Keys stay the same.** Keep the key `mosa_revel`, because it feeds the idempotency hash and the indexes on live packages. Its label can change.

### Separating "imported" from the source

- Add `payroll_items.import_origin`, a checked string: `intake`, `time_tracking`, `timecard_ocr` or `correction`. Add the predicates `intake_imported?` and `imported_by?(key)`.
- Replace each of the five `import_source == "mosa_revel"` checks:

  | File | What it controls |
  |---|---|
  | `import_service.rb:22` | Skips the overwrite confirmation |
  | `live_preview_row_state.rb:57` | Hand-edit detection |
  | `payroll_item.rb:688` | Keeps job buckets in sync |
  | `import_changes.rb:30` | Overwrite required |
  | `import_changes.rb:236` | Overwrite required |

- **Read** the new JSON keys `imported_hours` and `missing_source_hours`, falling back to the `mosa_*` keys. **Write** only the new keys.
- **`bonus_source`:** accept a new value, `import`, and keep `mosa_revel` valid.
- **Backfill** in batches with `update_all`. Before running it, confirm that no trigger blocks updates to committed rows, and record the row counts for each `import_source`.

### Universal workbook (`cornerstone_workbook` adapter)

- **Starting point:** generalize `MosaSupplementalTemplate` (schema `cornerstone-mosa-supplemental/v2`) into `UniversalWorkbook::Template`.
- **Contents:** a roster prefilled by Employee ID, an HOURS sheet (regular, OT, PTO and holiday, optionally by week), tips, loans and one-time items. Sheets a client doesn't use are hidden.
- **Parsing:** with the generated-template branch of `LoanTipExcelParser`, matching on `employee_id`.
- **Non-POS workbook-hours case:** the workbook supplies hours for an employee missing from the Revel PDF. When two sources give hours for the same person, that's a conflict warning, not a silent pick. The sheet is rejected today (`loan_tip_excel_parser.rb:404-411`).

### Tips and overtime as settings

- **Tips.** `tips.default` seeds the import's "tips already paid" choice. A value on an individual row wins, and the evidence records which one applied.
  - MoSa's: `paid_in_check`, which is today's behavior.
  - Spike: `already_paid_out`, which is today's behavior.
- **Overtime.** `overtime.mode` replaces each adapter's own `reports_overtime?`.
  - MoSa's: `source_reports`.
  - Spike: `weekly_split` today. It becomes `total_as_regular_warn_over_80` when Leon's Nov 7 decision ships; today it errors instead.
  - The pay-period length comes from `pay_frequency`, instead of the fixed `PERIOD_DAYS = 14`.

### Protecting MoSa's live import

- **Before the next MoSa run:** only the golden characterization specs and the descriptor wrapper (PRs B1–B2), which change no behavior.
- **Everything after B2** merges after that run.
- **Parity check before switching:** before MoSa moves to a refactored path, Dafne or Mark runs it on staging and compares it to the last applied MoSa run.

## 5. Workstream C: connected time for any client, with AIRE protected

### Protect AIRE first

1. **Shared contract fixtures.**
   - Add `worker_statements_v1_list.json` and `worker_statements_v1_detail.json` to both repos.
   - The fixtures cover hourly pay with OT, a carryover entry, taxes, a deduction, other pay, a salaried row, a contractor and a voided check.
   - **In Payroll,** a spec builds real responses and checks they match the fixture exactly, apart from ids.
   - **In AIRE,** a spec drives all three fakes from the fixture, and a pinned `my_pay_presented_v1.json` locks what AIRE's front end receives.
   - A CI step diffs each repo's copy against the other repo's `main`. Today the cutoff fixture is kept in sync by comments only.
2. **Extract `EmployeePay::StatementService`.** It covers scope, eligibility, voided history and serializers, and goes behind the existing controller. These stay unchanged:
   - audit action strings
   - error bodies and status codes, including **404 for an unmapped worker**
   - the PDF filename

   The fixture spec must pass with no changes.
3. **Grants instead of source type.**
   - Add `time_tracking_sources.employee_api_scopes`, a jsonb array **set by Payroll staff**.
   - Backfill `["worker_statements_v1"]` for AIRE.
   - Gate access on `source_type == "aire_services" || scope granted` until the backfill is verified in production, then on the scope alone.
   - **Never** add these as capabilities that AIRE advertises (§2.4).
4. **Installation pinning on statement calls.**
   - First, Payroll validates `X-Payroll-Source-Instance-Id` only when the header is present, returning 409 on a mismatch.
   - Next, AIRE starts sending it. Before that AIRE deploy, confirm the production pinned id matches.
5. **Response headers (tidying).** Add `Cache-Control: private, no-store` to the server-to-server statement PDF. This is a header-only change; check that AIRE's client ignores it.

### Must stay green throughout

| Repo | Specs |
|---|---|
| Payroll | `integrations/aire/worker_statements_spec`, `rack_attack_spec`, `pay_run_activity_spec`, `connector_spec`, `cutoff_contract_spec`, the PayStubGenerator specs |
| AIRE | `worker_statements_client_spec`, `integration_profile_spec`, and the My Pay, preview, emails, pay stubs, pay stub periods and links, kiosk pay stubs, and time-entry My Pay request specs |

### Generalize for the next connected client

**Replace AIRE-only gates with grants or descriptors.** Each needs a spec showing AIRE's behavior is unchanged and a custom source works once granted:

- history approval and rollout receipts (`history_approval.rb:187-189`)
- category mapping and rate matching (`category_rate_matcher.rb:14-20`, `time_tracking_category_mapping.rb:45`)
- employee evidence links
- the `company_id == 2` check in `aire_category_setup.rb`

**Rename classes, keep strings.** New code goes in an `Integrations::TimePayroll::*` namespace, and the old class names stay as thin subclasses. The audit action strings (`worker_statement#viewed`, `#pdf_downloaded`, `worker_statements#listed`) and the URL paths must not change, because history, `record_activity_query.rb` and rack-attack depend on them.

**Configure the time app, not fork it.** In the AIRE codebase, for the next own-clock-in client:
- `SOURCE_TYPE` and the installation identity come from the environment, defaulting to `aire_services`
- the app advertises its policy constraints. **Not for AIRE's existing source:** Payroll compares advertised `policy_constraints` the same way it compares capabilities, and AIRE's pinned value is empty, so sending constraints would break AIRE's connection until it is re-tested. New installations advertise them from day one. AIRE only changes in a planned deploy followed by a connection re-test.
- one setting holds the time zone and workweek, replacing about 20 hard-coded Guam references
- the public website sits behind a flag
- the kiosk gets neutral routes, with the AIRE aliases kept

**Deployment model:** the next one to three clients each get their own deployment. A multi-tenant Workforce app comes later.

### Employee API v1 for time apps

- **Prefix:** `/api/v1/integrations/time_payroll/workers/:source_user_uuid/`. The three existing routes stay forever as version 1.
- **Reads:**
  - `ytd`
  - `tax_forms` and `tax_forms/:id/pdf` (needs per-employee W-2GU and 1099 PDFs from the year-end work)
  - `pto_balances` (needs Workstream F)
  - `profile` (masked: name, address, phone last four, filing status, deposit method, bank last four)
  - `documents` and `documents/:id/download`
- **Writes, each behind its own grant:**
  - `POST change_requests {kind, payload, idempotency_key}` returns `202 {id, status: "verification_required", challenge: {channel, masked_destination, expires_at}}`.
  - `POST change_requests/:id/verification {code}` returns `pending_review`.
  - `GET change_requests/:id` returns the status only, never the values.
- **Auth:**
  - the source secret must match exactly one active source that holds the grant;
  - the installation id must be present and match for every new grant;
  - the worker is resolved only through `TimeTrackingEmployeeMapping`;
  - a signed worker assertion lasting 60 seconds or less: optional for reads, **required for every write grant**. A leaked source secret alone then can't submit changes for arbitrary workers.
- **Audit:** `actor_type: "source_worker"`, with the source, installation, worker UUID, grant and forwarded request id. `PayRunActivityPhrase` should use the source's name instead of "in the AIRE app".
- **Rate limits:** keyed by source id rather than IP, because one time app proxies every worker. Writes are limited to about 5 per hour per worker, plus a cap on OTP attempts.

## 6. Workstream D: one approval queue for sensitive changes

The base is `employee_change_requests`. It already provides row locks, a stale-value check, an encrypted payload, the staff inbox and notifications.

### Schema changes

| Change | Detail |
|---|---|
| Requester | `requester_type` (`client_user`, `employee_account`, `time_source`, `staff`), plus `employee_account_id` and `time_tracking_source_id` next to `requested_by_id`. A check constraint requires exactly one. |
| Idempotency | `source_idempotency_key`, unique per source |
| Field group | `field_group` (`profile`, `contact`, `address`, `pay`, `w4`, `bank`, `identity`, `termination`) |
| One pending per group | Replace `idx_employee_change_requests_one_pending` with a unique index on `(employee_id, field_group)` over the pending and verification-pending statuses |
| Statuses | Add `verification_pending`, `withdrawn`, `expired`, `superseded` |
| Timing | `effective_pay_period_id`, `effective_on`, `cooling_off_until` |
| Verification evidence | `step_up` jsonb (session id, `fva`, reverification id, time) and `old_contact_notified_at` |
| Sensitive values | Every value in `bank`, `identity` and `w4` requests goes in the encrypted payload. Today only identifiers do. |

New tables:
- **`employee_change_verifications`** records how staff verified a change: method (`callback`, `prenote`, `document`, `otp`), who did it, the outcome and any evidence document.
- **`employee_payment_accounts`** holds effective-dated bank accounts with the status `pending_verification`, then `active`, then `ended`. The current account keeps paying until the new one is verified and its effective payroll arrives. This replaces overwriting the two bank columns on `employees`.
- **Effective-dated pay** (audit PR 5): `employee_compensation_changes`, so an approved pay change starts in a chosen pay period and never overwrites a rate already used by an approved or committed run.

### Rules by field group

The table is each channel's baseline. A client's `review_first` switch can add Cornerstone review to a group the client admin would otherwise change directly. Nothing removes a Payroll-side verification. Bank, W-4, identity and classification are always reviewed.

"Contact on file" means the employee record in Payroll (`employees`), not the login account. A contact change updates the employee record. Changing the login identifier itself happens in Clerk, with a notice to the old address.

| Group | Client admin | Employee portal | Time app | Payroll-side verification | Takes effect |
|---|---|---|---|---|---|
| Contact (phone, email) | Direct | Request, approved automatically after OTP to the *old* contact, with a notice to the old contact | Request plus Payroll OTP | OTP to the contact on file | Immediately |
| Address | Direct (review when review-first is on) | Request | Request plus OTP | Notice to the old address or email. From December 1 until W-2s are mailed, employee and time-app changes need staff review. | Immediately, except during the year-end window |
| Pay rate | Direct, effective-dated (review when review-first is on) | Not offered | Not offered | Staff review when it goes through the queue | The chosen pay period (effective-dated) |
| W-4 | Request plus the signed form | Electronic W-4 (Phase 2) | Not offered directly. The time app links to Payroll's signing page, because an OTP doesn't meet the e-W-4 jurat and signature rules. | Staff review of the form | The next payroll not yet approved |
| Bank account | Request | Request (Phase 2) | Request plus OTP | Staff approval plus a callback or prenote recorded in `employee_change_verifications`; alerts to the old and new contacts | The next payroll not yet approved, after verification |
| SSN, legal name, W-2/1099 classification | Request; Cornerstone only | Request plus a document | Not offered | Document check | Immediately after approval |
| Termination | Records the last day worked | Not offered | Not offered | Staff review | The chosen date; the employee link becomes `former` |

### Payroll-diversion protection

- A bank change within 30 days of a contact change, a new login, or account recovery always needs staff review, with a callback to the number on file *before* the contact change. `cooling_off_until` holds it until then.
- Every bank change sends a notice to the old and new contacts, and to the client admin.

### Account recovery

- Recovery is never self-serve. A lost phone or MFA device goes through staff-assisted re-proofing: known facts plus a new invite token, issued by Cornerstone or the client admin.
- The re-proofing is logged, and it starts the 30-day bank-change hold.
- Former employees recover through Cornerstone.

### Staff review screen

- Readable before/after diffs instead of raw JSON (from the unfinished audit PR 3).
- Shows the requester's channel and the evidence of verification.
- **Approve** is disabled for a bank change until a verification is recorded.
- Every client user at the company sees that company's requests. Today the list is filtered to the person who submitted.

## 7. Workstream E: employee identity and Employee Portal Phase 1

### Identity

- **A separate Clerk application.** Phone sign-in and MFA need Clerk Pro: about $25 a month, with 50,000 retained users included per app, and SMS at about $0.01 per message in the US (Guam's rate isn't confirmed).
- **Verification.** Add a per-audience verifier in the API. It holds its own issuer, JWKS URL and a JWKS cache key per issuer, plus an `azp` allowlist.
- **Base controller.** `Employee::BaseController` sits on `ActionController::API`. It never uses `User` lookup, auto-provisioning, the dev bypass, or `X-Company-Id` resolution.
- **Tables:**
  - `employee_accounts`: `clerk_user_id` (unique), issuer, email (citext) and when it was verified, phone (E.164) and when it was verified, `mfa_enrolled_at`, status, `last_sign_in_at`, `locked_until`. **No SSN.**
  - `employee_account_links`: account (null while invited), `company_id`, `employee_id` with a composite FK to `employees(id, company_id)`, status (`invited`, `active`, `former`, `revoked`), `invite_token_digest` (unique), invite expiry, `activated_at`, `former_at`, `former_access_until`, and revoke fields. One active or invited link per employee, enforced by a unique index.
  - `employee_consents`: append-only. Consent type (`w2_electronic`, `1099_electronic`, `esign`, `sms`), disclosure version and its SHA-256, when the employee showed they can open the format, granted and withdrawn times, IP, user agent and session id.
  - `employee_activation_attempts`: the factor *names* checked, never their values, plus the outcome, IP and user agent.
- **Activation:**
  1. The invite is looked up only by its high-entropy token.
  2. The employee confirms two facts on file. When those are missing, or the worker is an EIN contractor, they use another method instead (EIN last four plus ZIP, or a one-time code handed over in person).
  3. Every failure returns the same response with the same timing, and never says which fact failed.
  4. Each link locks after N attempts. Activation is throttled by IP, by link and by account, through Rack::Attack.
  5. MFA is required at activation, and a personal email is recommended.
- **Practice copies.** A link may never point at a test or practice workspace company (check constraint plus validation).
- **Termination.** The link becomes `former`, with read-only access to stubs and tax forms for `former_access_years`. `revoked` is only for fraud or a mislinked account.
- **AuditLog** gains `actor_type` and `employee_account_id`, so employee activity is logged.

### Phase 1 endpoints: `/api/v1/employee/*`

The employee always comes from the session plus an `X-Employee-Link-Id` header, which is checked against that account's links. No endpoint accepts an employee id or company id.

| Endpoint | Notes |
|---|---|
| `GET me`, `GET links` | Employer switcher |
| `POST activations` | Token plus the identity check |
| `GET pay_stubs`, `GET pay_stubs/:id`, `GET pay_stubs/:id/pdf` | Built from `EmployeePay::StatementService`, **committed periods only** (no practice-copy baselines). PDFs are sent with `private, no-store` and as an attachment. |
| `GET tax_forms`, `GET tax_forms/:id/pdf` | 2026 forms are posted next to the paper copies. Electronic-only delivery comes after consent. |
| `GET consents`, `POST consents`, `POST consents/:id/withdraw` | W-2 disclosure text is versioned |
| `GET profile` | Masked |
| `POST change_requests` | Contact and address in Phase 1 (Workstream D) |
| `GET documents`, `GET documents/:id/download` | Only documents marked visible to the employee. This needs a new `visible_to_employee` flag; client visibility does not count. |
| `POST session/sign_out` | Audited |

### Notifications

- **Email:** through the existing Resend outbox. The W-2 posting email's subject line must contain "IMPORTANT TAX RETURN DOCUMENT AVAILABLE". If it bounces, the employee gets a paper notice within 30 days.
- **SMS:** needs a provider. AIRE already uses ClickSend, so reusing it keeps vendors down. That's for Leon to decide (§10).

### Web

- **Separate front end.** A phone-first employee app with its own route tree and sign-in. It shares UI components, not routes.
- **Screens:** My pay (each check with gross, taxes, deductions, net and YTD), Pay history, Tax forms, My info, Documents and the employer switcher.
- **Standards:** an installable web app, targeting WCAG 2.1 AA.

### Gates before the first invite

1. Staff and client MFA enforced in production: Clerk's "Require MFA" setting on, the API checking `fva`, and the `REQUIRE_MFA` attestation set to true. MFA also required in the employee Clerk app.
2. The AIRE contract fixtures (Workstream C step 1) and `EmployeePay::StatementService` are merged.
3. A penetration-style review of `employee/*`. One employee must not be able to see a coworker's data through any id, header or cache.
4. A pilot with Cornerstone's own employees, then MoSa's, with Dafne's sign-off.

## 8. Workstream F: Phase 2 HR

1. **PTO.**
   - Payroll owns `pto_policies` (accrual per hour worked or per period, cap, carryover, waiting period) and `pto_ledger_entries` (accruals posted at commit, usage from paid `pto_hours`, adjustments with a reason).
   - The balance prints on stubs and appears in both portals and through `pto_balances_v1`.
   - Leave requests are made in the employee portal, or in the time app for connected clients. Approved leave arrives as PTO hours. For AIRE, that means the finalized batch, since its leave requests today are whole days with no hours.
   - Each client turns PTO on in its profile.
2. **Documents.**
   - Employee-visible documents, handbook and policy acknowledgments with an e-signature, and employee uploads against a requirement.
   - Uploads reuse the client document pipeline (`ClientDocumentFileValidator` type/byte/size checks). **Pilot uploads are allowed without a malware scanner** (`ClientDocumentScanner::Noop`), trusting pilot companies; add malware scanning before wider rollout beyond the pilot (Leon, Nov 22, 2026).
3. **Electronic W-4,** meeting 26 CFR 31.3402(f)(5)-1: confirmation of the signer's identity, the perjury jurat, and the signature as the final entry. It feeds `EmployeeW4ElectionChangeService`.
4. **Bank changes** from the employee portal and time apps, using the Workstream D rules.
5. **Benefits view:** effective-dated deductions linked to a light `benefit_plans` table (plan name, carrier contact, summary PDF).
6. **Client portal follow-ups,** reported separately in an earlier review:
   - remove client delete of documents;
   - hide sensitive documents from clients by default;
   - block uploads against requirements that have already been reviewed.

## 9. PR sequence

Year-end forms (the W-2GU plan, steps 0–5) take priority over everything here until filing is done. The work below runs alongside, where people are free.

| # | PR | Repo | Depends on | Changes behavior? | Gate |
|---|---|---|---|---|---|
| C1 | Worker-statement contract fixtures, both repos, plus a CI diff | Payroll + AIRE | none | No | Both suites green |
| B1 | Golden intake characterization specs (MoSa v2/legacy/PDF-only/workbook-only/portal revision/hand-edit re-import; Spike) | Payroll | none | No | Can merge before the next MoSa run |
| B2 | Adapter registry and descriptors, read-only `intake_profile` endpoint | Payroll | B1 | No | Can merge before the next MoSa run |
| A1 | `client_operating_profiles` table, catalog, backfill, `CompanyFeatures` dual-read, read-only API | Payroll | none | No | Agreement spec for every company |
| A2 | "How this client runs" settings page, PATCH with audit and effective-date rules | Payroll | A1 | Settings only | QA at desktop and mobile widths |
| C2 | Extract `EmployeePay::StatementService`, add PDF `no-store` | Payroll | C1 | No (fixture-identical) | AIRE suite green against the fixture |
| C3 | `employee_api_scopes` grants plus backfill, gate alongside the source type | Payroll | C2 | No for AIRE | AIRE My Pay smoke test on production |
| B3 | `import_origin` column, backfill and predicates | Payroll | B1 | Internal | After the MoSa run; row counts recorded |
| B4–B6 | Gates from descriptors and profile; staff UI and `SubmissionForm` from descriptors; submission roles | Payroll | B2, B3, A1 | Yes (same behavior for MoSa) | Parity check on staging |
| B7 | Tip and overtime settings, Spike's "over 80" mode | Payroll | A1, B4 | Yes | Spike parallel run |
| D1 | Change-request extensions (requester types, field group, statuses, per-group index), readable diffs, visibility for all client users | Payroll | A1 | Yes | Existing client edit specs green |
| D2 | Effective-dated compensation (audit PR 5) | Payroll | D1 | Yes | Approved and committed runs never change |
| D3 | Change policy and direct client edits by field group with `review_first` (audit PR 6), terminations | Payroll | A2, D2 | Yes | Policy matrix specs |
| N1 | OTP and SMS service: provider integration, hashed codes, TTL and attempt caps, delivery audit | Payroll | Leon's provider decision | New only | Delivery tested to Guam numbers |
| D4 | `employee_payment_accounts`, `employee_change_verifications`, bank review screen with Approve disabled until verified, diversion hold and recovery hold | Payroll | D1, N1 | Yes | Fraud-path specs |
| S1 | Enforce staff and client MFA in production; per-audience Clerk verifier refactor | Payroll | none | Yes (sign-in) | Identity cutover runbook |
| E1 | Employee identity tables, second Clerk app, `Employee::BaseController`, AuditLog actor | Payroll | S1 | No user-facing | Isolation specs |
| E2 | Invitations and activation (staff and client employee records), Rack::Attack rules, account recovery. Behind a platform flag that is off by default; no invites until E3's gates pass. | Payroll | E1, D1 | No (flag off) | Enumeration and lockout specs |
| E3 | Employee portal Phase 1 API and web: pay, history, profile, contact and address requests, documents, switcher, former access | Payroll | E2, C2, D3, N1 | Yes | Isolation review, then pilot on Cornerstone staff; this is when the flag turns on |
| E4 | Tax-form posting, consents, W-2 notice email and bounce handling | Payroll | E3, year-end per-employee PDFs | Yes | Disclosure text reviewed by Dafne |
| C4 | Installation-id pinning on statement calls | Payroll, then AIRE | C3 | No if the ids match | Pinned id checked on production |
| C5 | Generalize history approval, category mapping and evidence; remove the company-2 check; neutral namespace | Payroll | C3 | No for AIRE | AIRE regression suite |
| C6 | Employee API v1 reads (ytd, tax forms, profile, documents) | Payroll | C3, E4 | New only | Contract fixtures extended |
| C7 | Employee API v1 change requests with Payroll OTP and required signed worker assertions | Payroll + AIRE | D1, D4, N1, C6 | New only | Approval only inside Payroll |
| F1–F5 | PTO, documents and acknowledgments (pilot uploads allowed without scanner; add scanning before wider rollout — Leon, Nov 22, 2026), e-W-4, bank changes (needs D4), benefits view | Payroll + AIRE | D1–D4, E3 | Yes | Per-feature acceptance |
| W1–W2 | Configuration readiness in the AIRE codebase, then the second client's deployment | AIRE | C5 | No for AIRE | AIRE production unchanged |
| B8–B9 | Universal workbook adapter; merge the two apply paths | Payroll | B7 | Yes | Parity run |

**Size, inferred.** About 30 PRs.

- **Next 10 weeks:** C1, B1, B2, A1, C2 and S1 can be done in that window, next to the year-end work.
- **February to April 2027:** Employee portal Phase 1 (E1–E4) lands then.
- **Workforce for a second client:** depends on whether a client is waiting.

## 10. Decisions for Leon

1. **Close PR #139** and build the operating profile fresh. Recommended.
2. **SMS provider** (*November 22: not needed for milestone 3; chosen when text notices are built*)**:** neither app sends SMS today (AIRE only has unused ClickSend placeholders), so either choice is new work. Options: ClickSend or Twilio. Recommended: pick whichever has confirmed delivery and pricing to Guam numbers, and use it in both apps.
3. **Clerk:** a separate Pro application for employees, about $25 a month plus per-user and SMS costs. Recommended. *Superseded November 19: one Clerk app for everyone. November 22: Payroll moves to a Clerk production instance (free plan) in milestone 3, and Pro is bought when MFA is switched on.*
4. **Turn on MFA for staff and client users** in production before any employee is invited. Recommended. Today it is off. *Decided November 22: built and tested in milestone 3, switched on at the milestone 4 gate or once the platform earns revenue.*
5. **Bank changes from time apps:** allow them in Phase 2 with a Payroll OTP plus staff verification, or keep them to the Cornerstone portal only at first. Recommended: portal only at first, and time apps after a pilot.
6. **Contact-change approval:** approve automatically after an OTP to the old contact, as in the table above. Recommended, to keep staff work down. The alternative is staff approval for every contact change.
7. **Employee app address,** for example `my.` plus the payroll domain. This is for Leon to choose.

## 11. Questions for Cornerstone

The [portal plan](EMPLOYEE_PORTAL_AND_PLATFORM_PLAN_2026-11-17.md) §8 already has seven questions. Add these two:

8. Which changes should always need Cornerstone's review, whatever the client prefers? Suggested: bank, W-4, SSN, legal name and pay.
9. For a bank change, which verification will staff actually do: a phone call to the number on file, a prenote, or a voided-check upload?

## 12. Risks

- **Effective-dated profile changes** could alter how hours resolve for periods already approved or committed. Mitigation: `effective_on` must fall after the latest committed period, and corrections go through the correction workflow.
- **The profile and `time_tracking_sources` can disagree.** Mitigation: readiness checks and a dual-read agreement spec.
- **Hiding a button is not a gate.** Each `CompanyFeatures` check has to stop the request in the API, not just hide something in the web app. Add a spec for each.
- **AIRE fails silently on drift.** Mitigation: the fixtures and the pinned presenter output, plus a production smoke test after every Payroll deploy that touches `EmployeePay`.
- **A second connected client with payroll history** can't finish onboarding today, because history approval is AIRE-only. This is fixed in C5, before onboarding.
- **Operator capacity.** Year-end comes first. Nothing here is allowed to delay the February 1 filings.
