# Shimizu Technology Platform Security Addendum to Cornerstone's WISP

**Status:** Draft for Dafne to review. Not adopted. It becomes part of Cornerstone's written information security plan (WISP) once Dafne and Leon accept it.
**Date:** November 24, 2026.
**Covers:** Cornerstone Payroll (`payroll.shimizu-technology.com`, its API, background jobs and file storage) and the Milestone 4 employee app.
**Code baseline:** every technical statement was checked against `Shimizu-Technology/cornerstone-payroll` `origin/main` at `01e6aa52` on November 24, 2026, and cites the file it comes from.
**Required by:** Milestone 4 gate G2 ([Milestone 4 plan](../MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md) §3) and the [Milestone 3 plan](../MILESTONE_3_FOUNDATIONS_BUILD_PLAN_2026-11-22.md) §5.2, following IRS Pubs 5708 and 4557 and the FTC Safeguards Rule (16 CFR 314.4), as summarized in the [research brief](../GUAM_PAYROLL_HR_LEGAL_COMPLIANCE_RESEARCH_2026-11-19.md) Q8.

This is a security plan, not legal advice. Whether the Safeguards Rule applies to Shimizu Technology directly is an open question for counsel ([counsel packet](../legal/M4_COUNSEL_REVIEW_PACKET_2026-11-24.md) A3). This addendum follows the Rule's structure either way, because Cornerstone must oversee Shimizu as a service provider (§ 314.4(f)).

**Status words used below:**

- **In place:** true in the code on `origin/main` today, or in production as recorded in the cited document.
- **Built, off:** in the code but not switched on in production.
- **Planned:** in an approved plan, not built yet.
- **Gap:** missing, with no plan yet, or not verified. Every gap is listed with an owner in §12.

---

## 1. Purpose and scope

Cornerstone needs a WISP that names this platform as a covered system (research Q8). We don't know whether Cornerstone's own WISP was finished after its March 2026 staff training on IRS Pubs 4557, 5708, 5709 and 5417 (research Part 5 and Part 4A, item 1). **Dafne to confirm.** If it wasn't, this addendum can't stand alone: Cornerstone's plan also has to cover its own office, staff devices, email and paper records.

This addendum covers the platform that Shimizu Technology builds and runs. It doesn't cover Cornerstone's office systems, client EFTPS or GuamTax logins, or AIRE Services' own app.

---

## 2. Qualified Individuals (16 CFR 314.4(a))

| Organization | Qualified Individual | Responsibility |
|---|---|---|
| Shimizu Technology | **Leon Shimizu** (proposed) | The platform's security program: this addendum, access reviews, change management, vulnerability scanning, incident response for the platform, and an annual written report to Cornerstone. |
| Cornerstone | **[Dafne to confirm]** | Cornerstone's overall WISP, oversight of Shimizu as a service provider, staff training, and decisions on client and employee notices. |

The Rule also asks for an annual written report to the board or a senior officer (§ 314.4(i)). Proposed: Leon reports to Cornerstone's Qualified Individual each year, and after any significant incident. Small-entity relief (§ 314.6) may exempt some of these elements for institutions with fewer than 5,000 consumers, but our research didn't re-read that section [Primary, not re-read]. We write the elements anyway.

---

## 3. Data and system inventory

### 3.1 Data

| Data | Where it lives | Notes |
|---|---|---|
| Employee identity: name, address, phone, email, date of birth | Postgres (`employees`) | Date of birth and address are **not** field-encrypted (`api/db/schema.rb`). |
| SSN | Postgres, encrypted (§4) | Shown as the last 4 digits on stubs (`api/app/services/pay_stub_generator.rb:120`). Full SSNs go into filings that need them, such as the SSA EFW2 file and DRT copies. |
| Bank routing and account numbers | Postgres, encrypted (§4) | MoSa's has none on file (M4 plan §2). |
| Contractor EINs | Postgres, encrypted (§4) | |
| Employer EINs | Postgres (`companies.ein`), not encrypted | A business identifier. |
| Pay, tax, deduction and YTD records | Postgres | |
| Generated documents (checks, stubs, reports, filings) and uploaded files (client documents, payroll imports, QuickBooks history) | Cloudflare R2, private bucket | See §4 on encryption at rest. Files are served by the API or by short-lived signed URLs (default 1 hour, `api/app/services/r2_storage_service.rb:155`). |
| Change requests with sensitive values | Postgres, encrypted payload (§4) | |
| Login accounts | Clerk (credentials and sessions); Postgres `users` (role, company access) | Payroll never sees passwords. |
| Audit log | Postgres (`audit_logs`) | §6.4. |
| Integration secrets for connected time-tracking apps | Postgres, encrypted (§4) | |

**Client bank, EFTPS and GuamTax passwords:** the schema has no column for them (`api/db/schema.rb`, searched November 24). Research Part 5 found that some client logins appear to be exchanged by email. The platform has no technical block on someone pasting a password into a portal message or a staff note, so the rule has to be a policy: never send or store client credentials in the platform (§12, gap G-11).

### 3.2 Systems and sub-processors

| System | What it does | Data it holds | Location |
|---|---|---|---|
| **Render** | API web service and background worker (`KNOWN_PRODUCTION_HOSTS` in `api/lib/staging_outbound_policy.rb`) | Everything, in memory while processing; environment secrets | Singapore |
| **Neon** | Postgres database | Everything in §3.1 apart from files | Singapore |
| **Cloudflare** | DNS, and R2 file storage (`api/config/storage.yml`) | Generated and uploaded files | United States or other countries |
| **Netlify** | Hosts the web app files | No customer data | United States or other countries |
| **Clerk** | Sign-in, invitations, one-time codes, sessions | Names, emails, password hashes, sign-in history | United States or other countries |
| **Resend** | Sends email | Recipient addresses and message content | United States or other countries |
| **Google** | Optional "Sign in with Google"; web fonts | Sign-in identity for users who choose it | United States or other countries |
| **OpenRouter** and its model provider | Optional AI tools for staff (timecard images, pasted payroll emails, invoice drafts) | What staff send to those tools, including employee names and hours | United States or other countries |
| **PostHog** | Product analytics, present but **turned off** | None while off | |
| **GitHub** | Source code and CI. **The repository is public** (checked November 24, 2026). | Code and docs. CI uses synthetic fixtures. The `data/` folder holds two MoSa's 2025 payroll validation reports with aggregate totals (G-18). | |

Locations, PostHog and the OpenRouter uses come from the published privacy policy (`web/src/pages/legal/PrivacyPolicy.tsx`), which was checked against production settings when it was written (commit `501a8fd9`). Whether OpenRouter is switched on in production today isn't recorded in the repository (§12, G-12).

**Other environments that may hold customer data:**

- **Staging:** a restricted rehearsal environment designed to run on a **clone of production data** for named testers, with outbound mail, storage, integration and database containment (`docs/STAGING_ENVIRONMENT.md`; `api/lib/staging_outbound_policy.rb`, `staging_database_policy.rb`, `staging_storage_policy.rb`). Whether a clone exists today, where it's hosted, and who can reach it must be confirmed (§12, G-13).
- **Staging v2:** a local Docker stack for connected AIRE and Payroll testing, with synthetic fixture data and 14-day local backups (`ops/staging-v2/README.md`).
- **Developer machines:** read-only production checks are run by the lead over a controlled connection and output counts only (for example, M4 plan §2). No written rule yet covers what may be copied to a laptop (§12, G-14).

---

## 4. Encryption

### 4.1 In transit

- **In place:** production forces HTTPS (`config.force_ssl` and `assume_ssl`, on unless `FORCE_SSL` is set to something other than true, `api/config/environments/production.rb:27,30`). The production readiness check fails if TLS isn't forced (`api/app/services/production_readiness.rb:118`).

### 4.2 At rest, by field (Active Record Encryption)

**In place.** These fields are encrypted by the application before they reach the database:

| Model and field | Mode | Source |
|---|---|---|
| `Employee#ssn_encrypted` | Deterministic, so a lookup can match it | `api/app/models/employee.rb:144` |
| `Employee#bank_routing_number_encrypted` | Non-deterministic | `api/app/models/employee.rb:145` |
| `Employee#bank_account_number_encrypted` | Non-deterministic | `api/app/models/employee.rb:146` |
| `Employee#contractor_ein` | Deterministic; still reads older unencrypted values | `api/app/models/employee.rb:152` |
| `EmployeeChangeRequest#sensitive_payload_encrypted` | Non-deterministic | `api/app/models/employee_change_request.rb:53` |
| `HistoricalWorker#private_snapshot` | Non-deterministic | `api/app/models/historical_worker.rb:12` |
| `TimeTrackingSource#shared_secret` | Non-deterministic | `api/app/models/time_tracking_source.rb:21` |
| `TimeTrackingDelegation#token` | Non-deterministic | `api/app/models/time_tracking_delegation.rb:8` |
| `UserSession#workos_access_token` | Non-deterministic | `api/app/models/user_session.rb:6` |

Employee invite tokens, finance API tokens and Cable tickets are stored only as digests (`invite_token_digest` and `token_digest` columns in `api/db/schema.rb`). The older `user_invitations` table keeps its token in plain text (`api/app/models/user_invitation.rb`; G-19).

**Keys:** production keys come from encrypted Rails credentials, or from environment variables if credentials are incomplete (`api/lib/active_record_encryption_configuration.rb`). After the August 24, 2026 incident, where two different key sets caused decryption failures, the readiness check now fails if the two sources disagree and if stored data can't be decrypted (`docs/PRODUCTION_ENCRYPTION_INCIDENT_2026-08-24.md`; `production_readiness.rb:137-169`).

**Not field-encrypted:** dates of birth, addresses, phone numbers, emails, pay amounts and employer EINs. They rely on database-level encryption (below), access control and RLS. Whether to encrypt dates of birth, which are half of the employee sign-up check, is open (§12, G-15).

**Logs:** request logs filter SSNs, tokens, codes, emails, uploads and taxpayer IDs (`api/config/initializers/filter_parameter_logging.rb`), and the audit log strips SSNs, bank numbers and secrets from recorded parameters (`api/app/controllers/concerns/auditable.rb:26-30`).

### 4.3 At rest, by provider

Neon (database) and Cloudflare R2 (files) are expected to encrypt stored data at rest, and the published privacy policy says uploaded files are in storage "encrypted at rest". The repository can't prove a provider-side setting. **Gap G-1:** record each provider's at-rest encryption from its own documentation or console.

---

## 5. Risk assessment (16 CFR 314.4(b))

Written November 24, 2026, for the platform and the Milestone 4 employee app. Reviewed at least once a year and before each milestone goes live.

| # | Risk | How it could happen | Controls today | What's left |
|---|---|---|---|---|
| R1 | A staff or client login is taken over | A reused or phished password. Two-step sign-in isn't required yet. | Invitation-only logins bound to the invitation (`api/app/services/payroll_invitation.rb`); Clerk token checks including issuer and authorized party (`api/app/services/clerk_token_verifier.rb`). MFA is **built, off** (§6.2). | Turn on MFA at gate G3, after the M4-1 fix. |
| R2 | One client company sees another's data | A query missing its company filter | App authorization per role and company; RLS policies staged but **not enforced** (§6.3). | Enforce RLS (gate G4, about December 9–11). |
| R3 | One employee sees another's pay | A query not limited to the employee's link, or a header swap | Employees resolve only from their link; 404 on every failure (M4 plan §1.1). Employee endpoints aren't built yet. | M4-11 isolation suite under RLS `raise`. |
| R4 | Someone signs up as an employee they aren't | Knows the person's date of birth and SSN-4 | **Planned:** invite token or one-time code required as well, lockout after 5 failures, staff alerts, generic errors (M4-2). | Build and test M4-2. |
| R5 | A staff member misuses access | Views or changes records without a reason | Role permissions (`api/app/policies/staff_role_policy.rb`); audit of changes and downloads (§6.4). **Planned:** "Sign in as" with step-up, reason, time limit and a log the client sees (M4-9). | Plain views aren't logged (§6.4). |
| R6 | Data is lost or can't be restored | Provider failure, a bad migration, or deletion | Neon and R2 are managed services. | **No verified backup restore** (G-2). |
| R7 | Encryption keys are lost or mismatched | A deploy picks the wrong key set | Readiness checks for agreement and decryption (§4.2). | Key backup and rotation procedure (G-3). |
| R8 | A sub-processor is breached | An incident at Render, Neon, Clerk, Resend, R2 or OpenRouter | Field encryption for the most sensitive values; least data sent to each provider. | Collect each provider's security terms (G-4). |
| R9 | Mail goes to the wrong person | One shared inbox sits on 405 employee records at 5 companies (M4 plan §2). | Real email is off for portal notices unless `PORTAL_EMAIL_NOTIFICATIONS_ENABLED=true` (M4 plan §1.3). | **Planned:** M4-3 guard and cleanup. |
| R10 | Abuse or brute force | Scripted sign-in or sign-up attempts | Rack::Attack throttles (§7.3). | Per-IP limits would stall a shared restaurant Wi-Fi; fix planned in M4-2. |
| R11 | A vulnerable dependency ships | A known advisory in a gem or npm package | CI fails on Brakeman findings, bundler-audit advisories, and npm advisories at moderate or above (§7.2). | No automatic dependency update PRs (G-6). |
| R12 | Malware in an uploaded file | A client uploads an infected PDF | Type, byte and size checks; no virus scanner, accepted for trusted pilot companies (M3 plan §9.1). | Add scanning before wider rollout (G-7). |
| R13 | Copied production data leaks | A staging clone or a local export | Staging containment controls (§3.2). | G-13, G-14. |
| R15 | Internal details are public | The GitHub repository is public, including plans and client reports | Secrets are never committed (§7.4). | G-18. |
| R14 | Client credentials are kept in the platform | Pasted into a message or note | No field for them (§3.1). | Policy and training (G-11). |

---

## 6. Access control and the quarterly access review

### 6.1 Who can get in

- **In place:** logins are invitation-only and bound to the invitation through Clerk metadata and a nonce, never matched by email (`api/app/services/payroll_invitation.rb`; M3 plan §2.3).
- **In place:** staff roles (`super_admin`, `org_admin`, `admin`, `manager`, `accountant`) map to named capabilities (`api/app/policies/staff_role_policy.rb`). For example, viewing the audit history is limited to `super_admin`, `org_admin`, `admin` and `accountant`; revealing a hidden staff note is limited to `super_admin` and `org_admin`.
- **In place:** client users reach only their own companies. Employee-only users (`portal_employee`) are blocked from staff and client routes (`api/spec/requests/employee_role_separation_spec.rb`).
- **Planned (M4-9):** view-only "Sign in as" for a separate permission held by Leon and Dafne, with a fresh two-step check, a reason, a 30-minute limit, a banner, and a log the client's admins can see. Acting for a user (M4-13) comes after wave 1.

### 6.2 Two-step sign-in (MFA)

- **Built, off.** `REQUIRE_MFA` defaults to false (`api/app/services/mfa_policy.rb:11`). When it's on, staff and client users must have a verified second factor in Clerk's `fva` claim. Employee-only logins are exempt by design (`mfa_policy.rb:15`; counsel question B1).
- **Known gap, fix planned:** Clerk's new-device email code sets `fva[1]=0` even when no second factor is enrolled, and the check accepts it (`mfa_policy.rb:18-26`). M4-1 adds a `two_factor_enabled` claim before MFA is switched on.
- **Planned (gate G3):** turn on `REQUIRE_MFA=true` for staff and client users on Clerk Pro, after Clerk production is live and M4-1 is merged. The architecture decision says it goes on at the Milestone 4 gate or once the platform earns revenue, whichever comes first.

### 6.3 Database-level company separation (row-level security)

- **Built, watch-only.** Every table is classified (`api/lib/rls_tables.rb`): 134 protected directly, 10 through a parent, 37 exempt, 19 global. CI checks that every table is classified and that every protected table's policies are staged but **not enabled or forced** (`api/spec/security/company_rls_isolation_spec.rb:14-30`).
- The guard mode is `off`, `log` or `raise`, defaulting to `off` (`api/lib/rls_configuration.rb`). The rollout runs production in `log` for a full pay cycle (`docs/RLS_CALLER_INVENTORY.md`). The production value isn't stored in the repository; the M4 plan records it as watch-only (§1.5).
- **Planned (gate G4):** enforcement in M3-7 phase 3, around December 9–11, 2026. A kill switch for incidents is documented (`docs/RLS_CALLER_INVENTORY.md`).
- Until enforcement, application authorization is the only company boundary.

### 6.4 Audit logging

- **In place:** every successful change, and every download, export, PDF, print or preview, is recorded by the `Auditable` concern on admin and client controllers (`api/app/controllers/concerns/auditable.rb:1-30,113-140`). Each entry has an actor type and name (`api/app/models/audit_log.rb`).
- **In place:** the application treats saved audit entries as read-only (`AuditLog#readonly?`, `audit_log.rb:19-21`).
- **Gap G-8:** that protection is only in the application. The planned runtime database role can update and delete any table, `audit_logs` included (`api/db/rls_runtime_role.sql:6`). There's no database-level append-only rule for `audit_logs`.
- **Gap:** plain views (not downloads) aren't logged (`auditable.rb:113-119`). M4-2 adds view and sign-in logging for the employee app.
- **Known bug, fix planned (M4-2):** `AuditActor.for_user` maps employee logins to `staff_user` (`api/app/models/audit_actor.rb`).

### 6.5 Quarterly access review (procedure)

**Status: Planned.** No access review has been recorded, and there's no tool for it yet. The procedure:

1. **When:** the first week of January, April, July and October, and whenever a staff member leaves.
2. **Who:** Leon runs it; Cornerstone's Qualified Individual signs off.
3. **What to check:**
   - every active Payroll user, with role, company assignments and last sign-in (admin Users page);
   - client users per company, confirmed with each client's admin;
   - who holds the "Sign in as" permission, once it exists;
   - Clerk users with no matching active Payroll user;
   - console access to Render, Neon, Cloudflare, Netlify, Clerk, Resend, OpenRouter and GitHub;
   - who can read production secrets.
4. **Act:** remove or reduce anything not needed, and record the review with date, reviewer, findings and changes.

The list of people with provider console access isn't written down anywhere yet (G-9).

---

## 7. Secure development and change management

### 7.1 How a change reaches production

- **In place:** `main` is protected by the GitHub ruleset "Protect Main": changes go through a pull request; the `backend`, `frontend` and `browser` checks must pass on the latest commit; force pushes and branch deletion are blocked. Checked through the GitHub API on November 24, 2026 (the ruleset lives in GitHub, not in the repository).
- **Gap G-10:** the ruleset requires **0 approving reviews**. Review today is by an automated reviewer (`greptile.json`) and an independent AI review under Shimizu's PR workflow, not a required human approval.
- **In place:** production deploys automatically from `main` (`docs/STAGING_V2_PRODUCTION_RELEASE.md`). New features merge switched off per client until a milestone goes live (architecture decision §6).
- **In place:** the production readiness check verifies TLS, Clerk keys and authorized parties, encryption, R2, Resend, the job worker, migrations and RLS privileges (`api/app/services/production_readiness.rb:116-180`).

### 7.2 CI gates (`.github/workflows/quality.yml`)

Runs on every pull request and on pushes to `main` and `staging-v2`:

- **Backend:** the full RSpec suite in three isolated workers, with a coverage proof that every spec ran; `db:integrity`; RuboCop; the compensation single-write-path lint; a transaction-mode pooler test; **Brakeman**; **bundler-audit** with an updated advisory database.
- **Frontend:** **npm audit gate** (fails at moderate or above, with one reviewed, expiring exception, `web/scripts/audit-gate.mjs`), the Netlify build-ignore test, and `web/scripts/gate.sh`: TypeScript, ESLint with zero warnings, Vitest and a production build.
- **Browser:** Playwright public, release, payroll-refresh and pay-item lanes on synthetic fixtures.
- **Staging config:** staging v2 Compose, isolation checks and image builds.

`.github/workflows/connected-payroll.yml` certifies exact AIRE and Payroll commit pairs for `staging-v2`.

### 7.3 Abuse protection (Rack::Attack)

- **In place:** enabled outside tests (`api/config/initializers/rack_attack.rb:5`). Limits include 300 API requests a minute per IP, 20 auth requests a minute, 30 a minute for tenant branding, and employee limits for activation, PDFs and general requests (`:23-118`). Counters use shared Redis when `RACK_ATTACK_REDIS_URL` is set, and otherwise per-process memory (`api/config/initializers/early_rack_attack_store.rb`). The readiness check requires a shared store when the web service is split (`production_readiness.rb:125`).
- **Planned (M4-2):** session- or link-keyed limits so one restaurant Wi-Fi doesn't lock out a shift, and tenant CORS headers on throttled responses.

### 7.4 Secrets

- **In place:** production secrets are supplied through the hosting provider's environment or encrypted Rails credentials, never committed (`docs/STAGING_ENVIRONMENT.md`; `api/lib/active_record_encryption_configuration.rb`).
- **Gap:** no secret-scanning setting is recorded in the repository. Confirm GitHub secret scanning and push protection are on (part of G-6).

---

## 8. Retention and disposal

- **Retention default:** payroll and wage records are kept at least **6 years**, the Guam DOL handbook's period. Counsel is asking which regulation sets it (research Q5; packet A2). Employment tax records are kept at least 4 years under IRS rules (research Q5).
- **Today:** the platform keeps records for as long as a client uses the service, and doesn't delete payroll records automatically. The published privacy policy says so (`web/src/pages/legal/PrivacyPolicy.tsx`, "How long we keep it"). The only automated cleanup removes abandoned portal uploads (`api/app/jobs/portal_upload_cleanup_job.rb`).
- **The Safeguards Rule's disposal rule:** dispose of customer information within 2 years of its last use unless it's needed or retention is required (§ 314.4(c)(6), research Q8). Payroll records fall under the retention rules, so the 2-year rule mostly applies to data outside them.
- **Planned:** employee-app copies (stubs, W-2GUs) stay available to the employee for the retention period, W-2GUs at least through October 15 of the following year (M4-5), and former employees keep read-only access until `former_access_until` (M4-2).
- **Gap G-5:** no written disposal schedule by record type, no deletion tooling, and no legal-hold tool. Audit logs are kept unchanged.

---

## 9. Vulnerability scanning and penetration testing

- **In place, on every change:** static and dependency scanning in CI (Brakeman, bundler-audit, npm audit; §7.2).
- **Planned, every 6 months:** an automated scan of the running production site and API. The first is the OWASP ZAP baseline scan in M4-11, run against a local build and then against the production employee site and API before anyone is invited. Results go into this plan.
- **Planned (M4-11):** an isolation suite for every employee endpoint under RLS `raise` with real authentication, and an adversarial review of the employee surface and "Sign in as" by a different AI model family.
- **Planned:** a full penetration test by an outside tester **before onboarding clients outside Cornerstone's current book** (M3 plan §5.2). The Safeguards Rule calls for annual penetration testing plus scans every 6 months, unless there's continuous monitoring (§ 314.4(d), research Q8).
- **Gap G-7:** no outside penetration test has been done, and none is booked.

---

## 10. Incident response and breach notification plan

**Status:** written here; not yet exercised. Who sends notices to employees depends on counsel's answer to packet question A5.

### 10.1 Roles

- **Incident lead:** Leon (Shimizu's Qualified Individual).
- **Cornerstone contact:** Cornerstone's Qualified Individual [Dafne to confirm], who decides client and employee notices with counsel.
- **Counsel:** [Firm], once engaged.

### 10.2 Steps

1. **Detect and record.** Any suspected incident (an alert, a provider notice, a client report, an odd audit entry) is written down with the time it was found. That time starts the notice clocks.
2. **Contain.** Revoke sessions or logins, rotate exposed secrets, switch off the affected feature for the affected client (features are per client, architecture decision §6), or use the RLS kill switch if company separation is involved (`docs/RLS_CALLER_INVENTORY.md`).
3. **Assess.** Which companies, which people, which data, whether it was encrypted and whether the key was exposed, and whether data was acquired and not just accessed. The audit log and provider logs are the evidence. Read-only checks output counts, not personal data.
4. **Tell Cornerstone and the affected client employers as soon as practicable.** Guam law requires an entity that maintains data it doesn't own to notify the owner "as soon as practicable following discovery" (9 GCA § 48.30(c), research Q8). Proposed internal target: within 24 hours of confirming the incident (Leon and Dafne to decide). The client agreement may set a fixed time, such as 72 hours (packet §6.1).
5. **Notices to people** (decided by the data owner, with counsel):
   - **Guam:** the owner or licensee notifies affected Guam residents "without unreasonable delay" (§ 48.30(a)), allowing a delay for law enforcement (§ 48.30(d)). Personal information covers a name with an unencrypted, unredacted SSN, driver's license or Guam ID number, or financial account number with its code. Encrypted data counts if the key was also compromised (§ 48.30(b)).
   - **FTC:** for unauthorized acquisition of unencrypted customer information of **500 or more consumers**, notice to the FTC as soon as possible and no later than **30 days** after discovery, through its online form (16 CFR 314.4(j)). Whether the Rule applies to this data at all is packet question A3.
   - Guam law requires no regulator notice (research Q8).
6. **Recover.** Fix the cause, restore data if needed (see G-2), and confirm with tests and the readiness check.
7. **Review.** Within two weeks (proposed), write up what happened, the timeline, the notices sent, and the changes made, like `docs/PRODUCTION_ENCRYPTION_INCIDENT_2026-08-24.md`. Update the risk assessment.

### 10.3 Records

Keep the incident record, the evidence (counts and identifiers only), the notices and their dates for at least as long as the payroll records involved.

**Gap G-16:** no incident exercise (tabletop) has been run. `docs/OPERATOR_AND_RECOVERY_ACCEPTANCE.md` lists one as unchecked.

---

## 11. Training and oversight

- Cornerstone's staff training on IRS Pubs 4557, 5708, 5709 and 5417 was scheduled in March 2026 (research Part 5). **Dafne to confirm** it happened and when it repeats.
- Shimizu's own security training is **a gap** (part of G-11).
- Cornerstone oversees Shimizu as a service provider through the Client Service Agreement and DPA (§ 314.4(f); packet §6.1), this addendum, and the annual report (§2).

---

## 12. Gaps and owners

| # | Gap | Owner | When |
|---|---|---|---|
| G-1 | Record each provider's at-rest encryption (Neon, R2) from its own documentation or console. | Leon | Before G2 sign-off |
| G-2 | **Backups and restore aren't verified.** No production restore test or Neon point-in-time restore is recorded; the evidence docs list it as unassigned (`docs/PRODUCTION_READINESS_EVIDENCE_2026-08-24.md:82`, `docs/PRODUCTION_READINESS_EVIDENCE_2026-08-23.md:29`). Record Neon's backup and restore settings, then run and time a restore into an isolated database. Also R2 versioning or recovery (`PRODUCTION_READINESS_EVIDENCE_2026-08-24.md:84`). | Leon | Before employees go live |
| G-3 | Written key procedure: where encryption keys and the credentials key are backed up, who can reach them, and how to rotate. | Leon | Before G2 sign-off |
| G-4 | Collect each sub-processor's security terms and DPA (Render, Neon, Cloudflare, Netlify, Clerk, Resend, Google, OpenRouter). | Leon | Before G2 sign-off |
| G-5 | Disposal schedule by record type, deletion tooling, and a legal hold. Depends on counsel's retention answer (packet A2). | Leon, with counsel's answer | Before onboarding clients outside Cornerstone's current book |
| G-6 | Turn on automatic dependency update PRs, and confirm GitHub secret scanning and push protection. | Leon | Before employees go live |
| G-7 | Outside penetration test; malware scanning for uploads before wider rollout. | Leon | Before onboarding clients outside Cornerstone's current book |
| G-8 | Make `audit_logs` append-only in the database for the runtime role. | Leon | With RLS enforcement (M3-7 phase 3) or soon after |
| G-9 | Write down who has console access to each provider and to production secrets; run the first quarterly access review (§6.5). | Leon; sign-off by Cornerstone's Qualified Individual | First review in January 2027 |
| G-10 | Required human approval on pull requests, or a written reason why one developer plus automated and AI review is acceptable for now. | Leon and Dafne decide | Before G2 sign-off |
| G-11 | Policy and training: no client passwords in the platform; Shimizu security training. | Dafne (Cornerstone staff), Leon (Shimizu) | Before employees go live |
| G-12 | Record whether OpenRouter is switched on in production, and decide whether employee-app data may ever reach it. | Leon | Before G2 sign-off |
| G-13 | Confirm whether a staging clone of production data exists, where it's hosted, who can reach it, and when it's destroyed. | Leon | Before G2 sign-off |
| G-14 | A rule for production data on developer machines and in exports. | Leon | Before G2 sign-off |
| G-15 | Decide whether to field-encrypt dates of birth, which are half of the employee sign-up check. | Leon | Before M4-2 merges |
| G-16 | Run an incident tabletop exercise. | Leon and Dafne | Before employees go live |
| G-17 | Confirm Cornerstone's own WISP status and name Cornerstone's Qualified Individual (§1, §2). | Dafne | Before G2 sign-off |
| G-18 | The repository is public. Decide whether client payroll reports (`data/`) and internal plans, including this addendum's gap list, should stay in it, or move the repository to private. | Leon | Before G2 sign-off |
| G-19 | Store `user_invitations` tokens as digests, or retire the table if it's no longer used. | Leon | Before employees go live |

**Planned controls, tracked in the Milestone 4 plan and not repeated here as gaps:** MFA on (M4-1, G3), RLS enforced (G4), employee sign-up protections (M4-2), the shared-inbox guard and cleanup (M4-3), "Sign in as" (M4-9), Wi-Fi-friendly rate limits (M4-2), employee view logging and the audit actor fix (M4-2), PostHog removed from the employee build (M4-8), and the M4-11 security checks.
