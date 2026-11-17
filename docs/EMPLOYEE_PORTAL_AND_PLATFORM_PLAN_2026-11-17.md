# Employee portal and repeatable client platform: plan

**Status:** Planned. This is a proposal for Leon's decisions in §9. No code has changed.
**Date:** November 17, 2026. References are to `main` at `162dd2ec` (Payroll), `9ace66e5` (AIRE) and `158ebbd` (Cornerstone Tax).

## What we want

1. **Employee portal.** Every client's employees can see their pay, download stubs and W-2s, see their deductions and benefits, view their documents and keep their contact details current, much like Paycom or ADP. For a CPA firm on Guam this sets Cornerstone apart.
2. **Repeatable.** Turning a feature on for a new client is a matter of settings, not code written for MoSa's or AIRE.
3. **Two ways to run a client, both repeatable:**
   - **Connected time.** The client clocks in on our time app (phone and kiosk, as AIRE does), and approved hours flow into Payroll.
   - **Import plus client portal.** The client sends its own reports (MoSa's Revel PDF and workbook, Spike's emailed hours) and its admin works in the client portal.
4. **AIRE keeps working.** Nothing in this plan changes what AIRE sees or does unless a step says so and AIRE's tests cover it.

## 1. Where things stand

### Payroll

**Ready to build on:**

- Firm-and-client tenancy. An Organization (the firm) owns its Companies (the clients). Staff and client users get access to a company through assignments. Every request carries an explicit company header with no silent fallback (`explicit_company_access.rb`).
- Client portal plumbing in `api/v1/client/*`:
  - employees, with change requests that keep sensitive fields encrypted
  - documents, document requirements, threads, file requests and notifications
  - pay periods and client review, pay stubs, about 40 reports
- The HR data an employee would see:
  - profile, effective-dated W-4 elections, direct-deposit details (encrypted)
  - rich retirement elections, deductions, loans with balances, wage rates
  - YTD totals, pay history, `PayStubGenerator`, W-2GU figures
  - document requirements with a review step
- A capability-based time connector with per-source secrets, installation pinning, policy constraints and neutral `time_payroll/*` routes. `docs/TIME_PAYROLL_CONNECTOR_PROTOCOL.md` already describes a "Custom compatible source."
- An intake adapter registry (`PayrollIntake::PreviewService::SOURCE_ADAPTERS`) with the sources each company needs stored in its settings.

**What blocks "repeatable for any client":**

| # | Problem | Evidence |
|---|---|---|
| 1 | **Logins aren't linked to employees.** Nothing connects a login to an employee record. The reserved `employee` role would see the whole company. Each user has one home company, one role and an email that is unique across the system, so one person can't be a client admin at one company and an employee at another, or an employee at two clients. | `user.rb:38,122-162`, `employees` has no user link, `ROLE_PERMISSION_MATRIX_2026-05-14.md:17` |
| 2 | **The client "submit payroll files" journey only works for MoSa's Revel files.** The source name `mosa_revel` also does double duty as the "this row was imported" flag. | `create_revision.rb:27`, `import_bridge.rb:57`, `SubmissionForm.tsx`, `payroll_item.rb:688`, `import_service.rb:22` |
| 3 | **The list of intake sources is fixed in code.** The universal workbook, the hours-source setting and the tip-handling setting (decided Nov 7) aren't built. | `company.rb:10`, `payroll_intake_session.rb:9` |
| 4 | **Connected-time onboarding only finishes for AIRE.** History approval, rollout receipts, category mapping, rate matching and worker statements accept only `aire_services`, and one setup step only runs for company 2. | `history_approval.rb:187-189`, `category_rate_matcher.rb:14-20`, `worker_statements_controller.rb:59`, `aire_category_setup.rb:6` |
| 5 | **Shared code carries AIRE names.** The neutral routes call `Integrations::Aire::*` controllers, and several tables are `aire_*`. | `routes.rb:27-39`, `aire_payroll_calendar/publisher.rb` |
| 6 | **No PTO or benefits model.** PTO exists only as hours on a paycheck, with no policy, accrual, balance or request. Deductions have no effective dates, plan or enrollment. | `schema.rb` (`payroll_items.pto_hours`, `employee_deductions`) |
| 7 | **Client settings are spread across many columns and two JSON blobs**, with no catalog or feature-toggle model. | `companies` table |
| 8 | **Single-firm assumptions.** The bootstrap slug is `cornerstone-tax-services` and a database constraint pins the platform owner's email. This only matters if Payroll is ever offered to another firm. | `clerk_authenticatable.rb:210-214`, `user.rb:7` |

### AIRE

- **Built for one business.** The README calls it "a single-employer workforce/timekeeping application." There's no company column anywhere, and about 150 files say "AIRE". The flight-school website is built in, kiosk routes are `/aire/kiosk/*`, and the Guam time zone and Sunday workweek are written into about 20 files.
- **It always tells Payroll it is `aire_services`** (`integration_profile.rb:9`, `batch_builder.rb:9`). Copying AIRE for a second client therefore fails one of two ways:
  - It keeps that source type, and the second client inherits AIRE's pay calendar, workweek and category rules.
  - It registers as a custom source, and My Pay stops working (Payroll returns 401) and calendar publishing is blocked.
- **My Pay depends on an undocumented contract.** AIRE reads about 40 fields from Payroll's worker-statement response (`my_pay_presenter.rb`). That response has no written contract and no fixture the two repos share, so either side could change it and still pass its own tests. This is the biggest risk to AIRE in the plan.

### Cornerstone Tax

- **Its own time tracking.** Cornerstone Tax has clock-in, schedules and overtime approval, and serves a v1 time summary.
- **The Nov 2 plan.** It makes Tax a second producer of the shared protocol (25–45 days), after AIRE is proven in production and a payroll commit snapshot exists.
- **Overtime gap.** Tax counts daily and weekly overtime, but the protocol is weekly-only.

### The August 23 strategy

`PRODUCT_STRATEGY_AND_PLATFORM_BOUNDARIES_2026-08-23.md` places "PTO, employee/manager self-service" in a future multi-tenant **Workforce** module, built out of AIRE and Tax timekeeping. It says the modules "should share identity, organization/company concepts, permissions… They should not share one unrestricted database."

This plan proposes one change to that decision. Self-service for pay and HR records moves into Payroll; time self-service stays in Workforce. See §3.

## 2. What employees get (from ADP, Paycom, Paychex, Gusto, Rippling and Homebase)

**Table stakes everywhere:**

- pay stubs, pay history and YTD on a phone
- W-2 download with electronic consent
- profile and emergency contacts
- notifications
- MFA
- access for former employees

**Usually on higher tiers or paid add-ons:**

- PTO balances and requests
- a time clock
- document e-signatures and handbook acknowledgment
- direct-deposit self-edit with fraud checks
- benefits enrollment
- earned wage access, which always runs through a licensed partner

**What it costs elsewhere:**

- Stubs and W-2 access are included in every vendor's base price.
- Time tracking and PTO are where vendors charge: roughly **$6–12 per employee per month**, or about $30–120 per location for Homebase.
- Gusto's published plans are $49 + $6, $80 + $12 and $180 + $22 per month (base + per employee). These come from third-party sources.

**Where a firm-run Guam portal can stand out:**

1. **One login across every Cornerstone client.** Plenty of people on Guam hold two jobs. Gusto manages this only when both employers use Gusto.
2. **Guam-correct by default.** W-2GU, no state-tax clutter, and the Guam DOL deduction disclosure on every stub.
3. **A named person at Cornerstone answers.** "Message Cornerstone" reaches a real preparer, not a call center.
4. **Tax season tie-in.** The W-2GU flows straight into a tax-prep appointment with the same firm.
5. **Local languages** later, such as Tagalog and Chuukese, if clients ask for them.

**Rules we have to follow:**

- **W-2 e-delivery** (26 CFR 31.6051-1(j)). The employee consents electronically and in advance, after the required disclosures. The notice email's subject line reads "IMPORTANT TAX RETURN DOCUMENT AVAILABLE". If that email bounces, a paper notice follows within 30 days. The form stays posted through October 15 of the next year (the next business day if that falls on a weekend or holiday). A corrected W-2 stays posted through that date or 90 days after it is posted, whichever is later. Paper is the default for anyone who hasn't consented. Guam follows the same rule through its mirror code (inferred; confirm with DRT).
- **Electronic W-4** (31.3402(f)(5)-1). The system must reasonably confirm the signer is the employee, include the perjury statement, and make the e-signature the final entry.
- **Guam pay statements.** The DOL poster says employers "must show, on a check stub or pay statement, all deductions taken… and a copy of it must be given to the employee." Whether an electronic stub counts as "given" is not confirmed. Until it is, paper stays available.
- **Record retention.** Guam requires wage records for at least 6 years (17 GAR §4104), the IRS 4, FLSA 3. Design for 6+ years.
- **Accessibility.** Aim for WCAG 2.1 AA.

## 3. The proposed architecture

### Principle: Payroll owns people and pay; time apps own clocking

```text
                    ┌──────────────────────────────────────────────┐
                    │                 Cornerstone Payroll           │
                    │  system of record: people, pay, tax, W-2GU,   │
                    │  deductions, benefits, PTO balances, HR docs  │
                    │                                               │
 Staff console ───▶ │  admin/*      (Cornerstone staff)             │
 Client portal ───▶ │  client/*     (client admins, e.g. Emma)      │
 Employee portal ─▶ │  employee/*   (one person's own records only) │
                    │                                               │
                    │  Employee Pay service  ◀── one implementation │
                    │      ▲               ▲     for stubs/pay/W-2  │
                    └──────┼───────────────┼───────────────────────┘
                           │               │ worker statements API
                           │               │ (versioned contract)
                 employee portal     ┌─────┴──────────────┐
                 (web, phone-first)  │ Time apps          │
                                     │ AIRE, Workforce,   │──▶ hours via
                                     │ Cornerstone Tax    │    time_payroll
                                     └────────────────────┘    protocol
```

- **Payroll is the system of record** for everything about a person's pay and employment: profile, W-4, direct deposit, deductions and benefits, PTO balances, documents, stubs and W-2s.
- **Time apps** (AIRE today, later a shared Workforce app and Cornerstone Tax) own punches, schedules, time approvals and leave *requests*. They send hours to Payroll and never calculate pay.
- **One internal Employee Pay service** produces a worker's statements, pay history, YTD and tax forms. The new employee portal and AIRE's My Pay both read from it, so a pay stub can't differ between the two apps.

This changes the August 23 strategy, which put self-service in Workforce. Workforce doesn't serve multiple businesses yet and doesn't hold pay data, while Payroll does both. Time self-service (clock-in, schedules, leave requests) stays with Workforce.

### Employee identity: a separate login, linked to employee records

Don't reuse staff and client `users`. Add:

- **`EmployeeAccount`:** one per person.
  - It holds the login (Clerk), the verified personal email and phone, MFA state and consent records.
  - It never gets a staff or client role, and admin and client code never accepts one.
- **`EmployeeAccountLink`:** the account, the company and the employee record, with a status (invited / active / former / revoked) and the dates.
  - One person can link to employee records at several Cornerstone clients. That gives us the multi-employer switcher.
- **`api/v1/employee/*` under an `Employee::BaseController`:**
  - It works out the employee record from the signed-in account and the chosen link, **never from a URL or a parameter.**
  - Each query is scoped to that one employee and company.
  - There is no reuse of `accessible_company_ids`.
- **Separate sign-in:** its own site and sign-in screen, and preferably its own Clerk instance.
  - That allows employee-specific policies: phone OTP for workers without email, a longer life for former employees, a different session length.
  - It also means an employee session can never reach staff code paths.
- **Two logins when someone is both:** a client admin who is also that client's employee (Emma may be) has two separate logins. A shared Clerk instance with role switching is possible, but it's riskier; ADP has the same split.

**Activation, following ADP's pattern:**

1. Cornerstone or the client admin sends an invite from the employee record.
2. The employee confirms two facts on file: normally date of birth and the last four digits of the SSN.
   - **When those aren't on file** (a missing DOB or SSN, or a business contractor identified by an EIN), use another check: the EIN's last four plus the ZIP code on file, or a one-time activation code that Cornerstone or the client admin hands over in person or prints on a stub. Staff record which method was used.
3. They verify a code sent by email or text.
4. They set up MFA.
5. They're asked to add a personal email, which keeps working after they leave the job. It's recommended, not required: a verified phone-only account is allowed. Phone-only accounts get W-2 and 1099 notices by paper where e-delivery rules require it.

**Termination:** when the employee is terminated in Payroll, the link becomes *former*. Former employees keep read-only access to stubs and W-2s for the retention period (6 years) and lose everything else.

### Settings that make it repeatable

Gather each client's operating choices into one typed **client operating profile**, with a catalog of settings that each carry help text, like AIRE's settings catalog:

- **Hours source:**
  - a connected time app (which source)
  - an intake adapter (Revel PDF, universal workbook, emailed hours)
  - manual entry
  - salaried only
- **Intake details:** the adapter's required files, how tips are handled (paid in the check, or reported as already paid), and whether the workweek is aligned.
- **Client portal:** on or off, who may upload, who may edit what, the "Cornerstone reviews first" switches, and who gets notifications.
- **Employee portal features:** stubs, W-2 e-delivery, profile edits, documents, PTO, direct-deposit edits, each on or off with a default, plus any client-specific wording.
- **Year-end:** kind of employer and filing contacts (see the W-2GU plan).

New capabilities are switched on through this profile, never by checking a client's name, company id or source type.

### Intake made generic (the MoSa path for any client)

- **Each intake adapter describes itself:** its name, the files it needs and their types, how they're parsed, how rows are matched to employees, and the warnings it raises. The client "submit payroll files" form and the staff import read that description and render from it. Neither hard-codes the Revel PDF.
- **Separate the "imported" flag from the source name.** Today `import_source == "mosa_revel"` also means "this row was imported." Change that to a plain imported flag plus the source.
- **Build the universal Cornerstone workbook** (decided Nov 7). It's one generated workbook per client and pay period, keyed by employee ID, and new clients use it by default.
- **Keep MoSa's Revel adapter**, since Leon decided the Revel PDF stays supported.

### Connected time made generic (the AIRE path for any client)

**On the Payroll side:**

- **Capabilities instead of source-type checks.** Accept any source that advertises the matching capability (`worker_statements_v1`, `category_mapping_v1`, `history_rollout_v1`), not just `aire_services`. AIRE keeps its current behavior because it advertises, or defaults to, the same capabilities.
- **Remove the company-2 condition** from `AireCategorySetup`.
- **Rename gradually.** Neutral controller and service names, with the old `aire_*` names kept as aliases. No table renames until there's a reason.
- **Write the contracts down.** Document the worker-statement endpoint in the connector protocol, add a fixture the two repos share (like the existing cutoff JSON), and check the installation ID on statement calls once AIRE sends it.

**On the time-app side** (AIRE's codebase, for the next own-clock-in client):

- **White-label readiness:**
  - source type and installation identity set by environment, defaulting to `aire_services` for AIRE
  - advertised policy constraints
  - one setting for time zone and workweek
  - the public website behind a feature flag
  - neutral kiosk routes, keeping the AIRE aliases
- **Rollout:** the next one to three clients each get their own deployment (database, Clerk, secret).
- **Long term:** one Workforce app that serves many businesses, combining AIRE's and Tax's timekeeping, as the August strategy proposes. That's a large change touching about 50 tables, so it waits until enough clients justify it.

## 4. Employee portal features by phase

### Phase 1: pay and tax forms (the MVP)

- **Sign-in:** invitation, identity check, MFA, personal email.
- **Employer switcher:** for anyone who works at more than one client.
- **My pay:**
  - a phone-friendly view of each check: gross, taxes, deductions, net and YTD
  - the PDF stub, the same file staff print
  - a notice when a new stub posts
- **Pay history:** with filters by year.
- **Tax forms:**
  - W-2GU and 1099 copies posted. Paper still goes out as required.
  - Electronic-only delivery for employees who consent, with every required disclosure stored by version and time.
  - The required notice email, bounce handling and corrected-form notices.
- **My info:** profile and contact details shown, and changes go in as change requests through the existing review process.
- **Former employees:** read-only access.
- **Audit:** every sign-in, view and download recorded in the Activity history for that client.
- **Cornerstone side:** settings per client to turn it on and choose the features, plus invite tools in staff and client employee records.
- **Pilot:** Cornerstone's own employees (company 1), then MoSa's.

Tax year 2026 W-2s will be furnished on paper either way. Consent has to come before electronic-only delivery, so the portal can post a copy of the 2026 W-2 alongside paper, and electronic-only delivery starts with the 2027 forms.

### Phase 2: HR basics

- **PTO:**
  - Payroll owns the rules (accrual per hour or per pay period, caps, carryover), a ledger and the balance on each stub.
  - Employees request time off in the portal, or in the time app for connected clients, which pushes the request through the protocol.
  - The client admin approves in the client portal.
- **Documents:**
  - the employee's own documents
  - handbook and policy acknowledgments with e-signature
  - uploading a requested document, such as a new ID or a signed form
- **Electronic W-4** that meets the IRS rule, feeding the effective-dated W-4 elections. Cornerstone reviews it before it takes effect.
- **Direct-deposit change request with fraud checks:**
  - a fresh MFA check before submitting
  - alerts to the old and new email and phone
  - the change applies only from the next payroll not yet approved
  - Cornerstone or the client approves it
  - It's held until all of this exists, because changing deposit accounts is the most common payroll fraud.
- **Benefits view:** what the employee has elected and the deductions taken, the plan name and carrier contact, and summary PDFs. Needs effective-dated deductions and a light plan model.

### Phase 3: onboarding and extras

- **New-hire self-onboarding:**
  - personal info, W-4, direct deposit, I-9 Section 1 and documents, all through the employee portal
  - the employer completes I-9 Section 2
  - this replaces part of today's client-side new-hire intake
- **Native app wrapper** for push notifications, if the installable web app falls short.
- **Languages.**
- **Earned wage access** through a partner, only if clients ask for it and after a contract and regulatory review.

### Not planned

- Employees approving their own paycheck before payroll runs (Paycom's "Beti"). This doesn't fit a firm-run payroll.
- Full benefits enrollment administration. Only if a client brings in a broker plan.

## 5. AIRE: what must not break

**The guardrail:** none of the following changes without a contract test in both repos:

- the `aire_services` behavior: default capabilities, fixed calendar, category rules, AIRE headers
- the worker-statement JSON and PDF
- `time_tracking_employee_mappings.source_user_uuid`
- the shared-secret and installation-ID checks
- idempotent events and `cutoff_change`

**How the plan protects it:**

1. **The shared contract comes first.** Before any refactor, add a worker-statement fixture that both repos test against, and document it.
2. **The Employee Pay service is extracted behind the existing endpoint.** The endpoint's output must match the fixture byte for byte.
3. **Capability gates are added beside the existing `aire_services` checks before those checks are removed.** AIRE's live descriptor must advertise, or default to, every capability.
4. **AIRE's My Pay stays where it is.** Whether AIRE workers should move to the employee portal later is a separate decision (§9.3).

## 6. Order of work

The W-2GU and 1099 work comes first, because it has a legal deadline of February 1, 2027.

| Track | Now – Jan 2027 | Feb – Apr 2027 | Later |
|---|---|---|---|
| Year-end forms | W-2GU/EFW2/1099 plan, steps 0–5 | W-2c, e-delivery hookup | |
| Protect AIRE | Worker-statement contract + shared fixture | Employee Pay service extraction | |
| Repeatability | Client operating profile (catalog); capability gates; remove company-2 guard | Intake adapter descriptors; generic client submission; universal workbook | Neutral renames |
| Employee portal | Identity and design spec, Leon's decisions | Phase 1 MVP, pilot on Cornerstone staff, then MoSa | Phases 2–3 |
| Own clock-in product | AIRE white-label readiness (only if a client is waiting) | Second client deploy | Multi-tenant Workforce; Cornerstone Tax joins |

**Rough size:**

- Phase 1 of the portal: about 4–6 PRs, roughly 4–6 weeks including QA.
- Intake generalization: about 3–4 PRs.
- Connected-time generalization: about 2–3 PRs.
- AIRE white-label readiness: about 2 PRs.

These are estimates, not commitments.

## 7. Packaging (for Cornerstone to decide)

| Tier | Includes |
|---|---|
| Included with payroll | Employee portal Phase 1: stubs, pay history, W-2GU/1099, profile |
| HR add-on | PTO, documents and acknowledgments, e-W-4, direct-deposit changes, onboarding |
| Time add-on | A connected time app with phone and kiosk clock-in, approvals and hours flowing into payroll |

The market charges for time and PTO, not for stubs and W-2s.

## 8. Questions for Cornerstone

1. Which clients want the employee portal first? Is a pilot with Cornerstone's own employees, then MoSa's, acceptable?
2. Do any clients offer health insurance or other benefits through payroll deductions? Through which carriers or brokers?
3. Which clients have a written PTO or sick-leave policy, and how are balances tracked today?
4. Do clients expect paper stubs to continue for everyone, or only for employees who don't use the portal? (Guam DOL's position on electronic stubs is unconfirmed.)
5. Who answers employee questions from the portal: the client admin, Cornerstone, or both?
6. Which languages do client workforces need?
7. Any clients interested in a time clock (phone or kiosk) like AIRE's?

## 9. Decisions for Leon

1. **Self-service for pay and HR records lives in Payroll,** with time self-service in Workforce and time apps. Recommended. This amends the August 23 strategy.
2. **Employee logins are separate from staff and client logins.** Each account can link to records at several clients and has its own sign-in site. Recommended.
3. **AIRE workers keep My Pay in AIRE,** fed by the same Employee Pay service. Recommended for now; revisit once the portal is live.
4. **The next own-clock-in client gets a separate deployment** of the white-labeled AIRE codebase, with a multi-tenant Workforce as the long-term goal once there are about three such clients. Recommended.
5. **Pilot order:** Cornerstone's own employees, then MoSa's. Recommended.
6. **Sequencing:** year-end forms, then the AIRE contract, then repeatability, then portal Phase 1. Recommended.

## Sources

Code evidence is cited inline above.

Regulatory and market sources:

- 26 CFR 31.6051-1(j): <https://www.govinfo.gov/content/pkg/CFR-2023-title26-vol17/pdf/CFR-2023-title26-vol17-sec31-6051-1.pdf>
- 26 CFR 31.3402(f)(5)-1: <https://ecfr.io/Title-26/Section-31.3402(f)(5)-1>
- Guam DOL FLSA poster: <https://dol.guam.gov/wp-content/uploads/GDOL-FLSA-Poster-as-of-2.16.2026.pdf>
- Guam DOL food and beverage flyer (17 GAR §4104 records): <https://dol.guam.gov/wp-content/uploads/Flyer-for-Food-Beverage-Industry-2.16.2026.pdf>
- ADP registration best practices: <https://support.adp.com/netsecure/pages/pub/docs/9.0/en_us/ADP_Registration_Best_Practices.pdf>
- Paycom employee self-service: <https://www.paycom.com/our-solution/employee-self-service/>
- Gusto bank-change protection: <https://support.gusto.com/article/137880230100000/Edit-bank-and-personal-information-for-US-employees-and-contractors>
- Gusto multiple profiles: <https://support.gusto.com/article/106622133100000/Switch-between-Gusto-profiles-and-accounts>
- Homebase time clock: <https://joinhomebase.com/time-clock/>
- IRS employment tax recordkeeping: <https://www.irs.gov/businesses/small-businesses-self-employed/employment-tax-recordkeeping>

Related:

- [W-2GU and 1099 year-end filing plan](W2GU_1099_YEAR_END_FILING_RESEARCH_2026-11-17.md)
- [Product strategy and platform boundaries](PRODUCT_STRATEGY_AND_PLATFORM_BOUNDARIES_2026-08-23.md)
- [Time payroll connector protocol](TIME_PAYROLL_CONNECTOR_PROTOCOL.md)
- [Client portal and Guam compliance plan](CLIENT_PORTAL_AND_GUAM_COMPLIANCE_PLAN_2026-04-25.md)
