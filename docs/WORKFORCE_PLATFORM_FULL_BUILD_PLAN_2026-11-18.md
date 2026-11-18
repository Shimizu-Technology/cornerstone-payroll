# HR, time and payroll: the full build

**Status:** Planned. A proposal for Leon and Dafne; no code has changed.
**Date:** November 18, 2026, on Payroll `main` at `705cbb84`.
**Builds on:**
- [HR module: ADP study and build plan](HR_MODULE_ADP_STUDY_AND_PLAN_2026-11-18.md)
- [Platform offerings implementation spec](PLATFORM_OFFERINGS_IMPLEMENTATION_SPEC_2026-11-17.md)
- [Employee portal plan](EMPLOYEE_PORTAL_AND_PLATFORM_PLAN_2026-11-17.md)
- [W-2GU and 1099 year-end plan](W2GU_1099_YEAR_END_FILING_RESEARCH_2026-11-17.md)

Leon asked what it would take to do HR and time tracking properly: not an MVP, not halfway. This document answers that. It also folds in Dafne's November 17–18 emails and gathers every open question in one place.

## Summary

- **The product:** one platform for Guam employers, run with Cornerstone. It covers:
  - payroll
  - people records and HR
  - time and attendance with scheduling
  - leave
  - documents, policies and e-signature
  - onboarding and offboarding
  - compliance and credentials
  - benefits and deductions
  - year-end forms
  - reporting

  Three front doors share one set of records:
  - an employee app on the phone
  - a manager portal for each client
  - the Cornerstone staff console
- **What "properly" means:** every feature is finished for real clients when it ships. It is:
  - correct for Guam
  - secure and audited
  - tested by Cornerstone
  - documented, supportable and sellable

  It does not mean shipping everything at once. The work comes out in releases, and each release is complete for what it covers.
- **The main architecture decision:** build time and attendance into the same multi-tenant platform as HR and payroll. Each client's time app would then stop being its own deployment with a sync connection. AIRE keeps its current system until a move is agreed (§4).
- **How long:** about nine to twelve months of focused work for the full scope, alongside year-end filing, which comes first (§7).
- **What's needed from others:** answers to the questions in §9, especially the commercial ones (who owns, sells, supports and bills the product), the MoSa's pilot details, and legal and compliance confirmations.

## 1. What changed since yesterday

**Dafne's emails, November 17–18:**

| Email | What it says | What it means for the plan |
|---|---|---|
| **"Cornerstone Timekeeping Software"** to Leon, with a Word document | <ul><li>In Cornerstone's own time tracking, "Client" should be the business name, not the client contact's.</li><li>The entry order should be Client → Category → Task → Period (optional) → Comments, replacing "Description". For example: *MoSa's / Bookkeeping / Bank Reconciliation / July 2026*, *SCR / Payroll / Payroll Return Preparation / 3rd Quarter 2026*, *SCR / General Accounting / GRT / November 2026*.</li></ul> | A concrete change to the Cornerstone Tax app (§8). The same Client → Category → Task → Period structure is how the product should handle job and project costing for construction and service clients. |
| **"Cornerstone Payroll Portal"**, an unsent draft to MoSa's | Cornerstone is moving clients onto the portal to upload hours, tip and loan reports and W-4s, run reports and see pay history. | Client-portal adoption is already Cornerstone's direction. The HR features build on a portal clients are starting to use. |
| **"GRT – October 2026"** with Nan (KPI) | Dafne is giving KPI's office portal access. Nan asks to be added so she gets payroll at the same time as Dee, the payroll contact. | Clients need several portal users with their own roles and notifications. Setting up KPI's users is a production change to make with Leon's go-ahead. |
| **"Updated Forms W-9" and "Form 1099 Preparation"** | MoSa's should collect W-9s from everyone it pays for produce, fish and bands. Benjo is identifying 2026 1099 vendors from QuickBooks. | Contractor W-9 collection belongs in the portal: send a request, the contractor fills in a W-9 online, it feeds the 1099s (§3, module P). |
| **Spike's November 1–14 hours** | Hours and tips arrive in an email, including a new hire whose W-4 is still pending. | Onboarding packets and portal intake would replace this. |

The other recent mail (a tax-marketing idea sent to Kami, and a tax-treaty inquiry from a Guam company) is Cornerstone's tax practice, not this product.

## 2. What "properly" means

A feature counts as done only when every line below is true.

1. **Complete for its users:** every role that touches it has what it needs, including employees, client managers, client owners and Cornerstone staff, on phone and desktop.
2. **Correct for Guam:** labels, forms, holidays, the meal and split-shift rules, the pay deadlines, H-2B and year-end filing, checked against the source and confirmed by Cornerstone.
3. **Safe:** permission checks on every record, MFA, sensitive changes approved in Payroll, everything audited, data encrypted, nothing a client shouldn't see.
4. **Effective-dated:** any change to pay, job, deductions, W-4, benefits or policy applies from a date. Past payrolls never change.
5. **Tested:** automated tests, a written acceptance script that Cornerstone (Mark and Benjo) runs on staging, and a pilot with a real client before general release.
6. **Supportable:** in-app help, a help article, an error message that says what to do next, and a staff screen to see and fix the record.
7. **Measurable:** usage and errors are tracked, so we know whether people use it and where they get stuck.
8. **Sellable:** in the price list, the client agreement and the demo.

## 3. The full product, module by module

"Have" means it exists in Payroll or AIRE today. Each module lists everything it needs for real clients.

### A. People and HR records
- **Have:** the employee record with personal and job data, client change requests, document requirements.
- **To build:**
  - effective-dated job and pay history
  - emergency contacts
  - work and personal contacts with verification
  - departments, locations and supervisors (the reporting line)
  - an org chart
  - employment status changes with reasons (hire, rehire, leave, termination)
  - company property issued
  - custom fields per client
  - a full change history on every field

### B. Employee app (phone first)
- **Pay:**
  - every stub, masked by default
  - a plain breakdown (earnings by code with hours and rate, taxes with Guam labels, deductions, tips, deposit)
  - compare two checks
  - YTD
  - PDF download and multi-stub export
  - the hours behind each check
- **Tax forms:** W-2GU and 1099 copies, paperless consent, corrected forms.
- **Profile:** contact details, emergency contacts, bank accounts and W-4. Sensitive changes go to Payroll for approval.
- **Everything else:**
  - time off: balances, ledger, requests, calendar
  - my schedule
  - clock in and out (for time clients)
  - documents and policies to read and sign
  - credentials and their expiry dates
  - onboarding steps
  - a task inbox
  - notifications by channel
  - more than one employer on one login
  - read-only access for former employees
  - languages
- **Native iOS and Android apps** for push notifications, reliable clock-in and a better phone experience, alongside the web app.

### C. Manager and client portal
- **Have:** submissions, reports, employee records, change requests, documents, notification preferences.
- **To build:**
  - approvals in one queue (time off, timecards, missed punches, changes, onboarding)
  - a team calendar
  - who's in now
  - scheduling
  - policy publishing and acknowledgement tracking
  - document requests
  - expiring credentials
  - onboarding and offboarding checklists
  - headcount and turnover
  - PTO liability
  - overtime watch
  - roles within a client (owner, manager scoped to a team or location, payroll contact, view-only), each with its own notifications

  Nan's request is an example of those roles: she and Dee both see payroll.

### D. Time and attendance
- **Have (AIRE):**
  - phone and PIN kiosk clock-in with a GPS radius
  - breaks
  - manual entries
  - pay codes and departments
  - daily and weekly overtime
  - employee corrections with manager review
  - approvals
  - a cutoff lifecycle
- **To build, as a multi-tenant module:**
  - punches with optional photo
  - geofences per location
  - kiosk tablets with an offline queue and signed timestamps
  - missed-punch requests for clock-in and clock-out
  - holidays filled in automatically
  - Guam meal-period and split-shift checks with waivers
  - attendance alerts (late, missed punch, approaching overtime)
  - timecard approval by pay period
  - job, task and project codes for costing (the Client → Category → Task → Period model)
  - a direct feed of hours into payroll with no sync job
  - an imported-hours path for clients on Revel and other POS systems

### E. Scheduling
- shifts by location and role
- templates
- publish and notify
- swaps and open shifts with manager approval
- availability
- labor cost against the schedule
- schedules shown beside the timecard

### F. Leave
- **Policies:** accrual per hour worked or per period, caps, carryover, waiting periods, holiday calendars.
- **The ledger:** carryover + earned/adjusted − taken − scheduled = balance, with definitions.
- **Requests:** hours per day, recurring, a review step, and approval with delegation when the manager is away.
- **Payroll and visibility:** approved leave becomes payroll hours, and balances print on stubs.
- **Other leave types:** unpaid, bereavement and administrative leave.

### G. Documents, policies and e-signature
- document types per client, with retention rules (at least 6 years for wage records)
- employee and employer uploads, malware scanning (must be switched on first) and versioning
- policies with audiences, due dates and acknowledgements that record version, time and device
- e-signature that meets ESIGN, with a stored consent record
- a forms library
- bulk send

### H. Onboarding and offboarding
- **Onboarding:**
  - a packet with personal info, W-4, direct deposit, emergency contacts, policies to acknowledge, required documents and credentials
  - I-9 Section 1, with Section 2 completed by the employer, and E-Verify where the client's contracts require it
  - new-hire reporting to the Attorney General's Child Support Enforcement Division
- **Offboarding:**
  - a checklist covering final pay within Guam's deadlines, PTO payout per policy, property return and access removal
  - former-employee access to stubs and W-2s

### I. Compliance and credentials
- **A Guam rules engine** with each rule's source, effective date and an override recorded with a reason:
  - minimum wage
  - overtime
  - no tip credit
  - the meal period
  - split shifts
  - pay timing
  - deduction authorization
  - retention
- **Credentials with expiry and reminders:** health certificates, licenses, certifications, H-2B ID cards, visas and certifications.
- **H-2B pack:**
  - the Guam DOL monthly report
  - registration and departure dates
  - prevailing-wage floors by trade
  - meals and lodging deductions with signed authorization
  - the §3106 equal-pay check for US workers
- **Certified payroll (WH-347)** for covered projects.

### J. Benefits and deductions
- effective-dated deductions
- plan records (carrier, plan, employee and employer cost, documents)
- enrollment at hire and on life events, with document upload
- dependents and beneficiaries
- an "as of a date" view and cost per paycheck
- retirement elections (already rich, staff-only today) exposed to employees

### K. Payroll links
- every approved change flows into the next unapproved run on its effective date
- approved hours and leave land as payroll items
- garnishments and loans
- direct deposit splits and a pay-card option, if a client wants one

### L. Year-end
- W-2GU, W-3SS, EFW2 for SSA and GuamTax, 1099-NEC and 1099-MISC, 1096 and the Pub 1220 file, W-2c
- employee copies posted and mailed
- a year-end service for employers who keep their own payroll

This is the [year-end plan](W2GU_1099_YEAR_END_FILING_RESEARCH_2026-11-17.md), and its first deadline is February 1, 2027.

### M. Reporting
- standard reports per role
- a report builder with saved filters
- exports to Excel and CSV
- scheduled email reports
- a client dashboard: labor cost, overtime, headcount, PTO liability, expiring credentials

### N. Notifications and messaging
- email, text and push, with verified channels and recorded consent (TCPA for texts)
- per-category preferences
- digests
- bounce handling
- announcements from the client to its employees

### O. Cornerstone staff console
- a view of every client, with health signals (late submissions, pending approvals, expiring credentials, failed notifications)
- support tools: view as, with audit; record fixes
- client setup through the operating profile
- per-client billing (base plus per-employee), invoices and usage

### P. Contractors and W-9s
- send a W-9 request
- the contractor completes and signs it online
- TIN validation where available
- the record feeds 1099s
- reminders to vendors still missing a W-9

MoSa's produce, fish and band payees are the first case.

### Q. Job and project costing
- client or job, category, task and period on time entries, with costing reports
- profitability per client

This serves Cornerstone's own firm (§8), construction jobs and service businesses.

## 4. Architecture for doing it properly

### One multi-tenant platform

Today there are three separate setups:
- **Payroll** serves Cornerstone staff and the client portal.
- **AIRE** is a separate deployment of the time app for one employer, connected to Payroll by a sync protocol.
- **Cornerstone Tax** has its own time tracking for Cornerstone's staff.

The [offerings spec](PLATFORM_OFFERINGS_IMPLEMENTATION_SPEC_2026-11-17.md) keeps time apps separate and plans a second deployment for the next time client.

**Recommendation:** build time and attendance as a module of the same multi-tenant platform. Each client is a tenant with its own settings, branding (logo, colors, its own web address) and data.

| | One platform (recommended) | Separate time app per client |
|---|---|---|
| Employee login | One, across pay, HR and time | One per app, linked by protocol |
| Data | One record of each person, hour and request | Copies kept in step by sync jobs |
| New client | Settings and branding | A new deployment, database and monitoring |
| Cost to run | Shared | Grows with each client |
| Where bugs hide | Inside one codebase | Between two systems |
| AIRE | Keeps its current system until a move is agreed | Unchanged |

The spec's rules still hold:
- offerings are settings
- one HR engine
- sensitive changes approved in Payroll
- AIRE keeps working

This adds one more rule: **time is part of the engine, not a client of it.** The connector protocol stays for AIRE, and for any client that insists on its own time system.

### Foundations every module needs

1. **Identity:**
   - a separate employee identity linked to employee records at one or more clients
   - MFA for everyone
   - passkeys
   - account recovery with checks (spec E1–E2, S1)
2. **Permissions:**
   - roles per tenant (Cornerstone staff, client owner, manager scoped by team or location, payroll contact, view-only, employee)
   - checked on every record, with isolation tests
3. **Effective dating:** one pattern for every dated record, so changes take effect on a date and past runs never change.
4. **Workflow engine:** a request → approver(s) → decision → effective-date flow used by every module, with delegation, reminders and audit. It extends `employee_change_requests` (spec D1–D3).
5. **Audit log:** every view, change, approval and download, with the actor and their role. It must also log actions with no staff user, which today's `Auditable` skips.
6. **Notification service:** channels, consent, preferences, templates, delivery tracking (spec N1, and an SMS provider to choose).
7. **Document service:** storage, malware scanning, versions, retention, e-signature and consent records.
8. **Rules engine:** Guam rules as data with sources and effective dates, not scattered constants.
9. **Import tools:** bring a new client in from QuickBooks exports, spreadsheets or another provider, with a reconciliation report.
10. **Environments:** staging that mirrors production, a demo tenant with fictional data for sales, and seed data for acceptance scripts.

## 5. The quality bar

| Area | Standard |
|---|---|
| Security | <ul><li>MFA required, passkeys supported.</li><li>Sensitive fields encrypted.</li><li>Least-privilege roles; isolation tests between tenants.</li><li>Dependency and secret scanning.</li><li>An outside penetration test before the first client outside Cornerstone's current book.</li></ul> |
| Privacy | <ul><li>Pay masked by default.</li><li>SSNs and bank numbers never shown in full.</li><li>A written privacy policy and data-processing terms for clients.</li></ul> |
| Reliability | <ul><li>Backups with tested restores (the repo already has a restore certification script).</li><li>Uptime monitoring and a status page.</li><li>An incident process.</li></ul> |
| Performance | Pages load in about a second on a phone over island networks. Clock-in confirms in under two seconds, or queues offline at kiosks. |
| Accessibility | WCAG 2.2 AA for the employee app and manager portal. |
| Testing | <ul><li>Automated tests per feature.</li><li>Contract tests between Payroll and AIRE.</li><li>A written acceptance script per release, run by Cornerstone on staging.</li><li>A pilot before general release.</li></ul> |
| Records | Wage and time records kept at least 6 years, plus audit and consent records. |
| Support | <ul><li>A help center.</li><li>In-app help on each screen.</li><li>A support queue with response targets.</li><li>Release notes.</li></ul> |
| Legal | <ul><li>A client agreement.</li><li>Terms of service and a privacy policy.</li><li>E-sign and e-delivery consent text reviewed by Dafne.</li><li>Text-message consent (TCPA).</li><li>Cyber and errors-and-omissions insurance checked.</li></ul> |

## 6. Releases

Each release ships complete for its scope and ends with Cornerstone's acceptance run and a pilot.

| Release | Scope | First users |
|---|---|---|
| **R0: Year-end** | The W-2GU and 1099 engine, EFW2 and the Pub 1220 file, employee PDFs, filing | All payroll clients, by January 31 |
| **R1: Foundations** | Identity and MFA, permissions and client roles, operating profile, audit, workflow engine, notification service, document service with scanning, rules engine scaffold | Cornerstone staff, client users (KPI's Nan and Dee, MoSa's) |
| **R2: Employee app and portal** | Pay (masked, breakdown, compare, YTD, PDFs), W-2GU copies and consent, profile and emergency contacts, documents and policy acknowledgements, credentials, task inbox, manager approvals, contractor W-9s | Cornerstone's own staff, then MoSa's and KPI |
| **R3: Leave** | Policies, ledger, requests, calendar with paydays and holidays, approvals with delegation, leave into payroll, balances on stubs | MoSa's (if it has a policy), others |
| **R4: Onboarding and offboarding** | New-hire packet, e-W-4, direct-deposit changes with verification and the fraud hold, I-9, new-hire reporting, offboarding checklist and final pay | All portal clients |
| **R5: Time and scheduling** | The multi-tenant time module (punches, kiosk with offline queue, geofences, missed punches, meal and split-shift checks, alerts, approvals), scheduling, job and task codes, native iOS and Android apps | The next client that wants its own clock-in |
| **R6: Benefits, reports, construction** | Benefits and life events, the report builder and dashboards, the H-2B pack, prevailing wages, certified payroll, job costing | Construction and larger clients |
| **R7: Year-end service** | Year-end filing for employers that keep their own payroll | Outside employers, for tax year 2027 (January 2028) |

## 7. Timing and effort

- **R0** is fixed by law: filing is due February 1, 2027. It comes first whenever the two compete.
- **R1–R2 by about February–March 2027.** That puts MoSa's and KPI on the employee app in the first quarter, starting with Cornerstone's own staff.
- **R3–R4 by about April–May 2027.** After that, Cornerstone can sell HR to new clients with onboarding included.
- **R5 by about June–July 2027,** for the first new time client.
- **R6 in the second half of 2027.**
- **R7 is built in fall 2027 for January 2028.**

That is nine to twelve months of focused work for the full scope, done by Leon working with agents. The dates assume year-end lands cleanly, Cornerstone runs acceptance scripts within a few days of each release, and the decisions in §9 come early.

Doing it properly costs more than an MVP in three places:
- the foundations in R1, which every later release reuses
- the acceptance and pilot time
- the legal and security work in §5

Those three are also what make the product sellable to businesses that don't already know us.

## 8. Cornerstone's own time tracking (Dafne's feedback)

The Cornerstone Tax app (`cornerstone-accounting.tax/admin/time`) already has most of what Dafne described in its database. The screen doesn't use it yet.

| Dafne asked for | Today | Change |
|---|---|---|
| Client shows the business name | The client list shows each client's first and last name, so a business appears under its contact. Clients already have `business_name` and `client_type`. | Show the business name for businesses and the person's name for individuals; search both. |
| Order: Client → Category → Task → Period → Comments | The form asks Category, then Client (optional), then Description. Category is a flat list, so "Bank Reconciliation" is a category. | Reorder the form. Use the existing `service_types` as Category and `service_tasks` as Task (already linked to time entries). |
| Period (optional) | No such field | Add a period: a month, a quarter or a year, or none. |
| Comments | Called "Description" | Rename it. |
| Reports | By user, category and client | Add task and period, and show hours by client → category → task → period. This answers the CEO's November 2 ask for per-client hours and profitability. |

This is a small, contained change to the Cornerstone Tax app. An earlier note held changes to that app until AIRE was proven on production; Dafne's request is a reason to lift the hold for this change. **Decision for Leon:** go ahead now. Recommended. The task lists and period choices come from the questions below.

## 9. Questions

Answered by the person named. Questions already in the earlier documents are repeated here so this is the one list to work from.

### Business (Dafne)

1. **The product's commercial setup.** Who owns it, who sells it, who supports it, who signs the client agreement, and how is revenue shared between Cornerstone and Shimizu Technology?
2. **Pricing.** What do clients pay Cornerstone for payroll today? Would they pay a per-employee price for HR and time? Should there be a setup fee?
3. **Pilot order and dates.** Cornerstone's own staff first, then MoSa's and KPI? When should MoSa's start, and who at MoSa's owns it (Emma, Sara)?
4. **Who's next.** Which clients and prospects follow, and do any have H-2B workers or federal contracts?
5. **Support.** Who answers employee questions from the app: the client's manager, Cornerstone, or both? During what hours? How much time can Mark and Benjo give to support and to acceptance testing?
6. **Direct deposit.** How are employees paid today: does each client's bank receive a file, or does someone key payments in? This shapes bank-change approvals and whether the product should produce a bank file.
7. **Benefits.** Which clients run health insurance or retirement through payroll, and with which carriers or brokers?
8. **Languages.** Which do client workforces read most comfortably?
9. **The airport.**
   - What W-2 product does it buy, roughly what does it cost, and how many W-2s does it issue?
   - What's painful about it?
   - Has Cornerstone taken advice on the procurement and conflict-of-interest question before any approach?
10. **The product's name,** if it should have one apart from Cornerstone.

### Compliance and legal (Dafne, with an attorney or Guam DOL where noted)

11. **Electronic pay stubs.** Do they satisfy Guam's requirement that the employee get a copy? (Guam DOL Wage and Hour)
12. **Holidays.** Must private employers give Guam's legal holidays off, or pay a premium for them?
13. **Meal waivers.** How do clients record meal-period waivers today?
14. **Retention.** Is 6 years right for every record type, or should Cornerstone keep some longer?
15. **Electronic signatures.** Is an electronic W-4 and I-9 acceptable for every client? Who completes I-9 Section 2 for remote hires?
16. **Year-end filing access.**
    - Does Cornerstone have an SSA Business Services Online login and a GuamTax account?
    - Is it registered with DRT as a payroll processor?
    - Can we have one of last year's ezW2 upload files, to check it was filed as W-2GU?
17. **Contracts and policies.** Who drafts the client agreement, terms of service and privacy policy? Cornerstone's attorney?
18. **Insurance.** Do Cornerstone's policies cover holding client employee data (cyber, errors and omissions)?

### MoSa's pilot (Dafne with MoSa's)

19. **Time off.** Is there a written PTO or sick policy? How does it accrue, and who approves?
20. **Policies.** Which should employees acknowledge: the handbook, the tip pool, others?
21. **Health certificates.** Are health certificates or food-handler permits required? Should they be tracked?
22. **Schedules.** Are they made in Revel or elsewhere? Would MoSa's want them in the app?
23. **Phones and email.** Do most employees have a smartphone and a personal email address?
24. **Tips.** Should employees see tips per period or per shift?
25. **Contractors.** Should produce, fish and band payees complete W-9s through the portal?

### KPI and other portal clients (Dafne)

26. **KPI's roles.** Should Nan and Dee have the same access, or should one submit and the other review? Should both get every payroll notification?
27. **Other clients.** Which other clients should get portal access now?

### Cornerstone's own time tracking (Dafne)

28. **Categories and tasks.** What is the full list of categories and the tasks under each? Your examples include Bookkeeping, Payroll and General Accounting.
29. **Period choices.** Should Period offer month, quarter and year? Tax year too? Is it optional for every category?
30. **Client required?** Should every entry need a client, with an "Internal – Cornerstone" choice for firm work?
31. **Clients that are both.** Are there clients that are both a business and an individual, such as an owner's personal return? How should they show?
32. **Billing.** Should time feed client billing and profitability reports?

### Decisions for Leon

33. **One multi-tenant platform including time** (§4). Recommended.
34. **Native iOS and Android apps in R5,** with the web app first. Recommended.
35. **Go ahead with Dafne's time-tracking change** in the Cornerstone Tax app now (§8). Recommended.
36. **The open decisions from the spec:**
    - close PR #139
    - the text-message provider (ClickSend or Twilio)
    - a separate Clerk app for employees
    - turn on staff and client MFA first
    - bank changes through the portal first
    - contact changes approved after a one-time code
    - the employee app's web address
37. **Year-end before everything else** until filing is done. Recommended.
38. **KPI's portal users.** Set up Nan and Dee on production once Dafne confirms their roles.
