# Milestone 4 ("Employee app, MoSa's first") build plan

**Status:** Approved by Leon on November 24, 2026, after two rounds of independent cross-family review (Gemini 4 Neon) and Leon's answers, then a third review of the answer-round changes, whose findings are fixed here (§0, §9). No application code has changed.
**Date:** November 24, 2026.
**Codebase baseline:** `Shimizu-Technology/cornerstone-payroll` `origin/main` at `01e6aa52` (includes #545, the Clerk Core 3 upgrade).
**Builds on:** [Product architecture decision](PRODUCT_ARCHITECTURE_DECISION_2026-11-19.md) (§0, §4, §6), [Milestone 3 build plan](MILESTONE_3_FOUNDATIONS_BUILD_PLAN_2026-11-22.md) (§5 legal and WISP, §7 costs), [Employee portal plan](EMPLOYEE_PORTAL_AND_PLATFORM_PLAN_2026-11-17.md) (§3 identity, §4 Phase 1), [Guam legal compliance research](GUAM_PAYROLL_HR_LEGAL_COMPLIANCE_RESEARCH_2026-11-19.md) (Part 1 items 1–3, 21, 23; Q1; Q7; Part 3), and [Client subdomain activation](CLIENT_SUBDOMAIN_ACTIVATION.md).

## Summary

Milestone 4 gives MoSa's employees a phone-friendly app where they sign in and see their own pay. It shows each paycheck, the same PDF stub Cornerstone prints, their pay history, a copy of their 2026 W-2GU, and their contact details. They can update their phone, personal email and emergency contacts themselves after confirming with a code, and ask for a home-address change, which MoSa's admins approve and Cornerstone then confirms on the payroll side (§0 D4).

There's no staging round for this milestone (Leon, November 24, 2026). Agents test locally, in CI and on the Clerk test app. In production, with the app on for MoSa's but nobody invited, Leon and Dafne use a view-only "Sign in as" to see exactly what any employee or MoSa's admin sees, The Cornerstone team does real sign-ups of its own on company 1 records, and Mark and Benjo run the written script. Then Elena Mercer, who leads MoSa's day to day and is on its payroll, becomes the first real user. She gets a client portal login and her own employee access, and tests every flow. Emma, Sara and Mo then enter their employees' own emails and phone numbers and send the invites. After that it opens in waves: about 5 employees, one full pay period, then everyone.

Three findings shape this plan more than the code does:

1. **We can't reach MoSa's employees yet.** Production has no real employee email and no phone number for any of MoSa's 61 active employees (§2). Most records carry one shared inbox that was entered by mistake. MoSa's admins will enter their employees' own details (D1), so the client portal needs an easy way to set and update them, and the shared inbox has to be cleaned up (M4-3).
2. **MoSa's has no client logins yet.** There are zero client users for company 6, so Emma, Sara and Mo have to be invited to the client portal before they can act as employee-app admins.
3. **The longest wait isn't code.** The lawyer review and the written security plan (WISP) must be finished before employees go live (architecture decision §6). They should start now and run alongside the build.

Bank changes stay **off** for MoSa's in this milestone. Payroll holds no bank details for MoSa's, because MoSa's pays through its own bank's ACH (§2), and the lawyer hasn't yet answered the direct deposit question.

**Cost at the gate:** $32 a month (Clerk Pro $25 + Render Starter employee web $7), or $27 with Clerk billed annually. That's unchanged from the M3 plan §7, plus the one-time law-firm fee.

### What milestone 4 deliberately does not do

- **No documents or policy sign-offs.** They move to Milestone 5 with onboarding (§0 D2). The code catalog already puts `employee_portal.features.documents` and `w4_requests` in Milestone 5 (`api/app/services/operating_profile_catalog.rb:73,76`).
- **No bank changes** (§0 D3). The switch stays locked for every client. Building the bank-change flow waits until a client needs it, an SMS provider is chosen and counsel answers the direct deposit question, no earlier than Milestone 5.
- **No electronic-only delivery.** Employees keep getting stubs and W-2s the way they do today, and the app is an extra copy. Electronic-only delivery waits for the lawyer's answer on Guam UETA consent and starts with the 2027 W-2s (§0 D5).
- **No 1099 copies in the app.** MoSa's has no contractors (§2). The 1099 recipient copy can be added when a client with contractors joins.
- **No text messages.** Codes come from Clerk by email. No SMS provider is chosen (M3 plan, "No SMS provider").
- **No languages other than English** for the pilot (§0 D8).
- **No acting for another user at launch.** "Sign in as" is view-only for the pilot. The full version, where Cornerstone support can act for a user, is planned in M4-13 and comes after wave 1.
- **No changes to AIRE's My Pay contract.** AIRE's routes, payloads and audit strings stay byte-for-byte the same (§4 M4-4).
- **No change to Year-End (Milestone 1) work.** The filing deadlines (DRT by January 29, SSA and employee copies by February 1, 2027) keep priority whenever schedules compete.

---

## 0. Decisions

### Recorded (Leon, November 24, 2026)

| Topic | Decision |
|---|---|
| **Pilot client** | MoSa's (company 6) first. |
| **Check before employees** | Leon, Dafne, Mark and Benjo check it before Emma or any other MoSa's employee gets access. There's no staging round for this milestone (D10). |
| **First real user** | Elena Mercer, who leads MoSa's day to day and is on its payroll (§2). She is both a MoSa's admin and an employee, on one login with a role switcher (architecture decision §0, "Logins"). |
| **Documents and policy sign-offs** | Milestone 5, with onboarding. Electronic-delivery consent for stubs and W-2s stays in Milestone 4. |
| **2026 W-2GUs** | Paper as required, plus a copy posted in the app. Electronic-only delivery starts with the 2027 forms, after consent. |
| **Employee contact details** | Most MoSa's employees have a phone and a personal email. The shared inbox on employee records is a mistake to fix. Every employee gets their own email, and email, phone and address must be easy to set and update (M4-3). |
| **Contact changes** | D4 below. |
| **Earlier 2026 pay** | Cornerstone has the original QuickBooks stub PDFs (D6). |
| **Languages** | English only (D8). |
| **Employees' sign-in** | Password, Google, or an emailed code from Clerk. No authenticator app (D9). |
| **Sign in as** | View-only for the pilot, then plan the full version properly (D10, M4-13). |

### Decisions and recommendations

| # | Question | Decision or recommendation | Why |
|---|---|---|---|
| D1 | How do employees' emails and phones get in? | **Decided.** MoSa's admins enter and maintain their employees' emails, mobile numbers and addresses in the client portal, and send the invites (M4-3, M4-9). Emma goes first as the demo: her details are entered, she signs up, and she tests every flow before anyone else is invited. Cornerstone enters details only when MoSa's asks. Anyone without an email gets a printed one-time sign-up code and enters their own email. | It gets MoSa's into the system early, and keeps contact details with the people who know them. Client users can already edit an employee's email, phone and address directly (`api/app/services/client_employee_update_service.rb:5-21`). A wrong email can't let the wrong person in, because sign-up also checks DOB and SSN last 4. |
| D2 | Documents and policy sign-offs | **Decided.** Milestone 5. The architecture decision's milestone table is updated in this PR. | They need MoSa's actual policies, which nobody has given us yet, plus the lawyer's view on electronic signatures. Milestone 5's onboarding uses the same parts. |
| D3 | Bank changes for MoSa's | **Recommended: off.** The app shows "Direct deposit" or "Paper check" read-only, with a "Contact MoSa's to change" note. | Payroll holds no bank details for MoSa's (0 of 48 direct-deposit employees, §2). The lawyer's direct deposit question (Part 3 Q1) is open. The catalog's `bank_requests` switch also depends on an `sms_provider` setting that doesn't exist (`operating_profile_catalog.rb:384-396`), so it can't be turned on as written. |
| D4 | How do employees' own changes get applied? | **Decided.** Mobile phone, personal email and emergency contacts apply right away after a fresh one-time code (Leon, November 19, confirmed November 24). **Home address: MoSa's admins approve**, and the change applies on approval. Nobody approves a request about their own record: when the employee is also a MoSa's admin, like Emma, another MoSa's admin or Cornerstone approves. **Cornerstone sees every applied change** in a "Changes to confirm" list and marks each one confirmed on the payroll side. A payroll run warns about unconfirmed changes but isn't blocked. Legal name, SSN and W-4 stay with Cornerstone. | MoSa's knows its people and can already change addresses directly today. The confirm list keeps Cornerstone responsible for payroll accuracy without making it a bottleneck. Today change requests are approved only by staff with `manage_client_configuration` (`api/app/models/employee_change_request.rb:129-137`), so M4-7 adds a client approval path. |
| D5 | Paper during the pilot | **Recommended.** Nothing changes in how MoSa's employees get stubs today. The app adds a copy. Electronic-only delivery is a later switch, once counsel approves the consent wording. | Guam UETA requires a recorded agreement and a paper option (research Q1). Until counsel answers Part 3 Q2, the app can't replace paper. |
| D6 | Pay before September 10, 2026 | **Decided: show it.** Cornerstone has the original QuickBooks stub PDFs. They're uploaded, matched to each employee and check with a staff review (never guessed), and posted as "Original QuickBooks stub". The Pay list shows those checks from the QuickBooks data Payroll already imported. Before anything posts: confirm the PDFs don't print a full SSN, and that the imported rows group into one entry per check (M4-4). | Employees see the whole year in one place, and the originals are exactly what they received. The imported rows carry earnings, tax and deduction breakdowns (`api/db/schema.rb:2050-2102`). Emma's record has 59 imported rows for January–August, more than a biweekly schedule produces, so the per-check grouping has to be confirmed first. |
| D7 | Save the stub as issued | **Recommended.** Post each stub to the app at a defined moment and freeze it then, with a fingerprint (M4-4 defines the moment). Corrections become a separate "Corrected" document. Today the staff download serves an archived R2 copy only in narrow cases and otherwise regenerates (`api/app/controllers/api/v1/admin/pay_stubs_controller.rb:64-79`). AIRE always regenerates (`api/app/controllers/api/v1/integrations/aire/worker_statements_controller.rb:43-52`). | Regenerating can change the "Generated on" time, the check number or payment line, and, after reversals, the YTD figures. An employee's earlier download should match what the app shows later. |
| D8 | Languages | **Decided.** English only. | No translation setup exists in `web/`, and there's no known need. |
| D9 | Employees' second sign-in step | **Decided.** Employee-only logins don't need an authenticator app. They sign in with a password, Google, or an emailed code from Clerk, and Clerk emails a code on each new device. Before any change, they confirm again with a fresh first-step verification (Clerk reverification at the first-factor level, `fva[0]` within 10 minutes). Employees who chose to enroll a second factor confirm with that instead. Staff and client users, including Emma, Sara and Mo, require two-step sign-in. | This matches the M3 plan: employee-only users "pass the global MFA gate… relying on step-up" (M3 plan, M3-2). Most restaurant workers won't set up an authenticator app. The lawyer review asks whether the FTC Safeguards Rule's MFA requirement covers employees viewing their own records (§3 G1). |
| D10 | How is it tested with real data? | **Decided:** (a) **no staging** for this milestone; agents test locally, in CI and on the Clerk test app; (b) **view-only "Sign in as"** in production (M4-9): Leon and Dafne see exactly what a given employee or client user sees, with that person's permissions, before and after they sign up; (c) before Emma, **the Cornerstone team does real sign-ups itself** on Cornerstone (company 1) employee records, so any sign-up problem is found by us and not by the client (Leon: "we'll test it first before Emma is in there"). That covers both paths: a staff member claiming employee access with an existing login, such as Benjo, and one brand-new employee-only sign-up with a second email, which is revoked afterward; (d) **Emma is the first real user** (D1). The **full "Sign in as"**, acting for a user, is planned properly in M4-13. | Test workspaces can't turn the employee app on (`api/app/services/company_features.rb:104-108`), and links must belong to a live company, which the database enforces (`api/db/migrate/20261122060000_add_payroll_invitation_binding_and_employee_account_links.rb:30`). View-only creates no new exposure, because staff with access to MoSa's already see this data. Acting for someone does, and some actions are the person's own legal acts, so the full version gets its own design. |
| D11 | Tell employees when a new stub posts? | **Recommended: yes, by email.** It says "Your pay stub for <date> is ready" with no amounts and a link to the app. It goes only to the verified personal email, only when the company's `stubs` switch is on, and only while `PORTAL_EMAIL_NOTIFICATIONS_ENABLED` is on. | The portal plan lists it (`EMPLOYEE_PORTAL_AND_PLATFORM_PLAN_2026-11-17.md`, Phase 1), and it's the main reason people open the app. Generic emails with no amounts follow the existing pattern (`api/app/services/portal_notifications/email.rb:6`). |
| D12 | What happens to an open session when access ends? | **Recommended.** Revoking or retiring a link ends access on the next request, because the link check runs on every call. When it was the person's last eligible link, the `portal_employee` login is also deactivated, which blocks every API call at once (`api/app/controllers/api/v1/employee_portal/base_controller.rb:31`). Their Clerk sessions are ended through Clerk's Backend API. The existing `PayrollAccess::RevocationDispatcher` only drops live Cable connections (`api/app/services/payroll_access/session_revoker.rb:10`), and the employee service has none. Former employees keep read-only access until `former_access_until`. | A stolen or shared login shouldn't keep working after Cornerstone revokes it. |

---

## 1. Where things stand

Every claim below was checked against `origin/main` (`01e6aa52`) on November 24, 2026. Milestone 3 left most of the groundwork in place, switched off. Nothing yet serves pay data to an employee.

### 1.1 Employee identity

- **Built:**
  - **`EmployeeAccountLink`** (`api/app/models/employee_account_link.rb`) has statuses invited/active/former/revoked, `invite_token_digest`, `invite_expires_at`, `former_access_until`, and revoke fields. The schema allows one open link per employee (`api/db/schema.rb:893-919`). The table is covered by row-level security (`api/lib/rls_tables.rb`). `portal_eligible` and `portal_enabled?` gate access (`employee_account_link.rb:17-23`).
  - **`Api::V1::EmployeePortal::BaseController`** resolves the employee from the signed-in user plus the `X-Employee-Link-Id` header. It never uses the URL. It scopes RLS to the link's company, binds a subdomain token to that company, and returns 404 for every failure (`api/app/controllers/api/v1/employee_portal/base_controller.rb:9-47`). The only endpoint is `GET /api/v1/employee/context`, which returns 204 (`api/config/routes.rb:64-66`).
  - **The `portal_employee` role** (`api/app/models/user.rb:39`). Employee-only users are blocked from staff and client routes (`api/spec/requests/employee_role_separation_spec.rb`).
  - **Invitation binding** through Clerk invitation metadata plus a nonce (`api/app/services/payroll_invitation.rb:29-98`).
  - **`/auth/me`** returns `roles: { staff, client, employee_links_count }` (`api/app/controllers/api/v1/auth_controller.rb:31-35`).
- **Missing:**
  - Anything that creates, accepts, resends, revokes, expires or retires a link. `invite_token_digest` and the `former_access_years` setting are unused.
  - The sign-up check (DOB + SSN last 4, or a one-time code).
  - Creating `portal_employee` users. The admin user controller only allows staff and client roles (`api/app/controllers/api/v1/admin/users_controller.rb:467-470`).
  - Moving links to *former* on termination. The two services that change an existing employee's status don't touch links (`api/app/services/employee_status_transition_service.rb:41-125`, `api/app/services/employee_classification_transition_service.rb:30`). Two other paths create new inactive records (`client_employee_update_service.rb:97`, `year_end/one_off_payee_resolver.rb:182`). M4-2 also confirms no other controller writes `status` directly.
  - Employee invite emails (today's invite always redirects to `/login`, `api/app/services/user_invite_email_service.rb:71-135`).
- **Bugs to fix:**
  - `AuditActor.for_user` maps `portal_employee` to `staff_user` (`api/app/models/audit_actor.rb:6-11`).
  - The employee base controller uses `ActionController::API` without `Auditable` and never sets `Current.actor` (`base_controller.rb:6`). Adding `Auditable` also needs `current_company_id` and `Current.user`, which it relies on (`api/app/controllers/concerns/auditable.rb:93,124`).
  - The SPA can't find its links. Every employee endpoint needs `X-Employee-Link-Id`, but `/auth/me` returns only `employee_links_count` (`auth_controller.rb:34`), so nothing returns link IDs or employer names.

### 1.2 Two-step sign-in

- `MfaPolicy.verified_second_factor?` accepts any `fva[1] >= 0` (`api/app/services/mfa_policy.rb:18-26`). **Known gap:** Clerk's new-device email code sets `fva[1]=0` even when no second factor is enrolled. Fix it before `REQUIRE_MFA=true` (M4-1).
- `required_for?` exempts `employee` and `portal_employee` (`mfa_policy.rb:15`). That matches D9.
- `recently_verified?` (step-up within 10 minutes) exists but has no callers (`mfa_policy.rb:28-32`).

### 1.3 Pay and tax documents

- **Pay stubs: built.**
  - `PayStubGenerator.new(payroll_item).generate` returns the stub PDF with the SSN reduced to the last 4 (`api/app/services/pay_stub_generator.rb:28,36,120`). `#statement` returns the same rows as data (`:79-87`).
  - `EarningsStatementEligibility.printable?` decides what can be printed.
  - A stub is final when its pay period is `reportable_committed` (`api/app/models/pay_period.rb:331`). Voids, reversals, corrective checks and replacements can change it afterward (`pay_period_correction_service.rb`, `reverse_paycheck_service.rb`, `issue_corrective_paycheck_service.rb`).
- **AIRE worker statements: built, and the best template.** The list, detail and PDF endpoints, with voided history kept, payment status, rate limits, and the `worker_statements#listed` / `worker_statement#viewed` / `worker_statement#pdf_downloaded` audit strings (`api/app/controllers/api/v1/integrations/aire/worker_statements_controller.rb:23-227`). The query and presenters should move into a shared service that both AIRE and the employee app call, without changing AIRE's output.
- **W-2GU copies: built for staff.** `W2GuOfficialCopies` prints Copy B and C for employees, with the SSN truncated (`api/app/services/w2_gu_official_copies.rb:7-10,312-320`). It's final only when the company's W-2 readiness record is current (`api/app/models/w2_filing_readiness.rb:20-22`) and the annual filing-responsibility gate allows it (`w2_gu_official_copies.rb:88-92`). It runs for a whole report, not one person, and only for tax year 2026 (`:32,153-165`). The staff download re-checks and audits (`api/app/controllers/api/v1/admin/reports_controller.rb:4809-4870`). Corrected forms (W-2c) don't exist yet.
- **Electronic-delivery consent: missing.** There's no table, model or disclosure versioning.
- **Notifications: partial.** `PortalNotifications` knows only the `staff` and `client` audiences (`api/app/services/portal_notifications.rb:16-64`). Real email stays off unless `PORTAL_EMAIL_NOTIFICATIONS_ENABLED=true`. When it's off, rows are saved as `skipped` (`:67-69`).

### 1.4 Change requests, admins and audit

- **Change requests: built, client-to-staff only.** `EmployeeChangeRequest` has pending/approved/rejected statuses, one pending request per employee, a stale-value check, encrypted SSN/EIN payloads, and staff approval with `manage_client_configuration` (`api/app/models/employee_change_request.rb:5-215`). `requested_by` must be a `User`. Client contact and address edits apply directly without review (`api/app/services/client_employee_update_service.rb:5-21`). Each client user sees only their own requests.
- **Client roles: partial.** There's one `client` role and no client-admin tier. Clients can list, view, create and update employees, but can't invite or terminate them.
- **Operating profile switches: built, M4 entries locked off** (`operating_profile_catalog.rb:68-80`, enforced at `api/app/services/client_operating_profiles/update_service.rb:81-83`). `review_first?` and `employee_portal_feature?` have no callers (`api/app/services/company_features.rb:86,111-119`).
- **Audit actors:** `employee`, `kiosk` and `system_job` types exist (`audit_actor.rb:4`). Downloads are logged by `Auditable`. Plain views are not (`api/app/controllers/concerns/auditable.rb:115-138`).
- **Data quality:** no employee-email validation, no uniqueness check, and no detection of shared or placeholder addresses (`api/app/models/employee.rb`). Login emails are unique system-wide (`user.rb:41`).

### 1.5 Platform and web

- **Employee web build: scaffold.** `VITE_APP_SURFACE=employee` builds a separate bundle with no staff code (`web/vite.config.ts:10-49`, proven in `web/src/lib/appSurfaceBuild.test.ts:24-45`). Today it's a "coming soon" placeholder with no router, no Clerk and no API client (`web/src/EmployeeApp.tsx`). There's no employee manifest, safe-area handling or translations.
- **Subdomains: built.** The tenant branding endpoint, the registry, dynamic CORS for `/api/v1/(auth|employee)/`, and the `azp` check (`api/app/controllers/api/v1/public/tenant_branding_controller.rb`, `api/app/services/tenant_subdomain_registry.rb`, `api/config/initializers/cors.rb:18-49`, `api/app/services/clerk_token_verifier.rb:236-275`). Company 6 has no `subdomain_slug` yet (§2). The activation steps are in `docs/CLIENT_SUBDOMAIN_ACTIVATION.md`.
- **Process roles: built.** `APP_PROCESS_ROLE` = `all | payroll_web | employee_web` (`api/lib/process_role.rb:4-7`). `employee_web` drops payroll routes and Cable (`api/config/routes.rb:2-6`). Pool sizes come from env only (`api/config/database.yml:13-24`). The employee Render service doesn't exist yet.
- **Rate limits: built, but sized per IP, which won't work for a restaurant.** MoSa's employees on one shared Wi-Fi all count as one IP against every one of these:
  - `auth/ip`: 20 a minute, including `/api/v1/auth/me` (`api/config/initializers/rack_attack.rb:28-30`)
  - `tenant_branding/ip`: 30 a minute for every client-origin auth or employee request (`:32-39`)
  - `employee/activation_ip`: 10 per 15 minutes (`:107-109`), which would stall a shift signing up together
  - `employee/pdf`: 15 a minute (`:115-118`), which would stall payday downloads
  - `employee/ip`: 120 a minute (`:103-105`)
- **More rate-limit gaps:**
  - The activation body check rejects any request without a `token` (`rack_attack.rb:66-101`), so code-only sign-up would be refused.
  - A throttled (429) or rejected (400) response adds CORS headers only for static origins (`json_response_headers`, `:124-134`). On `mosas.shimizu-technology.com` the browser would see an unreadable CORS error instead of "try again".
  - There's no per-employee attempt counter or lockout for a DOB + SSN check.
- **Row-level security:** employee tables, payroll items, pay periods, W-2 readiness and YTD totals are covered (`api/lib/rls_tables.rb:7-48`). Enforcement is still in "watch only" mode. It turns on in M3-7 phase 3 (around December 9–11).
- **Tests:** API specs cover role separation, subdomains, RLS isolation, rate limits and MFA. Playwright runs Desktop Chrome only. There's no mobile device project and no employee-surface server (`web/playwright.config.ts:30-54`).
- **Staging can't run the internal test as it stands.** Staging allows only 1–2 bound testers (`api/lib/staging_outbound_policy.rb:74`), rejects a Clerk user who isn't already bound (`api/app/controllers/concerns/clerk_authenticatable.rb:41-49`), allows only one frontend origin, and reserves the `staging` subdomain (`api/app/services/tenant_subdomain_registry.rb:4-9`). This milestone doesn't use staging (D10a), so it stays as it is.
- **Analytics:** the employee build mounts PostHog today (`web/src/employee-main.tsx:4,11`).

---

## 2. MoSa's production data (read-only, November 24, 2026)

These counts come from production (revision `455eef28`), run inside one `REPEATABLE READ READ ONLY` transaction. The output was counts only, with no names or contact details.

| | Result |
|---|---|
| Active employees | **61**: 59 hourly, 2 salary, 0 contractors |
| DOB and SSN on file | **61 of 61**, so every active employee can pass the sign-up check |
| Full mailing address | 53 of 61 |
| Email | 46 on file, **2 distinct addresses**. 45 are one shared inbox, entered by mistake (Leon). The other belongs to a staff user (Dafne). 15 have none. |
| Phone | **0** |
| Payment method | 48 direct deposit, 13 paper check. **0 bank accounts on file.** |
| Inactive employees | 56, none with a termination date, none paid through Payroll in 2026 |
| Payroll-run pay periods in 2026 | 6 committed, from September 10 to November 19 |
| Imported 2026 history | 855 QuickBooks paychecks (January 1 – August 27) for 72 employees (58 now active, 14 inactive) |
| Client users for company 6 | **0** |
| Employee-app links or portal users anywhere | 0 |
| Shared inbox across all companies (second check, same day) | One address on **405 employee records at 5 companies** (221 active). A second address is shared by 5 more. Neither is anyone's login email. |
| Elena Mercer | One active, hourly, biweekly record with DOB and SSN on file. 6 Payroll-run checks in 2026, 59 imported QuickBooks rows. Her email on file is the shared inbox, and there's no phone. |

**What this means:**

- Invites can't use the email on file. MoSa's admins enter real addresses, the shared inbox is cleared (M4-3), and the invite tool refuses a shared address, a placeholder, or a staff user's address.
- The 14 inactive employees paid in early 2026 get paper W-2s, as today. In the pilot, only active employees get invites.
- The 56 inactive employees with no termination date can't start a "former employee" window. That's harmless while only active employees are invited. A cleanup report for Cornerstone is in M4-9.

---

## 3. Gates before the first MoSa's employee signs in

All of these must be true. Each one maps to a check in the go-live runbook (M4-12).

| # | Gate | Owner | Notes |
|---|---|---|---|
| G1 | **Lawyer review** of the "needed before launch" questions that apply to this app: electronic pay stubs (Part 3 Q2), the Safeguards Rule (Q5, including whether MFA covers employees viewing their own records), IRC § 7216 (Q6), breach notice (Q7). Plus counsel-drafted **Employee App Terms and Privacy Notice**, **electronic stub and W-2GU consent wording**, and the **Client Service Agreement and Data Processing Addendum** between Cornerstone and Shimizu Technology (M3 plan §5.1), or an explicit written pilot carve-out that Leon and Dafne accept. Also, through Dafne, DRT's answer on electronic W-2GU copies and truncated SSNs (research Part 4B). | Leon and Dafne pick the firm. The lead prepares the packet. | Start now. The packet contents are in M3 plan §5.1. The direct deposit question (Q1) matters only once bank changes are on. |
| G2 | **WISP**: Cornerstone's plan covers Payroll, plus a Shimizu Technology platform security addendum. | The lead drafts, Dafne reviews. | The contents are in M3 plan §5.2. Includes the incident response plan. |
| G3 | **Clerk production live** (M3-0b complete, with its readiness evidence recorded; it's scheduled for the night of November 24) and **two-step sign-in on** for staff and client users (`REQUIRE_MFA=true`) after the M4-1 fix, on Clerk Pro. | Lead | Clerk Pro is bought at this gate (Leon, November 22). |
| G4 | **Row-level security enforced** (M3-7 phase 3). Employee endpoints run with the guard set to `raise`. | Lead | About December 9–11. |
| G5 | **Employee website and API service live:** Netlify site 2, Render `employee_web`, `mosas.shimizu-technology.com` and a company 1 subdomain for the team's own sign-ups, Clerk allowed subdomains. | Lead | M4-10. |
| G6 | **MoSa's admins have client logins:** Emma, Sara and Mo invited to the client portal, with `PORTAL_EMAIL_NOTIFICATIONS_ENABLED` on. | Leon's go | This follows the November 15 client-portal steps (Leon tests, Dafne re-runs a practice copy, then Emma is invited). |
| G7 | **Contact details entered** by MoSa's admins for each wave (D1). | Emma, Sara and Mo | Emma's first. |
| G8 | **Internal sign-off, then Emma:** (a) in production with no MoSa's employee invited, Leon and Dafne check employees, and Emma's client view once her client login exists (G6), with view-only Sign in as. The team does both kinds of real sign-up on company 1 (D10c), Mark and Benjo run the written script, and Dafne signs off. (b) Then Emma completes her acceptance as the first real user. | Leon, Dafne, Mark, Benjo, Emma | The go-live rule's steps 3–4 (architecture decision §6), without staging (D10a). |
| G9 | **Security check of the employee surface and Sign in as:** cross-company, cross-link and former-access tests under RLS `raise`; an adversarial review by a different model family; an automated scan of the employee site and API. | Lead | M4-11. A full penetration test is due before onboarding clients outside Cornerstone's current book (M3 plan §5.2). |

**Order of the gates.** G3, G4, G5, G6 and G9 come first, then the internal check (G8a). **Emma (G8b) also needs the WISP (G2),** which is drafted internally and doesn't wait on outside counsel. She needs either G1 or a pilot carve-out that counsel clears as a fast-track first question and that MoSa's owners (Sara and Mo) and Emma sign. Emma can't waive Cornerstone's own Safeguards or § 7216 duties on her own. Every other employee waits for all nine gates and their contact details (G7).

---

## 4. Build slices

Each slice is one pull request unless it says otherwise. Every slice merges to `main` **switched off**: the M4 switches stay locked until M4-9 opens them for one company at a time behind the gate checks. "Done" means reviewed, CI green, and deployed, with the switch still off.

**Standing rules for every slice:**
- **Every new company-scoped table is protected by row-level security from its first migration.** It gets a `company_id` (with composite foreign keys to its parent), is registered in `RlsTables` (`api/lib/rls_tables.rb`), gets its policies, and has a cross-company isolation spec. CI already fails on an unclassified table (`api/spec/security/company_rls_isolation_spec.rb:16-26`). Until M3-7 phase 3 turns enforcement on, policies are created but not enabled or forced, as the spec expects for every protected table (`:27`). They're enabled together with the rest in phase 3, or in a follow-up migration if the table lands after it.
- **Employee endpoints are tested with real authentication**, not stubbed auth, under the RLS guard in `raise` mode.
- **AIRE's routes, payloads and audit strings don't change.**
- **Every employee-facing 404 stays non-enumerating.** The web app turns it into a friendly message.

### M4-0 Plan and decisions (this PR)

- This document.
- An update to the architecture decision's milestone table: Milestone 4 drops "documents and policy sign-offs", notes that bank changes are off for MoSa's, and links this plan. Milestone 5 lists documents and policy sign-offs.

### M4-1 Two-step sign-in fix, step-up and readiness

- **Purpose:** make `REQUIRE_MFA=true` mean a real second factor, and give every change submission a step-up check that works for employees without a second factor.
- **Scope:**
  - Add a `two_factor_enabled` custom session claim (Clerk session token template), and require it with `fva[1]` in `MfaPolicy.verified_second_factor?`. `CableTicketService` already calls this method (`api/app/services/cable_ticket_service.rb:9`), so it only needs new specs.
  - Split step-up into two helpers:
    - `recently_verified_second_factor?` requires the claim and `fva[1]` within 10 minutes. It's for staff, client users, and employees who enrolled a second factor.
    - `recently_verified_any_factor?` accepts `fva[0]` within 10 minutes. It's for employee-only users with no second factor (D9), using Clerk's first-factor reverification.
  - Add one `require_recent_verification!` that picks the right helper for the signed-in user, and returns a response the web app turns into Clerk's reverification prompt (`useReverification`, first-factor level, available in `@clerk/react` 6).
  - **Google sign-in:** Clerk doesn't accept Google as a reverification factor. Turn on email-code first-factor verification in Clerk, so employees who sign in with Google confirm with an emailed code.
  - Add a readiness check that fails when `REQUIRE_MFA=true` but a test token lacks the claim.
- **Tests:**
  - A token with `fva [1,0]` and no `two_factor_enabled` is refused for staff. With the claim, it's accepted.
  - An employee-only token with `fva [3,-1]` passes step-up. One with `fva [25,-1]` is refused.
  - A staff token older than 10 minutes on the second factor is refused for step-up.
- **Acceptance:** repeat the M3 two-step test on the separate Clerk test app. Include the new-device email code case, a first-factor reverification by password, and one by email code for a Google-signed-in user.
- **Depends on:** nothing. It can start now.

### M4-2 Employee link lifecycle and sign-up (API)

- **Purpose:** the full path from invite to an active link, and from termination to *former*.
- **Invite (`EmployeeLinks::Invite`):**
  - Issues a link with a random token (only the digest is stored), a 14-day expiry, and `invited_by`.
  - **It doesn't create a login.** `users.email` must be unique and valid (`api/app/models/user.rb:41`), and many employees have no usable email yet, so the `portal_employee` user is created at sign-up. `EmployeeAccountLink#user` is already optional until the link is active (`api/app/models/employee_account_link.rb:4,13`).
  - Sends the invite to the employee's own email (M4-3), or prints a one-time sign-up code (10 characters, unambiguous letters, valid 14 days, single use, digest only).
  - **Same-person logins:** when the employee's email belongs to an existing login already confirmed as the same person (M4-3), such as Emma's client login, the invite points to "Sign in to add your employee access" (the claim path below) instead of new-account sign-up.
  - Resend keeps the link and rotates the token. Revoke records who, why and when (D12). Every step is audited.
- **Sign-up for a new person** (`POST /api/v1/employee/activation`, reachable before a link session exists):
  1. **Check:** the token or code, plus DOB and SSN last 4. It compares in constant time and returns one generic error for every failure. It locks after 5 failures per link (24-hour lock, staff can unlock), and alerts staff after 3 locks at one company in an hour.
  2. **Login:** on success, it creates the `portal_employee` user (home company = the employee's company, email = the address the employee enters) and records it on the still-`invited` link. The model allows that, since it requires a user only once a link is active. It then creates a Clerk invitation with `notify: false`, carrying the user id, link id and nonce in its metadata. This extends `PayrollInvitation` (`api/app/services/payroll_invitation.rb:29-98`). It returns the invitation's sign-up URL to the web app (`api/app/services/clerk_invitation_service.rb:22,37`) instead of emailing it.
     - **Retries:** if the employee abandons Clerk sign-up and comes back, activation reuses the link's pending user. It updates the email if the employee typed a different one and that address is free, and it rotates the invitation. No second user is created.
     - **Contact details at sign-up:** when the employee record has no email, the address the employee signs up with is saved to `employees.email`. Confirming it with Clerk's code sets `email_verified_at`. When the record already has a different address, the employee chooses which one gets notices.
     - **An email that already has a login:** activation returns the same generic response and points the employee to "Already have an account? Sign in", which uses the claim path below. It never reveals that the address exists.
  3. **Bind:** after Clerk sign-up, the web app calls `/auth/me`, where `bind_from_metadata` already runs (`api/app/controllers/concerns/clerk_authenticatable.rb:55-62`). That runs before the auth controller's RLS scope (`api/app/controllers/api/v1/auth_controller.rb:6`), so the extended bind does all of this inside `TenantScope.as_system` and `user.with_lock`, in one transaction:
     - looks up and locks the link;
     - re-checks that it's still `invited`, not expired, not locked, `portal_enabled?`, and that a subdomain token's `azp` matches the link's company;
     - marks it `active` with `activated_at`;
     - clears `invite_token_digest`.
- **Claiming a link with an existing login** (`POST /api/v1/employee/links/claim`, signed in): for someone who already has a Payroll login: a client admin who is also an employee, like Emma (D1); a Cornerstone staff member with a company 1 employee record, like Benjo (D10c); or an employee at a second client. `PayrollInvitation#send_invite` refuses users who are already bound (`payroll_invitation.rb:20-21`), so this path never sends a Clerk invitation. It takes the token or code plus DOB and SSN-4, requires step-up (M4-1), and attaches the link to the signed-in user. Staff and client users keep their own two-step rules. The web app switches roles using `/auth/me` `roles`.
- **Finding links:** `GET /api/v1/employee/links` (no link header needed) returns the signed-in user's eligible links: id, company name, subdomain slug, status, and former-access end date. The web app uses it for the employer picker and the `X-Employee-Link-Id` header.
- **Where `links` and `links/claim` live:** neither can inherit `EmployeePortal::BaseController`, which requires the link header (`base_controller.rb:19-23`).
  - They go in a small `EmployeePortal::AccountController` that verifies the Clerk token the same way, allows client-subdomain tokens (`clerk_authenticatable.rb:30,81-83`), and returns 404 on every failure.
  - On a client subdomain, both are limited to that subdomain's company (`TenantSubdomainRegistry`, as at `base_controller.rb:44-46`), so a worker's other employers never show up there.
  - `links/claim` gets the same throttles as activation: it's added to the activation path match and body check (`api/config/initializers/rack_attack.rb:56`).
- **Termination:** both status-transition services call `EmployeeLinks::Retire` (§1.1).
  - Terminate makes the link *former*, with `former_access_until = termination date + former_access_years`.
  - Deactivating without a termination date revokes the link with a reason. It doesn't start a former window.
  - Reactivation and rehire issue a new invite.
  - **A rehired employee-only person keeps their login.** If their `portal_employee` user was deactivated when their last link closed, the new invite goes through activation, not the claim path. The claim path refuses deactivated users. Activation re-checks the token or code plus DOB and SSN-4. The person then signs in to their existing Clerk account, and that fresh sign-in is the M4-1 step-up (`fva[0]` within 10 minutes). It's handled by a restricted reactivation endpoint that accepts a deactivated `portal_employee` only for this one step. Only then does it reactivate the same user and bind the new link, in one transaction. A spec proves that any failed check leaves both the user and the new link inactive. The old link stays closed, and the Clerk sessions revoked at deactivation stay revoked, so the person signs in fresh. If they're a staff or client user too, their login was never deactivated and they use the claim path as usual.
  - Closing the last eligible link deactivates the `portal_employee` user and revokes their sessions (D12).
- **`ExpireEmployeeLinksJob`** runs daily. It expires unused invites and closes former access when the window ends.
- **Audit and context fixes:**
  - `AuditActor.for_user` maps `portal_employee` to `employee`.
  - The employee base controller adds `Auditable`. It defines `current_company_id` from the link, sets `Current.user` and `Current.actor`, and resets `Current` after each request.
  - Sign-in, every view and every download are audited.
- **Rate limits for one shared Wi-Fi** (§1.5):
  - Key the employee, auth-on-tenant, PDF and activation limits on the signed-in Clerk session or link where one exists, with a higher per-IP ceiling as a backstop.
  - Keep strict per-link and per-token limits on sign-up.
  - Let the activation body check accept `token` or `code`.
  - Add tenant-origin CORS headers to throttled and rejected responses, for registered tenant origins only.
  - Prove it with 30 simulated phones on one IP: sign-up, `/auth/me` and PDF downloads.
- **Tests:**
  - The whole lifecycle, including claim-with-existing-login.
  - Wrong DOB, wrong SSN-4, wrong code, expired token, revoked link, reused code, and lockout. None of them reveals whether an employee exists.
  - The cross-company and cross-link matrix under RLS `raise`.
  - Termination and deactivation from both services.
  - Revoking signs out the session.
- **Depends on:** M4-1 for step-up, and M4-3 for contact validation and the invite guard.

### M4-3 Contact details: one place, easy to update, and the shared inbox fixed

- **Purpose:** every employee has their own email and phone, and they're easy to set and update by the client, by Cornerstone and by the employee (Leon, November 24).
- **Where contact details live:**
  - **`employees.email` and `employees.phone` become the employee's own contact details.** Add `email_verified_at`, `phone_confirmed_by_employee_at` (not "verified": without SMS, a code sent by email proves who the employee is but not that they own the phone), a source (client, staff, employee, import) and change history. Any change to the email by an admin or client clears `email_verified_at`, so stub notices never go to an unconfirmed address. This replaces the separate `employee_contacts` table from the earlier draft. That table was only there to keep the shared inbox untouched, and the inbox is now being fixed.
  - **Other code that reads or writes `employees.email`** gets a spec and a fix where needed:
    - `TimeTracking::EmployeeMatcher` (`api/app/services/time_tracking/employee_matcher.rb:36-40`) suggests the first employee with a matching email at full confidence. With family-shared emails it must match by email only when exactly one active employee has that address, and fall back to name matching otherwise.
    - AIRE cockpit matching suggestions (`api/app/services/aire_payroll_cockpit/presenter.rb:150-165`) and time-tracking history approval (`api/app/services/time_tracking/history_approval.rb:333`).
    - Cornerstone Tax client-profitability matching against company 1 employee emails (`api/app/services/client_profitability/link_queue.rb:132`).
    - Write paths that must run the shared validator below: the employee bulk import (`api/app/services/employee_bulk_import/import_service.rb`), and the W-2/1099 transition, which copies email and phone to the new worker record (`api/app/services/employee_classification_transition_service.rb:134`) and must not copy `email_verified_at` blindly.
    - Search, serializers and the audit subject fallback (`api/app/controllers/api/v1/client/employees_controller.rb`, `api/app/controllers/api/v1/admin/employees_controller.rb`, `api/app/services/audit_record_snapshot.rb:85`) need no change, but get covered by specs.
    - Mailers, W-2 and 1099 generators don't read it.
  - **The sign-in email** (`users.email`, and the email on the Clerk account) is separate. It's the address the employee signs up with, and it changes only as an account change.
  - **Home address** stays on `employees` and changes through MoSa's approval when the employee asks (M4-7).
  - **Emergency contacts** get their own table (M4-7).
- **Shared inbox cleanup:**
  - At the November 24 check, one address was on 405 employee records at 5 companies (221 active), and a second address was shared by 5 more (§2).
  - A staff "Shared and placeholder emails" report lists them by company.
  - Cornerstone clears them to blank in bulk, company by company, with an audit. Nothing depends on the shared address (Leon, November 24). A blank shows up as "needs contact details", which is better than a wrong address.
  - No production data changes without Cornerstone's go.
- **Easy to set and update:**
  - **Client portal:** a "Contact details" page lists every employee's email, mobile and address in one editable grid, with a "needs contact details" filter and save per row. Edits apply directly, as they do today, and are audited.
  - **Admin app:** the same page for Cornerstone staff.
  - **Employee app:** M4-7.
  - **The same rules everywhere:**
    - email format check;
    - mobile numbers normalized, with Guam numbers defaulting to +1 671;
    - a warning, not a block, when another employee at the same company uses the email, since family members sometimes share one;
    - a block on the known placeholder list and on **another person's** staff or client login email. An employee's own login email is allowed when that login is already linked to the employee, or when staff or a client admin confirms that it's the same person (name match plus an explicit, audited confirmation). That covers dual-role people like Emma and Cornerstone staff with company 1 records, without ever silently accepting a case like Dafne's email on a MoSa's record.
  - **One shared validator** enforces these rules on every write path: the client portal, the admin app, the employee app, bulk import and the classification transition.
  - An email entered by an admin stays unverified until the employee confirms it at sign-up or with a code.
  - **Optional import:** a client that prefers a spreadsheet can upload CSV or Excel to the same page. It previews the matches and lists unmatched rows, never guessing. MoSa's doesn't need it.
- **Invite guard:** an email invite goes only to an address that passes those rules and isn't used by another employee.
- **Tests:** the real shape of the data (one address on hundreds of records, a staff user's address, a family-shared address).
- **Depends on:** nothing. It can run in parallel with M4-1.

### M4-4 Employee pay API

- **Purpose:** employees see their own checks, matching the printed stub.
- **Scope:**
  - **Extract a shared `EmployeePayStatements`** service and presenter from the AIRE worker statements controller. AIRE keeps its routes, JSON and audit strings exactly, proven by its existing specs (`integrations/aire/worker_statements_spec.rb`, `pay_run_activity_spec.rb`) plus a golden-file comparison.
  - **Endpoints:**
    - `GET /api/v1/employee/statements`: year filter, newest first, paged.
    - `GET /api/v1/employee/statements/:id`
    - `GET /api/v1/employee/statements/:id/pdf`
    - All are gated by `employee_portal.features.stubs` through `employee_portal_feature?`, and all are audited (`employee_statement#listed/viewed/pdf_downloaded`, category `employee_portal`).
  - **Frozen stub as issued (D7):**
    - **When a stub posts:** the pay period is `reportable_committed` (`api/app/models/pay_period.rb:331`). It's 6am Guam time (`Pacific/Guam`) on the pay date, or later if the run was committed after that. And a paper check has its check number assigned. A paper check with no number waits until one is assigned. Payment evidence (a delivered check, a confirmed deposit) isn't a trigger: it can't be recorded ahead of time (`api/app/services/employee_payroll_payment_evidence.rb:13-27`), and MoSa's records its own ACH outside Payroll.
    - **What the frozen PDF says about payment:** the employee copy prints only "Direct deposit" or "Check #1234". The staff wording "Direct deposit (stub only; transfer not confirmed)" (`api/app/services/pay_stub_generator.rb:138-143`) is replaced through an employee-copy option on the generator. Live payment status (prepared, printed, delivered, transfer confirmed) is shown in the app from `EmployeePayrollPaymentEvidence`, never baked into the PDF.
    - **Storage:** at posting, the PDF is generated once and stored in R2 with a SHA-256 fingerprint, in an `employee_documents` table. Its source is one of a payroll item, a QuickBooks check (`historical_paycheck_id`) or a W-2GU (`tax_year`), with partial unique indexes such as `(payroll_item_id, revision)` and `(historical_paycheck_id, revision)`. The posting job takes a row lock, so two downloads can't freeze two copies. Downloads serve the frozen file.
    - **"Corrected" revisions** happen only on changes that alter the PDF: a delivery-method switch, a check number change or replacement check, a void or reversal, or a correction run. They post a new revision marked "Corrected" and keep the original visible as replaced. Recording a delivery or a deposit confirmation never creates a revision or a second notice.
    - Posting also triggers the D11 notice.
  - **Earlier 2026 pay (D6),** possibly as its own PR:
    - The Pay list shows January–August checks from `historical_paychecks`, labeled "From QuickBooks records". It uses only rows matched to the employee in a locked import batch (`status: "locked"`, the same scope as `UnifiedPayrollReporting#locked_historical_scope`, `api/app/services/unified_payroll_reporting.rb:291-297`), from regular pay periods, with `reconciliation_status: "matched"`. Opening-summary rows are never shown. Any `historical_paycheck_adjustments` on a check are shown with a note, so totals aren't shown unadjusted.
    - **Original QuickBooks PDFs:** a staff upload takes Cornerstone's files, which are one file or page per check (Leon, November 24). Each page must carry an unambiguous employee name, pay date and net pay, because direct-deposit checks may have no check number. It previews matches by those fields and posts only confirmed matches as "Original QuickBooks stub", frozen with a fingerprint. Unmatched pages stay unposted.
    - **Before anything posts:** an automated text scan on every upload blocks a page that shows a 9-digit SSN or the employee's full SSN, so later uploads stay protected too. Staff also confirm that the imported rows group into one entry per check (Emma has 59 rows, §2).
    - Gated by the same `stubs` switch.
  - **Former links:** read-only, limited to statements dated before `former_access_until`.
  - **Performance:** use the per-item YTD snapshots already stored, and page in SQL, not in Ruby (the AIRE list loads all years today). Listing posted `employee_documents` makes the page query simple. Eligibility (`EarningsStatementEligibility.printable?`, `api/app/services/earnings_statement_eligibility.rb:18-28`) is checked once, at posting, instead of on every list.
- **Tests:** an employee can't see another employee's or company's statements, a draft or uncommitted period, or a voided original without its replacement. AIRE output is unchanged.
- **Depends on:** M4-2.

### M4-5 W-2GU copies in the app

- **Purpose:** the 2026 W-2GU (Copy B and C) is available in the app alongside the paper copy.
- **Scope:**
  - Add a single-employee path to `W2GuOfficialCopies`. Serve it only when it would print as final for staff: the W-2 readiness record is current and the filing-responsibility gate allows it (§1.3).
  - Freeze each posted copy with a fingerprint, like stubs.
  - Gate it by `employee_portal.features.tax_forms`.
  - Notify the employee by email with the subject "IMPORTANT TAX RETURN DOCUMENT AVAILABLE". That's required for electronic furnishing and harmless when paper also goes out.
  - Keep the copy available at least through October 15, 2027.
  - Record bounces for these notices. The pilot doesn't need them, because paper goes out anyway. But bounce tracking, with a mailed notice within 30 days, is required before electronic-only W-2s are switched on (26 CFR 31.6051-1(j)).
- **Not in this slice:** W-2c and corrected-form posting. Until W-2c exists, staff can withdraw a posted copy, and the app says "A corrected form is being prepared."
- **Depends on:** M4-4 (shared storage and audit). The Year-End filing record from Milestone 1 is already live.

### M4-6 Electronic-delivery consent records

- **Purpose:** the records counsel will need before electronic-only delivery. They're built now so the switch is ready.
- **Scope:**
  - `delivery_consents` stores account, employee, kind (pay statements; W-2GU), disclosure version and text digest, given-at, IP and device, method, and withdrawn-at.
  - Disclosure texts are versioned and stored, and loaded from counsel's wording.
  - Withdrawal works in one tap and triggers paper.
  - The W-2GU consent follows 26 CFR 31.6051-1(j): all the disclosures from research Q7, and a "can you open this PDF" step that proves access.
- **Ships with the consent screens hidden** until counsel's text is loaded. Paper continues for everyone during the pilot (D5).
- **Before electronic-only delivery can be switched on later:** counsel's wording (G1), DRT's answer (G1), bounce tracking with mailed notice (M4-5), and paper-on-withdrawal working end to end.
- **Depends on:** M4-2. The final wording depends on G1.

### M4-7 Employees' own contact changes and address requests

- **Purpose:** employees keep their details current without calling the office, following D4.
- **Applied right away, after step-up (M4-1):**
  - mobile phone and personal email, on the employee record with a verified mark (M4-3);
  - emergency contacts, in a new `employee_emergency_contacts` table (company-scoped, RLS protected): name, relationship, phone.
  
  A new personal email is verified by code before it's saved. Each change is audited, and MoSa's admins and the assigned Cornerstone staff are notified.
- **Home address goes through MoSa's approval (D4):**
  - Use the existing `EmployeeChangeRequest`. Keep `requested_by_id` as the signed-in user, and add a nullable `requested_by_link_id`. That's simpler than a polymorphic requester and keeps today's validations and serializers (`employee_change_request.rb:63`).
  - **Add a client approval path, limited to address requests about the requester's own record.** The request is either employee-submitted (`requested_by_link_id` is present) or a client admin's own-record request (`requested_by_id` is a client user linked to that employee, or confirmed as the same person in M4-3, recorded on the request as `own_record: true`). In both cases the request is an update, the proposed fields are only `address_line1`, `address_line2`, `city`, `state` and `zip`, and there's no sensitive payload. A client user with access to the company approves or rejects those. Every other change request, including client-submitted pay rate, W-4, SSN and new-hire requests, stays staff-only with `manage_client_configuration` (`employee_change_request.rb:129-137`). Cornerstone can still approve address requests too.
  - **No self-approval:** a request about the approver's own employee record must be approved by someone else. The approver can't be the requester, or anyone linked to or confirmed as that employee. **A client admin's edit to their own address** goes through the same approval. When a client user edits the employee record linked to their own login (through `employee_account_links`, or the same-person confirmation in M4-3), the client portal turns the address change into an address request for another MoSa's admin or Cornerstone to approve. Direct edits to other employees' addresses still apply right away and go onto Cornerstone's confirm list.
  - On approval the address applies, the employee sees "Your W-2 will be mailed here", and the change goes on Cornerstone's confirm list.
  - The employee sees the request's status and the decision.
- **Cornerstone's "Changes to confirm" list:** every contact or address change made by an employee or a client user, with before and after, who made it, and a "Confirmed on payroll" button. Starting a payroll run for the company shows a warning while any are unconfirmed, but doesn't block the run. Filters and a "Confirm all" action handle initial entry, such as MoSa's filling in 61 employees' details at once. The list is stored in an RLS-protected table.
- **Legal name and SSN** show "Contact Cornerstone" with what to bring. They're not editable.
- **Notifications.** Today's notification types reach only staff or client users, so this needs new wiring:
  - A new `employee` audience. The employee's decision notice goes to their verified `employees.email`. `employee_change_decided!` reaches only client users today (`api/app/services/portal_notifications.rb:33-35`).
  - New client-audience events: MoSa's admins get address requests to approve and a notice of each contact change. `employee_change_submitted` reaches staff only (`portal_notifications.rb:25-28`).
  - Cornerstone gets the confirm list, plus the existing `employee_change_submitted` for addresses.
- **Client portal:** a company-wide "Employee changes" list where MoSa's admins approve address requests and see contact changes.
  - It needs new `approve` and `reject` routes. Client change-request routes are `index` and `show` only today (`api/config/routes.rb:95`).
  - It needs explicit scoping. `index` shows only the user's own requests today (`api/app/controllers/api/v1/client/employee_change_requests_controller.rb:13`). The company-wide list shows employee-submitted address requests to every admin at the company, while client-submitted payroll-sensitive requests keep today's visibility.
- **One pending request per employee** (`api/db/schema.rb:940`), in both directions:
  - If a client user already has a request open for that employee, the employee sees "A change is already being reviewed" instead of a conflict error.
  - If the employee's address request is pending, a client submitting a pay or W-4 change gets a message linking to that request. The current message says "A payroll-sensitive change request is already pending" (`api/app/services/client_employee_update_service.rb:348-353`), which would be misleading here.
- **Gated by:** `employee_portal.features.profile_requests`.
- **Depends on:** M4-1, M4-2 and M4-3.

### M4-8 Employee web app

- **Purpose:** the app employees use, phone first.
- **Scope** (`VITE_APP_SURFACE=employee`):
  - **Sign-in** with the client's name and logo from tenant branding, and Clerk's sign-in on the subdomain.
  - **Sign-up:** token or code, DOB and SSN-4, Clerk account, personal email.
  - **Employer picker:** for anyone with more than one link. It sets `X-Employee-Link-Id`.
  - **Screens:**
    - **Home:** the latest check (pay date, net, "View stub").
    - **Pay:** a list by year, then the check (gross, taxes, deductions, net, YTD), then the PDF. Earlier 2026 checks appear under "From QuickBooks records", with the original PDF once posted.
    - **Tax forms.**
    - **My info:** contact details plus "Request a change", with the request's status.
    - **Help:** who to contact (§5 Q2).
  - **Former employees:** a read-only mode.
  - **Rules:** pay data is never cached in the service worker or local storage, and PDFs are served `no-store`. **PostHog is removed from the employee build** (`web/src/employee-main.tsx:4,11`), and `appSurfaceBuild.test.ts` asserts it's absent.
  - **Legal:** links to counsel's Employee App Terms and Privacy Notice (G1) on sign-up and in Help. Sign-up records acceptance with the version.
  - **Unavailable:** when the API returns 404 because the app is switched off or a link has ended, the app shows a friendly "The employee app isn't available right now" or "Your access has ended" screen. It never says whether a person exists.
  - **Errors:** messages that never reveal whether an employee exists.
  - **Phone basics:** a tenant-branded manifest and icon, a safe-area-aware layout, 44px tap targets, and no zoom on input focus.
- **Tests:** a Playwright project on iPhone and Pixel devices builds the employee surface and simulates the subdomain. It covers sign-up, viewing a stub, downloading the PDF, a contact change with step-up, an address request, former mode and a lockout message. iPhone device profiles run on WebKit, which doesn't run on the Mac mini, so WebKit runs in CI or on the ASUS. Chromium mobile emulation runs locally.
- **Depends on:** the M4-2 and M4-4 APIs. The screens can start against the API contracts in parallel.

### M4-9 Staff and client admin tools, and the switch

- **Purpose:** Cornerstone and MoSa's run the rollout without the database.
- **Scope:**
  - **The employee's record:** an "Employee app" panel showing status (not invited / invited / active / locked / former / revoked), with invite, resend, print a sign-up code, unlock and revoke. All of them are audited.
  - **Company rollout page:** how many are ready to invite, invited, active, need contact details, or are locked. Bulk-invite a chosen wave.
  - **Sign in as, view only (D10b):**
    - **Who and what:** an org admin with a separate permission (Leon and Dafne to start), who also passes `payroll_access_allowed?` and has access to the target's company, the same checks payroll-sensitive staff paths use (`api/app/models/employee_change_request.rb:132-133`, `api/app/models/user.rb:109-112`), picks a target and sees exactly what that person sees, worked out from that person's roles, company access and link, never more. The target can be a client user or an employee record. It can never be another staff user, or a person or record in another organization.
    - **The grant:** a server-side row (staff user, one company, target user or target employee, mode, reason, expiry). Starting it needs a fresh two-step check (M4-1) and a reason. It lasts at most 30 minutes, with a banner the whole time ("Viewing as Elena Mercer, view only") and an end button.
    - **Where it renders:**
      - Client views render in the main app.
      - Employee views open the real employee site (for example `mosas.shimizu-technology.com`) against `employee_web`, so the check covers the real surface.
      - The staff member signs in there with their own Clerk session. The grant is passed in a header to a small inspect and end route under `/api/v1/auth/` that accepts subdomain tokens and uses the real user.
      - The banner shows in both apps (M4-8).
    - **Enforcement:** one shared concern, included in both `ApplicationController` and `EmployeePortal::BaseController`, which doesn't inherit from it (`api/app/controllers/api/v1/employee_portal/base_controller.rb:6`). It runs after Clerk verification and MFA on the real user, and before `ExplicitCompanyAccess` and the RLS scope:
      - the company is pinned to the grant's one company, within both the staff member's and the target's access;
      - every request except GET, HEAD and OPTIONS is refused, apart from ending the grant;
      - `track_authenticated_user_activity` is skipped, because it writes to the user and records a sign-in on every request (`api/app/controllers/application_controller.rb:44-75`);
      - reads have no side effects while viewing: no stub posting or freezing (M4-4), no notifications, and no audit rows in the target's name;
      - `Current.real_user` and `Current.view_as_grant` stay separate from the effective user;
      - `AuditLog.record!` itself stamps the real user and the grant on every row, because many controllers call it directly with `current_user`, for example `api/app/controllers/api/v1/client/pay_periods_controller.rb:73`.
    - **Employees who haven't signed up:** there's no user or link row yet, so the grant resolves a read-only employee context (employee, company, simulated status). The M4-4, M4-5 and M4-7 read services take that context instead of a link.
    - **The log:** each session is audited as "Leon viewed as Emma". A new client endpoint (`GET /api/v1/client/support_access_logs`) shows only those events for the client's company, so client admins can see them without seeing internal staff audit entries.
    - **No session as the user:** Clerk's own impersonation feature was considered and not used, because it creates a session as the user.
  - **Client users** see the rollout page, enter contact details (M4-3), and invite, resend and print sign-up codes for their company's employees (D1). Revoking stays with Cornerstone in the pilot, apart from termination, which retires links automatically.
  - **Cleanup report:** inactive employees with no termination date.
  - **Lift the M4 lock for one company at a time** for `employee_portal_enabled`, `subdomain_enabled`, and the `stubs`, `tax_forms` and `profile_requests` features. **`bank_requests` stays locked** (D3; it also depends on an `sms_provider` setting that doesn't exist). They can be turned on only when production readiness passes the M4 checks:
    - `REQUIRE_MFA=true` with the claim (M4-1);
    - RLS guard in `raise`;
    - `CLERK_AUTHORIZED_PARTIES` set and the company's `subdomain_slug` set (client subdomains are authorized through the subdomain registry, not static lists: `api/app/services/clerk_token_verifier.rb:244-267`, `api/config/initializers/cors.rb:14-31`);
    - the `employee_web` service healthy;
    - counsel text loaded for any terms or consent screen that's shown.
    
    The setting screen lists any failing check by name.
- **Depends on:** M4-1, M4-2 and M4-3. The view-only employee screens also need M4-8, so that part can ship as its own PR.

### M4-10 Platform: employee site and service

- **Scope:**
  - **Render `employee_web` service** (Starter, $7): `APP_PROCESS_ROLE=employee_web`, `DB_POOL_MAX=3`, the shared Redis rate-limit store, its own health check. Check the connection budget against Neon (M3 plan §6).
  - **Netlify site 2** for `VITE_APP_SURFACE=employee`, with base `web/` and its own build settings beside `web/netlify.toml`. It has its own `_redirects` and headers (CSP, `no-store` on the app shell's data routes). Deploy previews stay off. Build credits are watched, because both sites share the team pool.
  - **`mosas.shimizu-technology.com`**, following `docs/CLIENT_SUBDOMAIN_ACTIVATION.md`: company 6 slug and branding, the Netlify alias on site 2, a DNS-only CNAME, and the Clerk allowed subdomain. CORS and Clerk authorized parties come from the subdomain registry automatically, so there are no static list edits.
  - **A company 1 subdomain** for the team's own real sign-ups (D10c), set up the same way. The switch requires a `subdomain_slug` (M4-9), and only `mosas` was planned.
  - **A smoke check** of each subdomain before anyone signs up: TLS, headers, CORS and branding.
  - **No staging for this milestone (D10a).** Staging's tester and containment rules stay as they are.
  - **Runbooks** for both services, and readiness checks for the employee surface.
  - **Alerts:** employee 5xx rate, activation lockouts, rate-limit hits.
- **Depends on:** M3-0b (Clerk production). Everything else can be prepared earlier.

### M4-11 Security verification

- **Scope:**
  - A full isolation suite for every employee endpoint, under RLS `raise` with real authentication (no auth stubs). Real auth is what caught the `ExplicitCompanyAccess` issue in #543.
  - An adversarial review of the whole employee surface by a different model family.
  - An automated scan (OWASP ZAP baseline) of a local build, and of the production employee site and API before anyone is invited.
  - Sign in as: no escalation, no writes in view-only mode, the time limit, and the audit trail.
  - Checks on enumeration through the sign-up and error paths.
  - Recorded results for the WISP.
- **Depends on:** M4-2 through M4-10.

### M4-12 Go-live runbook and acceptance

- **The internal check (G8):**
  - **Before production:** a real new-user activation on the Clerk test app with matching subdomain settings.
  - **In production, with the app on for MoSa's and no employee invited:** Leon and Dafne use view-only Sign in as on several MoSa's employees (hourly, salaried, direct deposit, paper check), and on Emma's client view once her client login exists (G6). They compare stubs with the printed ones.
  - **The team's real sign-ups on company 1 (D10c):**
    - a claim with an existing login, such as Benjo's;
    - one brand-new employee-only sign-up with a second email, revoked afterward, which also proves that revoking ends the Clerk session (D12);
    - covering stubs, a contact change with a code, lockout and unlock.

    Emma and Benjo both use the claim path, so without this new-user sign-up the first real one would be a wave 1 employee's.
  - Mark and Benjo run the written script, and Dafne signs off.
- **Emma's acceptance** (wave 0): Emma gets her client portal login, claims her employee access, and runs the script as both admin and employee:
  - stubs, QuickBooks history, and the W-2 copy once posted;
  - a contact change, and an address request approved by Sara or Mo;
  - the rollout page and contact entry.
- **The rollout runbook.** Each step starts only when its gates in §3 ("Order of the gates") are met: Emma after G3–G6, G9, G8a, G2 and G1 or a cleared carve-out; wave 1 after all nine gates and G7.
  1. turn on for MoSa's;
  2. invite Emma, Sara and Mo to the client portal (if not already done);
  3. Emma (wave 0);
  4. MoSa's enters contact details and invites about 5 employees (wave 1);
  5. one full pay period;
  6. wave 2, everyone else.
- **Rollback:** switch off for MoSa's. Links and records stay. The API returns its usual 404, and the app shows "The employee app isn't available right now".
- **Support:** who answers employee questions (§5 Q2), and a one-page "how to sign up" sheet for MoSa's to hand out.

### M4-13 Full "Sign in as" (acting for a user)

- **Purpose:** Cornerstone support can do what a user could do, on their behalf, the way Salesforce's "Log in as" works. Leon asked for this to be planned properly and fully (November 24).
- **Builds on** M4-9's view-only grant and adds an "act" mode.
- **Who can use it:**
  - A separate permission, granted per staff member, with Leon and Dafne by default.
  - Never as another staff user, and never as someone with more access than the staff member.
- **One company per grant:** a client user or employee with access to several companies can be acted for only in the grant's one company, and only where that company allows it.
- **The client's permission:**
  - A company setting, "Allow Cornerstone support to act for our users", controlled by the client's admins, with an optional time limit.
  - Employees are covered by the privacy notice. Acting for an employee also needs a recorded reason, such as the employee's own request.
- **Starting a session:** a fresh two-step check, a reason, the target and the mode. It lasts at most 30 minutes, one session at a time, with an end button and a banner.
- **Recording:** every change stores both who did it (staff) and who it was for (the user), in the audit log and in record history ("Changed by Leon Shimizu for Elena Mercer"). The user is notified of changes made for them.
- **Never allowed, even when acting.** Only the person can:
  - accept the terms or privacy notice;
  - give or withdraw electronic-delivery consent;
  - complete policy sign-offs, W-4s or other signatures;
  - approve a payroll as the client (`api/app/controllers/api/v1/client/pay_periods_controller.rb:28-35` requires a client user);
  - make bank changes;
  - change their sign-in email, password or two-step settings;
  - invite or remove users, or change anyone's access;
  - change or extend the "Allow Cornerstone support to act for our users" setting;
  - request payroll changes or decide on payroll submissions as the client (`Client::PayPeriodsController#request_changes`, `api/app/controllers/api/v1/client/pay_periods_controller.rb:48-58`, and the payroll submission period routes, `api/config/routes.rb:101-108`);
  - bind an employee identity (activation or claim);
  - submit payroll-sensitive changes, such as pay rate, W-4 or SSN.

  These show "Only Emma can do this."
- **Code shape:** one central check with an allowlist of actions permitted while acting, wired into both base controllers. New write endpoints are denied by default. A spec fails if a write endpoint isn't classified, and it runs with `APP_PROCESS_ROLE=all` so every route is checked. `AuditLog.record!` stamps the staff member as the actor and the user plus the grant as on-behalf-of (M4-9).
- **Legal:** a question for counsel on acting for users (consent, notice, attribution), and wording for the client agreement and privacy notice.
- **Tests:**
  - escalation attempts;
  - each forbidden action;
  - attribution in history and notifications;
  - the time limit;
  - ending the grant mid-session.
- **When:** after view-only and after wave 1. It isn't a launch gate.
- **Depends on:** M4-9, an extension of M4-11's security review, and counsel's wording (G1).

---

## 5. Order of work and dependencies

```text
Now, in parallel (no code dependency):
  G1 lawyer packet + G2 WISP draft        (outside track; longest lead time)
  M4-1 two-step fix
  M4-3 contact details, shared-inbox cleanup + email guard
  M4-10 prep (runbooks, Netlify site, Render service definition)

Then:
  M4-2 link lifecycle + sign-up           (after M4-1, M4-3)
  M4-4 pay API                            (after M4-2)
  M4-7 contact changes + address requests (after M4-2)
  M4-8 web app                            (screens start early; wire up after M4-2/M4-4)
  M4-9 admin tools + switch               (after M4-1, M4-2, M4-3; view-only employee screens after M4-8)
  M4-5 W-2 copies                         (after M4-4; needs the Year-End W-2 readiness record)
  M4-6 consent records                    (after M4-2; wording after G1)

Then:
  M4-11 security verification
  G3, G4, G5, G6, G9 → M4-12 internal check (G8a) → G2 + (G1 or cleared carve-out) → Emma (wave 0, G8b)
    → all gates G1–G9 + G7 → wave 1 → one pay period → wave 2

After wave 1:
  M4-13 full Sign in as                   (after M4-9; wording after G1)
```

- **Overlap with the database lock:** M4 code can merge while RLS is in watch-only mode. But no employee signs in until RLS is enforced (G4) and has run for at least one normal payroll.
- **Overlap with year-end:** Milestone 1 keeps priority. A useful target, not a commitment: wave 1 live before W-2GUs are furnished (February 1, 2027), so the W-2 copy shows up in the app. That depends mostly on how fast counsel answers.

### Questions for Cornerstone (through Leon or Dafne)

1. Do the original QuickBooks stub PDFs print a full SSN (D6)? They're one file or page per check.
2. Who answers employees' app questions: MoSa's admins, Cornerstone, or both? Whose phone or email goes on the Help screen?
3. Which 5 or so employees should be in wave 1?
4. Which law firm reviews the packet (G1)?

---

## 6. Risks and mitigations

| Risk | How it happens | Mitigation |
|---|---|---|
| **Invites go to the wrong person** | 45 employees share one inbox, and one employee's email belongs to a staff user (§2). | The shared inbox is cleared (M4-3). MoSa's admins enter real addresses through one shared validator that refuses placeholders and another person's login email. Sign-up also needs DOB and SSN-4. |
| **Someone guesses their way in** | DOB and SSN-4 are guessable for someone who knows the person. | A token or one-time code is required as well. Lockout after 5 failures, staff alerts, generic errors, Rack::Attack limits, and an audit of every attempt. |
| **One employee sees another's pay** | A query not limited to the link's employee, or a header swap. | The employee is resolved from the link only (`base_controller.rb:18-47`). RLS in `raise` mode. A cross-link and cross-company matrix with real auth (M4-11). |
| **Shared Wi-Fi locks out a whole shift** | Per-IP limits on auth (20 a minute), tenant requests (30), sign-up (10 per 15 minutes) and PDFs (15), all shared by one restaurant IP (§1.5). Throttled responses also lack tenant CORS headers. | Session- or link-keyed limits with a per-IP backstop, plus tenant CORS on 429 and 400, in M4-2, tested with 30 simulated phones on one IP. |
| **A revoked person keeps using the app** | Revoking a link in the database doesn't end their Clerk session. | D12: the link check blocks the next request, the login is deactivated with its last link, and Clerk sessions are revoked through Clerk's Backend API. |
| **Stubs change after the employee saw them** | Stubs are regenerated on every download today. | The frozen issued copy plus "Corrected" documents (D7). |
| **AIRE My Pay breaks** | Extracting the shared statement service changes AIRE's output. | Golden-file comparison and AIRE's specs on every PR. AIRE's routes and audit strings stay frozen. |
| **Employees in two places see different numbers** | AIRE and the employee app use separate code paths. | One shared service (M4-4). |
| **Legal wording blocks launch late** | Counsel's answers arrive after the build is done. | Start G1 now. Build consent records with placeholder wording that stays hidden. Launch only with paper continuing (D5). |
| **Pay data leaks through analytics or caching** | Session replay or a service worker caching API responses. | No content capture in the employee build, no caching of pay data, `no-store` headers (M4-8). |
| **Netlify credits run out** | A second site shares the team pool that ran out on November 20. | Previews off, an ignore-build script on both sites, and the contingency plan in the M3 plan. |
| **The 2026 W-2 in the app is wrong** | Posted before the filing record is final, or a correction is needed with no W-2c. | Only when it would print as final for staff (current readiness record plus the filing-responsibility gate). Staff can withdraw a posted copy. W-2c is a follow-up before electronic-only delivery. |
| **Year-end is delayed** | M4 work competes with the January deadlines. | Milestone 1 keeps priority. M4 slices merge switched off. |
| **Sign in as is misused** | A staff member views or acts for someone without a reason. | View-only first. A separate permission held by two people, plus step-up, a reason, a time limit, a banner, and an audit the client can see. The full mode has a default-deny allowlist and never covers legal acts (M4-13). |
| **An admin approves their own change** | Emma is both a MoSa's admin and an employee. | No self-approval (M4-7). |
| **QuickBooks PDFs expose too much or reach the wrong person** | An original stub prints a full SSN, or a page is matched to the wrong employee. | SSN check before posting, staff-reviewed matches only, and unmatched pages stay unposted (M4-4). |
| **Clearing the shared inbox breaks something** | Leon confirmed nothing depends on it, but matching code reads the field. | Specs on every reader (M4-3), a report first, then clearing company by company with an audit. |
| **The client is the first to hit a bug** | There's no staging round, and Emma is the first real user. | Local, CI and Clerk test-app runs, view-only checks in production, and the team's own sign-up before Emma (D10c). |

---

## 7. Costs

| Item | Now | At the M4 gate | Notes |
|---|---|---|---|
| Clerk | $0 (free plan, production) | **$25 a month** Pro, for two-step sign-in | $20 a month if billed annually (M3 plan §7) |
| Render employee web | $0 | **$7 a month** Starter | No separate employee worker until Milestone 6 |
| Netlify site 2 | $0 | $0 (shared credits) | +$9 a month only if credits run short |
| Law firm | | One-time fee | Unknown until a firm quotes |
| **Total** | **$0** | **$32 a month** ($27 billed annually) | Same as M3 plan §7 |

---

## 8. Milestone acceptance

Milestone 4 is done when:

1. Every slice above is merged and deployed, switched off by default.
2. Gates G1–G9 are met and recorded.
3. Leon, Dafne, Mark and Benjo have signed off (G8), and Emma has completed her acceptance.
4. MoSa's wave 2 (everyone) has used the app for one full pay period, with these confirmed:
   - no cross-employee access in the audit;
   - no change in how pay is run;
   - stubs in the app match the printed stubs.
5. Emma, Sara and Mo have used the rollout page and request list as admins.

---

## 9. Review log

**Round 3 (Gemini 4 Neon, high, review of the answer-round changes `c594d055..4479d5d7`): "ready with fixes."** Every finding the lead spot-checked held against the code, and all are fixed in this revision:

- **Blockers:**
  - View-only Sign in as had no rendering path or enforcement design. GET requests write activity and audit rows, the employee base controller doesn't inherit `ApplicationController`, employees who haven't signed up have no link, there were no target limits, and there was no client log endpoint (M4-9).
  - The client approval path would have let a client approve payroll-sensitive change requests. It's now limited to employee-submitted address requests (M4-7).
  - Blocking every login email would have blocked dual-role people like Emma. It now blocks only another person's login (M4-3).
- **Highs:**
  - Emma and Benjo both use the claim path, so a brand-new sign-up is now tested on company 1, and a company 1 subdomain is added (D10, M4-10, M4-12).
  - The gate order contradicted itself, and Emma needs the WISP (§0, §3, §5).
  - There were more readers and writers of `employees.email`, including the time-tracking email matcher (M4-3).
  - The notification audiences and client change-request routes and scoping needed new wiring (M4-7).
  - Full Sign in as needed one company per grant, more forbidden actions, and attribution in `AuditLog.record!` (M4-13).
- **Mediums and lows:**
  - the locked-batch QuickBooks scope, the document table shape, and automated SSN scanning (M4-4);
  - verified-mark meaning (M4-3, M4-2);
  - the M4-9 dependencies;
  - the reverse pending-request collision and initial-entry noise (M4-7);
  - stale text.

**Leon's answers (November 24, after round 2):**

- Decided: D1 (MoSa's admins enter contacts and invite, with Emma first), D4 (MoSa's approves addresses and Cornerstone confirms), D6 (show January–August with the original QuickBooks PDFs), D8, D9 and D10 (no staging, and view-only Sign in as).
- The shared inbox is a mistake to fix (M4-3).
- The full Sign in as is planned in M4-13.
- A read-only production check confirmed Emma's record and the shared inbox's reach (§2).
- Later the same day: the team signs up first, before Emma (D10c); nothing depends on the shared inbox; the QuickBooks PDFs are one per check. Leon approved the plan.

**Round 2 (Gemini 4 Neon, high, re-check of `cac49720`): "ready with fixes."**

- Round 1's blockers and highs were confirmed fixed, with two caveats now addressed: an email-only staging tester slot, and RLS policies staged but not enforced before M3-7 phase 3.
- **New, all fixed in this revision:**
  - D12 overstated what the revocation dispatcher does. It only drops Cable connections, so Clerk sessions are now revoked through Clerk's API.
  - The stub posting trigger relied on payment evidence that can't be recorded in advance, and would have marked normal stubs "Corrected".
  - Sign-up retry and email-collision handling, the bind step's RLS and locking, and where `links` and `links/claim` live and how they're throttled.
  - Google sign-in can't be used for reverification, so it uses an email code.
- **Lead's own find while checking:** the stub prints staff wording ("transfer not confirmed"). Employee copies use an employee-copy option instead (M4-4).

**Round 1 (Gemini 4 Neon, high, November 24, 2026): "ready with fixes."** Every finding was checked against the code and accepted:

- **Blockers, all fixed:**
  - Step-up would have blocked employees with no second factor. Fixed by splitting step-up into two helpers (M4-1).
  - Sign-up had four missing seams: code-only invites with no email, existing logins, the Clerk handoff and bind, and finding links. All are now specified (M4-2).
  - The contact model contradicted itself, and the draft overrode Leon's November 19 decision. Fixed with one contact model (M4-3) and D4 aligned to November 19 (M4-7).
- **Highs, all fixed:**
  - All per-IP limits and the missing CORS on throttled responses (§1.5, M4-2).
  - Staging containment blocking the internal test (§1.5, M4-10).
  - RLS for new tables (standing rule).
  - Switch checks contradicting how subdomains are authorized (M4-9, M4-10).
- **Mediums and lows, all fixed:**
  - Citation fixes (D7, §1.1, §1.3, M4-1).
  - The `requested_by_link_id` design (M4-7).
  - The stub posting and freeze moment (M4-4).
  - PostHog, terms, client agreement, DRT and bounce tracking (M4-5, M4-6, M4-8, G1).
  - New decisions D11 (stub notices) and D12 (revocation).
  - WebKit placement, pagination, and the unavailable screen.
