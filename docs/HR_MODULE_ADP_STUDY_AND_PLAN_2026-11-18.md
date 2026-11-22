# HR module: ADP study and build plan

**Status:** Planned. This is research and a proposal; no code has changed.
**Date:** November 18, 2026. Code read on Payroll `main` at `cdc5bde9` and AIRE `main`.
**Builds on:**
- [Employee portal and platform plan](EMPLOYEE_PORTAL_AND_PLATFORM_PLAN_2026-11-17.md)
- [Platform offerings implementation spec](PLATFORM_OFFERINGS_IMPLEMENTATION_SPEC_2026-11-17.md)
- [W-2GU and 1099 year-end plan](W2GU_1099_YEAR_END_FILING_RESEARCH_2026-11-17.md)

## What changed

Dafne and Leon want an HR module as a product, not only an add-on to the employee portal. The plan:

- **MoSa's pilots it soon.** They have asked for it.
- **Cornerstone sells it to other Guam businesses from early 2027,** including construction.

Dafne's reasons:
- **Little choice on Guam.** She found no real alternative to QuickBooks for payroll until we built ours. She expects other businesses have the same trouble finding HR software.
- **Year-end W-2s are a separate pain.** The airport (where she is in charge now) buys a separate product just for W-2s.

The team to test it is in place: Dafne, Mark and Benjo at Cornerstone, with MoSa's as the first client.

To learn what a mature product gives employees, Leon asked for a read-only study of ADP Workforce Now. He has an employee login there through Bank of Guam (BOG), which also uses ADP for non-exempt clock-in. Sections 1 and 2 cover that study. Section 3 compares it with what Payroll and AIRE do today. Section 4 covers the market and Guam rules. Sections 5 to 11 are the proposal.

## How the ADP study was done

- **Read-only.** Every Myself, Resources and header page was opened in Leon's existing Chrome session on November 18, except the outside discounts site and Support Requests. Nothing was saved, submitted, acknowledged or changed. Forms were opened only to see their fields, then closed without input.
- **No personal data recorded.** No pay amounts, IDs, account numbers, contacts or coworker details went into this document. ADP's own "Hide My Pay" masking stayed on.
- **What it can't show:**
  - **The manager and HR-admin side.** Leon's account has no direct reports and no practitioner role.
  - **The hourly punch flow.** Leon is salaried exempt, so the timecard shows hours entry, not punches. BOG's non-exempt staff punch through the ADP mobile app; BOG's quick links include "Missed Punch Edit Request" and "Supervisor Functions" guides.
  - **The ADP mobile app** itself.

## 1. What ADP gives an employee

**Navigation.** There are three top tabs:
- **Home**
- **Resources:** Company Policies and the Forms Library.
- **Myself:** grouped into My Information, Talent, Employment, Pay, Time & Attendance, Time Off and Benefits.

A header bar on every page has search, Things to Do, Calendar, ADP Assist (AI chat) and the user menu.

| Area | What the employee sees and can do |
|---|---|
| **Home** | Tiles that the employer arranges and brands: the company mission, My Time, Things to Do, quick actions (update tax withholding, payment options, profile), quick links curated by the employer (guides, forms, policies), My Pay (masked), My Benefits, time-off balances with a Request button, calculators, discounts and recognition. |
| **Pay & Tax Statements** | <ul><li>**Hide My Pay** is on by default, with a Show toggle the employee can set.</li><li>The list shows each check's date, gross, take-home and hours, with a year filter.</li><li>**Details:** a donut chart (taxes / retirement / take-home as a share of gross). Expandable sections cover earnings by code with units and rate, each tax, retirement and where the money was deposited, plus PTO balance. Each section links to a calculator (paycheck, tax withholding, retirement).</li><li>**YTD:** year-to-date totals.</li><li>**Compare:** any two statements side by side, with increase or decrease by category.</li><li>**View statement:** download the current one (recommended), view it, or export several.</li><li>**Tax Statements:** W-2s by year and employer.</li><li>**Go Paperless:** opt in to electronic delivery.</li></ul> |
| **Tax Withholdings** | <ul><li>The W-4 status, with Edit.</li><li>The history of certificates on file.</li><li>For Guam it says "Guam doesn't charge income tax. There is no form to complete." See §2.</li></ul> |
| **Payment Options** | The employee can add and edit deposit accounts directly. Each account shows its type, masked routing and account numbers, and the deposit amount ("Full" on Leon's; the field suggests split deposits are possible). There is also a pay-card (Wisely) section, which showed an error. |
| **Profile** | <ul><li>Personal info, with a **Verified** badge on the phone.</li><li>Emergency contacts: add, edit, delete, with relationship.</li><li>Work info: hire date with tenure, supervisor, badge, pay class.</li><li>Credentials: education, skills, licenses and certifications, training, languages.</li><li>Company property issued.</li><li>Pay info, masked behind Show checkboxes.</li></ul> |
| **My Documents** | <ul><li>The employee's document list, with filters and export as ZIP or PDF.</li><li>Upload, either as read-only or as a document set up for e-signature and fill-in.</li></ul> |
| **Company Policies** | <ul><li>Policy PDFs with a due-date column (none of BOG's had a due date) and a pending or completed status.</li><li>Leon has 54 pending and 125 completed acknowledgements; they also appear in Things to Do.</li></ul> |
| **Forms Library** | The employer's forms by category: benefits forms, payroll authorizations, career. |
| **Time off** | <ul><li>Balances per policy as of any date. BOG's policies include PTO, mental-health time off, an extended leave bank, unpaid leave and miscellaneous leave.</li><li>A **balance equation** in plain words: carryover + earned/adjusted + future earned − taken − scheduled = balance. Each term has a definition.</li><li>A **transaction ledger** with a running balance.</li><li>The request list with filters.</li><li>A side-panel request form: dates, policy, reason code, start time, hours per day, recurring, "add more time off", then a Review step before Submit.</li><li>"Balances do not include pending requests" is stated plainly.</li></ul> |
| **Calendar** | <ul><li>Month, week or day views, for the employee or their peers.</li><li>Shows paydays, holidays and time off.</li><li>Select dates on the calendar, then Request time off.</li><li>A balances panel alongside.</li></ul> |
| **Holiday list** | The previous, current and next year. It includes Guam holidays (Liberation Day, All Souls' Day) and the employer's administrative leave days. |
| **My Timecard** | <ul><li>A pay-period grid: each day with pay code, hours and department, and regular / overtime / non-worked columns.</li><li>Week and pay-period totals.</li><li>Holidays filled in automatically and flagged "Supervisor Approval Required".</li><li>Tabs for Totals (by pay code or week, with dollars shown or hidden), Schedule, Supplemental Pay Codes and Time Off Balances.</li></ul> |
| **Benefits** | <ul><li>Coverage as of any date, cost per paycheck and a downloadable enrollment summary.</li><li>Each plan with carrier, coverage, effective date and cost, plus waived plans with the reason.</li><li>Qualifying life events (new child, marriage, lost other coverage) with document upload.</li><li>Dependents and beneficiaries with percentages.</li><li>Year-round enrollments.</li><li>"Items to review annually": address and emergency contacts, tax withholding.</li></ul> |
| **Things to Do** | One inbox in three tabs: Tasks (for example policy acknowledgements), Notifications, and History of completed tasks. |
| **Preferences** | <ul><li>Password, user ID, **passkeys**.</li><li>Verified personal mobile with an explicit consent to text and voice alerts.</li><li>Notification email.</li><li>A **notification matrix:** attendance, timecard and meal-break alerts, each by push, email or in-app.</li><li>Hours display format.</li><li>Terms and consents.</li></ul> |
| **Other** | Org chart with direct-report counts and export; internal job postings, applications and referrals; recognition with points; surveys (errored); salary and hourly paycheck calculators and a W-4 assistant; employee discounts. Sign-in is through BOG's Okta (Okta Verify for MFA). |

## 2. Lessons from ADP

### What to copy

1. **Privacy first on pay.** Masking by default protects people checking pay on a shared screen or at work. It costs little and builds trust.
2. **Explain the money.** The donut chart, plain category names, units × rate, and "Compare" answer the most common employee question: why is this check different? It saves Cornerstone phone calls.
3. **Show the arithmetic for balances.** The time-off equation and ledger make a balance checkable. Disputes about PTO usually come from balances nobody can trace.
4. **As-of dates everywhere.** Balances and benefits can be viewed on any date, so past and future are both answerable.
5. **One task inbox.** Acknowledgements, requests and notices all land in Things to Do, with history kept.
6. **The employer curates content.** The mission banner, quick links, forms and policies are set by each employer without code. This is how one product serves many clients.
7. **Paydays and holidays on the calendar,** right next to time-off requests.
8. **A review step before submit** on requests.
9. **Verified contact channels and explicit text consent** before sending alerts.
10. **Per-channel notification choices,** including timecard and meal-break alerts for hourly staff.

### Where ADP falls short, and where we can win

1. **Guam is an afterthought.**
   - The tax page tells a Guam employee that Guam has no income tax.
   - The Guam territorial income tax withheld is labelled "Federal Income Tax".
   - Guam employers file W-2GU with both SSA and DRT; a product that names and handles Guam correctly is easy to explain to Guam businesses.
2. **Slow.** Pages took 10 to 30 seconds to fill in during the study.
3. **Errors.** Surveys and the pay-card section failed, and Total Rewards was empty.
4. **The same data lives in several places.** Address and contacts sit under Profile, Personal Info, Preferences, and Benefits → Manage personal information.
5. **Noise.** 54 policy PDFs pending with no due dates. Volume without priority teaches people to ignore the inbox.
6. **Bank accounts are edited straight from the page.** The study didn't open Edit, so any check behind it is unknown. Our planned approval queue with verification and a hold (spec §6) puts a person in the loop for the change payroll fraud most often targets.
7. **Distance.** ADP is a vendor portal; questions go to the employer's HR. Our product comes with Cornerstone, a local firm that already runs the payroll.

## 3. Where our apps stand against ADP

From a read-only code audit of Payroll and AIRE on November 18, 2026.

| ADP capability | Status | Where |
|---|---|---|
| Pay statement detail | **Partial** | The stub has earnings with hours, rate and YTD, taxes, deductions and employer contributions (`api/app/services/pay_stub_generator.rb`). AIRE workers see it in My Pay with PDF and email. Payroll has no employee view yet. Missing: deposit split, compare, hide my pay, multi-PDF export. |
| W-2GU online, paperless consent | **Planned** | Year-end aggregates exist; employee copies and consent are spec E4. |
| W-4 self-service with history | **Partial** | Effective-dated W-4 history exists (`employee_w4_elections`), staff only. e-W-4 is spec F3. |
| Direct deposit self-service | **Missing** | One account per employee; no split or pay card. Spec D4 plans payment accounts with fraud holds. |
| Profile | **Partial** | Personal and job data plus client change requests exist. Missing: emergency contacts, phone verification, credentials, company property. |
| Documents, policies, forms | **Partial** | Client documents and document requirements with review exist. Missing: employee visibility, e-signature, policy acknowledgements, forms library. |
| Time off | **Partial (AIRE)** | AIRE has requests, approvals, undo and self-approval blocking (`aire-services/backend/app/models/leave_request.rb`). Missing everywhere: balances, accrual ledger, hours per day, a calendar with paydays and holidays, and any link to Payroll. |
| Benefits | **Missing** | Deductions have no effective dates, plans or enrollments. |
| Timecard | **Built / partial (AIRE)** | Punches, breaks, manual entries, pay codes and departments, daily and weekly overtime, schedules, employee corrections with manager review, attendance status. Missing: holiday auto-fill, meal-break alerts, supplemental pay codes. |
| Task inbox, notification preferences | **Partial** | AIRE has a supervisor "Needs attention" list and cutoff reminders. Payroll has email preferences for client users. No push, SMS or text consent. |
| Org chart, holidays, recognition, jobs, surveys | **Missing** | — |
| MFA, separate employee identity | **Partial / planned** | MFA evidence checks exist; employee identity is spec S1/E1. No passkeys. |
| Mobile | **Partial** | Both apps are installable web apps; no native app. |
| Manager side | **Built (AIRE)** | Approvals, timecards, leave approvals, approval groups, team management. |
| Kiosk, geofence, photo, offline | **Partial (AIRE)** | PIN kiosk with lockout and device sessions, and a GPS radius check. No photo capture. Offline punches are refused on purpose. |
| Onboarding, offboarding | **Partial** | Payroll has client new-hire intake and document readiness; AIRE has a termination preview. No I-9 or self-onboarding. |
| Year-end forms | **Partial** | W-2GU and 1099-NEC aggregates, preflight and filing records exist. Missing: official employee copies, W-3SS, EFW2, 1096, Pub 1220 file, 1099-MISC, W-2c. Due February 1, 2027. |

**Where AIRE already beats ADP:**
- **Hours behind each check.** My Pay lists the shifts behind each statement (`source_entries`). ADP doesn't show this.
- **A settings catalog** with plain-language help for each setting (`settings_catalog.rb`), a good model for client HR settings.
- **Stubs without a login,** by kiosk request or a one-time emailed link.
- **Approvals people can trust:** undoable approval batches, optimistic locking, self-approval blocked, and the employee's original value kept when a correction is rejected.
- **A cutoff lifecycle:** reminders, acknowledgements, lock and late-hours handling.
- **Phone-first error guidance,** for example when location is blocked.

**The gaps that block a multi-client HR module:**
1. **No employee identity in Payroll.** No login links to an employee record. Everything self-service waits on this (spec S1, E1–E3).
2. **No HR data model:** PTO policies and ledger, effective-dated deductions and benefit plans, multiple bank accounts, emergency contacts, policies and acknowledgements, credentials with expiry dates.
3. **Leave lives only in AIRE** and never reaches Payroll, but Payroll is meant to own balances. The bridge needs designing (spec F1).
4. **AIRE serves one employer:** no company column, the source type is fixed, and the Guam time zone and Sunday workweek are hard-coded (spec C5, W1–W2).
5. **No consent or notification foundation:** no e-delivery consent records, SMS or OTP, or push (spec N1, E4).
6. **The worker-statement contract between the two apps has no shared test fixture** (spec C1).

## 4. The market and Guam's rules

Web research from November 18, 2026. Numbers in brackets refer to the sources at the end. Points marked *unverified* could not be confirmed and are worth asking Cornerstone or the agency about.

### Guam is underserved

- **QuickBooks doesn't cover Guam.**
  - Intuit's own support says QuickBooks Online Payroll is not available in Guam [1].
  - QuickBooks Desktop can't e-file Guam W-2s [2].
  - This matches Dafne's experience.
- **The big US providers don't show Guam support.** No published W-2GU support was found for ADP, Paychex, Gusto, Rippling or Paylocity (*unverified*; BOG uses ADP, so ADP does serve Guam employers in some form) [3].
- **Local options are outsourcing, not self-service software.**
  - FIS Corp in Tamuning runs payroll for private companies and local government [4].
  - A few local firms and remote employer-of-record companies offer payroll or HR outsourcing [3][5].
  - No local company offering employee self-service HR software was found (*unverified*).
- **The airport.** No W-2 or payroll-software purchase showed up in GIAA board minutes or notices. The closest items:
  - a 2020 timekeeping and attendance policy [6]
  - a shared application-support RFP for GWA, GPA, the Port and GIAA that names no applications [7]

  The Government of Guam's Department of Administration moved to a new HR and payroll system in February 2024 [8]. Dafne will know what the airport actually buys.

### What competitors charge and what users complain about

| Product | Price (per employee per month unless noted) | Users like | Users dislike |
|---|---|---|---|
| ADP Workforce Now | Not published; third parties estimate about $23–30 for software, $27–48 with more modules, plus $1,000–5,000 setup (low confidence) [9] | The full suite | Support, a confusing interface, reporting; slow mobile app and missed punches [10] |
| Paycom | Quote only; about $25–36, plus per-run and per-check fees in one public contract [11] | Beti cuts pay corrections | Hidden fees, uneven support [11][12] |
| Paylocity | Quote only; about $22–33 plus setup [13] | Ease of use | Support, year-end fees [13] |
| Gusto | $49 + $6 up to $180 + $22; time tracking $6 more [14] | Simple tax filing | Slow fixes for tax errors [15] |
| Rippling | About $8 + $35 base, $15–35 with modules [16] | Everything in one place | Cost grows with modules, setup [12] |
| BambooHR | $10–25 [17] | Clean interface, support | Reporting, customization [12] |
| Homebase | Free to 10 employees at one location; $30–120 per location [18] | Scheduling, time clock | Clock-in bugs, payroll support [19] |
| When I Work | $2.50–8 per user; time clock costs extra [20] | Scheduling | Price jumps, hidden time-clock cost [21] |

The complaints repeat across all of them:
- support quality
- tax-filing accuracy
- clock-in reliability
- hidden fees

Those are the four things to get right. In one buyer survey, reporting (33%) and self-service (31%) were the most requested features [22].

**Year-end software for Guam:**
- TaxBandits, $0.80–2.75 per form [23]
- Tax1099, which states SSA filing only [24]
- ezW2, $49 plus $99 for e-filing; it needs red-ink paper forms for W-2GU [25]
- Yearli, price on request [26]
- W2 Mate, a Guam EFW2 utility launched in January 2026 and pitched at QuickBooks users [27]

Their pain points are filing twice (SSA and DRT), strict file formats, corrections done offline and paper forms.

### Guam rules the product must handle

From Guam DOL's FLSA handbook (February 2026; the meal, split-shift, records, tips, deductions and pay-timing rows were checked against its text) [28], the H-2B booklet (August 2026) [29] and other primary sources. Cornerstone should still confirm each one before it becomes a rule in the software.

| Topic | Rule |
|---|---|
| Minimum wage | $9.25 an hour since September 1, 2021. It follows any federal increase. Bill 4-38, which would index it to inflation, is pending [28][30]. |
| Overtime | Time and a half after 40 hours a week. Comp time can't replace overtime pay [28]. |
| Tips | No tip credit. Tip pools are allowed. Service charges are not tips [28]. |
| Meals | A 30-minute meal period for a work period over 5 hours. If 6 hours or less completes the day, it can be waived by mutual consent. The meal period is unpaid unless the employee can't be relieved of duty [28]. |
| Split shifts | Must fall within 14 hours [28]. |
| Paying wages | Within 7 days after the pay period ends. When someone is fired, immediately or by the next business day. When someone quits, within 7 days after the pay period ends [28]. |
| Deductions | Deductions required by federal or territorial law (taxes) or by court process need no authorization. Any other deduction needs the employee's written authorization. Fines are banned and can't be authorized (22 GCA §3203–3204) [28]. |
| Pay statements | Must show every deduction, and the employee gets a copy. No Guam rule on electronic stubs was found (*unverified*; ask Guam DOL Wage and Hour) [28]. |
| Records | Keep wage and hour records for 6 years. Alien workers' records need passport numbers [28]. |
| Holidays | 12 legal holidays (1 GCA §1000, amended June 2025), plus one-off holidays by executive order [31]. Whether private employers must give them off is *unverified*. |
| New hires | Report to the Attorney General's Child Support Enforcement Division [32]. |
| H-2B (construction) | <ul><li>Register each worker with Guam DOL within 24 hours of arrival. No work before the Guam DOL ID card. $2,091 per worker per year.</li><li>Monthly report by the 7th: IDs, visa and certification dates, project, deductions, transfers, departures.</li><li>Employers with more than five H-2B workers must provide meals and lodging. They may deduct the standard allowable $80 a week for board and lodging actually provided, with the worker's signed authorization. A different amount needs Guam DOL approval first.</li><li>Prevailing wages (for example carpenters $19.10, electricians $21.36 from August 24, 2026).</li><li>US workers in the same job earn at least the H-2 wage [29].</li></ul> |
| E-Verify | Required on covered federal contracts, including on Guam. Not every federal contract is covered: FAR 22.1803 excludes, for example, contracts shorter than 120 days and those under the simplified acquisition threshold. Reminders must follow the contract's terms [33]. |
| Davis-Bacon | Doesn't cover direct federal construction on Guam, but some federally funded "Related Acts" projects do. Certified payroll is due within 7 days of each payday [34]. |
| Year-end | W-2GU and W-3SS to SSA, Copy 1 to DRT by January 31 (February 1 in 2027). The same EFW2 file is uploaded to GuamTax. Payroll processors need a flagged account. Details are in the [year-end plan](W2GU_1099_YEAR_END_FILING_RESEARCH_2026-11-17.md) [35]. |

## 5. The product

**One sentence:** Guam-correct payroll, time and HR for local businesses, run with Cornerstone.

### Modules

These are offerings in the client operating profile ([spec §1, §3](PLATFORM_OFFERINGS_IMPLEMENTATION_SPEC_2026-11-17.md)), not separate apps.

| Module | What it is | Built on |
|---|---|---|
| **Payroll** | Cornerstone runs payroll, taxes and filings. In place today. | Payroll |
| **Employee portal** | Pay, stubs, W-2GU and 1099 copies, profile. Included with payroll. | Spec E1–E4 |
| **HR** | <ul><li>PTO with a ledger</li><li>policies and acknowledgements</li><li>documents with e-signature</li><li>onboarding packets</li><li>emergency contacts</li><li>credentials with expiry dates</li><li>a task inbox, calendar and notifications</li><li>manager approvals in the client portal</li></ul> | Payroll (§6 below, spec F1–F5) |
| **Time** | Phone and kiosk clock-in, schedules, approvals, hours into payroll. In place at AIRE today; needs generalizing for a second client. | The AIRE codebase (spec C5, W1–W2) |
| **Year-end service** | W-2GU, W-3SS, EFW2 for SSA and GuamTax, 1099s and employee copies, for employers who keep their own payroll, such as the airport. | The year-end engine due February 1 |
| **Construction pack** (later) | H-2B date tracking and the monthly Guam DOL report, prevailing-wage checks, certified payroll, E-Verify reminders. | HR and Payroll |

### Design rules

The existing spec's rules all apply:
- offerings are settings
- Payroll is the one HR engine
- sensitive changes are approved in Payroll
- AIRE keeps working

The ADP study adds these:

1. **Guam is correct everywhere:** labels (Guam income tax, W-2GU), holidays, meal and split-shift rules, the 7-day pay deadline, 6-year retention.
2. **Pay is private by default.** Hide-my-pay masking, with a choice the employee keeps.
3. **Explain every number:** stub breakdowns, compare two checks, the hours behind each line (AIRE already does this), a balance equation and ledger for PTO.
4. **One inbox:** tasks, approvals and notices in one place for employees and for managers, with history.
5. **Each employer curates its own content:** banner, quick links, policies, forms, PTO policies, required documents. All of it is settings and uploads, never code.
6. **Phone-first and fast.** Most restaurant and construction staff will only ever use a phone. Every page should load in a second or two, not ADP's 10 to 30.
7. **Never more than one place to edit the same thing.** Address and contacts live in one profile.
8. **Verified channels and recorded consent** before texts or electronic tax forms.

## 6. HR module scope

### For the MoSa's pilot

MoSa's is a restaurant. Its staff are hourly, earn tips and clock in on Revel, and the restaurant has ordinary turnover. Revel stays the time source, so the pilot is the Payroll + portals offering with HR switched on.

| Feature | Employee sees | MoSa's managers see (client portal) | Notes |
|---|---|---|---|
| Sign-in | Invitation by email or text, MFA, one login across employers | Invite and deactivate employees | Spec E1–E2 |
| My pay | <ul><li>Stub list, masked by default</li><li>breakdown with tips shown clearly</li><li>compare two checks</li><li>YTD</li><li>PDF download</li></ul> | Unchanged | Spec E3, plus the ADP ideas in §2 |
| Tax forms | 2026 W-2GU posted alongside the paper copy; paperless consent for 2027 | Who has consented | Spec E4; needs the year-end per-employee PDFs |
| Profile | <ul><li>Contact details and emergency contacts</li><li>changes go through approval rules</li></ul> | Changes waiting for approval | Emergency contacts are new |
| Time off | <ul><li>Balance per policy with the equation and ledger</li><li>request form with review step</li><li>request status</li><li>calendar with paydays and holidays</li></ul> | <ul><li>Approve or decline</li><li>team calendar</li><li>who is off</li></ul> | Only if MoSa's has a PTO or sick policy. Payroll owns balances (spec F1). |
| Policies | <ul><li>Read and acknowledge the handbook</li><li>tip-pool and other policies</li><li>due dates</li></ul> | Upload a policy, set who must acknowledge it, see who hasn't | New |
| Documents | Their own documents; upload a requested one | Request a document, review it | Extends today's document requirements; pilot uploads are allowed with existing `ClientDocumentFileValidator` type/byte/size checks and no malware scanner, with scanning added before wider rollout (Leon, Nov 22, 2026) |
| Credentials | Their own permits and expiry dates | Expiring-soon list and reminders | Health certificates for food workers if Guam requires them (question 4) |
| Task inbox | Everything waiting on them | Everything waiting on managers | Email first; text after the SMS decision |
| New-hire packet | <ul><li>Personal info and W-4</li><li>direct deposit (approval rules apply)</li><li>emergency contacts</li><li>policies to acknowledge</li><li>documents</li></ul> | Start a packet, track completion | Could slip to after the pilot starts. I-9 Section 1 comes later. |

**Not in the pilot:** benefits enrollment, recognition, org chart, job postings, surveys, an AI assistant, a native app.

### After the pilot, before selling widely

- e-W-4 (spec F3)
- direct deposit changes with verification and the fraud hold (spec D4)
- a benefits view (spec F5)
- I-9 Section 1 and Section 2 with document upload
- holiday calendars per client
- reports managers ask for: headcount, turnover, expiring credentials, PTO liability
- text notifications

## 7. Time tracking: what to learn from ADP

For the Time module (AIRE's codebase), in rough order of value:

1. **Holidays fill in automatically** from the client's holiday calendar, flagged for supervisor approval, as ADP does.
2. **Guam meal-period compliance.**
   - Warn at clock-out or break when a shift passes 5 hours without a 30-minute meal.
   - Record a waiver when one applies.
   - Add a missed-meal report.
   - Today AIRE tracks breaks but sends no alerts.
3. **Missed-punch requests for both clock-in and clock-out.** Today the employee can correct only the clock-out. Requests go to the supervisor's queue.
4. **Attendance alerts:**
   - late arrival
   - a missed punch
   - a long shift
   - approaching overtime
   
   They go to the worker and the supervisor, with the employee choosing the channel (ADP's notification matrix).
5. **A 14-hour split-shift check** and a daily overtime view that follows Guam's 40-hour weekly rule. AIRE already supports configurable daily and weekly thresholds.
6. **Time-off balances inside the time app,** read from Payroll (spec `pto_balances_v1`), so connected-time employees see the same numbers as portal users.
7. **A timecard view by pay code and department, with totals,** plus the schedule beside it.
8. **Kiosk photo capture as an option per client** to stop buddy punching. It needs a consent and retention rule.
9. **Offline punching at kiosks only,** with signed device timestamps and supervisor review. AIRE refuses offline punches on purpose today; revisit only if a client's site has unreliable internet.
10. **More than one employer** (spec C5, W1–W2): a company column, a configurable time zone and workweek. Needed before a second time client.

Already better than ADP and worth keeping:
- the hours behind each paycheck line
- undoable approvals
- the cutoff lifecycle
- stubs without a login

## 8. Order of work and timing

Two dates fix the order:
- **February 1, 2027:** W-2GU and 1099 filing is due.
- **When MoSa's wants to start.** Not yet set.

The year-end engine also produces the per-employee W-2GU PDFs that the portal posts and the year-end service sells, so it is not a detour.

This plan pulls the employee portal earlier than the spec's February–April estimate. That is tight for one developer working with agents. **If anything conflicts, year-end wins.**

| When | Work | Outcome |
|---|---|---|
| **Now to mid-December** | <ul><li>Year-end steps 0–5 (EFW2, W-2GU PDFs, 1099/1096, Pub 1220).</li><li>Alongside them: spec C1 (AIRE contract fixtures), A1 (client operating profile) and S1 (staff MFA).</li><li>Leon's decisions in §10 and the spec's §10.</li></ul> | Year-end on track; foundations safe for MoSa's runs |
| **Mid-December to mid-January** | <ul><li>Employee identity and portal Phase 1: spec E1–E3.</li><li>HR data foundations: emergency contacts, policies and acknowledgements, credentials, the task inbox.</li></ul> | Pilot with Cornerstone's own staff in January |
| **Late January to February** | <ul><li>W-2GU copies posted (E4), alongside paper.</li><li>MoSa's invites.</li><li>PTO policies, ledger and requests if MoSa's has a policy.</li><li>Manager approvals in the client portal.</li></ul> | MoSa's pilot live; a natural launch: "get your W-2 on your phone" |
| **March to April** | <ul><li>New-hire packet, e-W-4, bank changes with verification (D4), reports.</li><li>Time module items 1–4 from §7.</li><li>Design the year-end service for tax year 2027.</li></ul> | Ready to sell to the next two or three clients |
| **Later in 2027** | <ul><li>A second time client (W1–W2).</li><li>The construction pack, if Cornerstone's construction prospects want it.</li><li>Benefits view, I-9.</li></ul> | Broader sales |

New PRs to add to the [spec's sequence](PLATFORM_OFFERINGS_IMPLEMENTATION_SPEC_2026-11-17.md#9-pr-sequence). Each depends on E1, plus D1 for change requests.

| # | PR | Notes |
|---|---|---|
| H1 | Emergency contacts (table, staff, client and employee views; changes through the approval rules) | Small; good first HR PR |
| H2 | Policies and acknowledgements (upload, audience, due date, acknowledgement record with version and time, client report) | Pilot uploads allowed without a malware scanner using `ClientDocumentFileValidator`; add malware scanning before wider rollout (Leon, Nov 22, 2026) |
| H3 | Credentials with expiry (type catalog per client, dates, document link, reminders, expiring report) | Covers health certificates now and H-2B dates later |
| H4 | Task inbox and notification preferences for employees and client managers | Email first; text after spec N1 |
| H5 | Client holiday calendars, shown in the portal calendar and fed to time apps | Guam's legal holidays as the default |
| H6 | New-hire packet (steps assembled from H1–H3, W-4 and direct deposit) | After the pilot starts, if needed |
| F1 | PTO (already in the spec), adding the balance equation, ledger view and request review step from §2 | — |

## 9. Packaging and pricing

These are suggestions for Cornerstone to decide, and they rest on the comparison in §4:
- small-business tools charge about **$6–15 per employee per month** plus a base fee
- all-in-one suites charge **$20–36**
- ADP is estimated at **$23–30** for software alone

Users complain most about per-run fees and paying extra for a time clock.

| Offering | Suggested model | Reasoning |
|---|---|---|
| Payroll service | Cornerstone's current fees | Unchanged |
| Employee portal | Included with payroll | The market charges for HR and time, not for stubs and W-2s; including it makes payroll stickier |
| HR | A monthly base plus a small per-employee fee | One clear price, no per-run fees |
| Time | Per employee per month, kiosk tablet at cost | No separate time-clock fee |
| Year-end service | A base fee plus a per-form fee covering both filings and employee copies | Competitors charge $0.80–2.75 per form for software alone; Cornerstone adds the filing and the Guam expertise |
| Construction pack | An add-on per H-2B worker or per project | Priced once a construction client confirms what they need |

The numbers should come from what Cornerstone's clients pay today and what MoSa's would pay after the pilot.

## 10. Decisions for Leon

1. **Pull the employee portal and the HR pilot ahead of the spec's estimate,** with year-end first. Recommended.
2. **HR is sold only with Cornerstone payroll in 2027,** not as standalone HR software. Recommended. It keeps one HR engine and avoids importing other providers' payroll.
3. **The year-end service** is built from the year-end engine this season and sold for tax year 2027 (filing in January 2028). Selling it to new customers this January is risky with the current deadline. Recommended.
4. **Credentials with expiry dates are core HR,** not a construction extra. They cover restaurants (health certificates) as well as construction. Recommended.
5. **The construction pack waits** until a construction client confirms the need and the price. Recommended.
6. **The product's name and brand,** if it should have one apart from Cornerstone. Leon's call.

The earlier decisions in [the spec §10](PLATFORM_OFFERINGS_IMPLEMENTATION_SPEC_2026-11-17.md#10-decisions-for-leon) still stand. They include the SMS provider, the employee Clerk app, staff MFA and the employee app's web address. The HR pilot needs them answered.

## 11. Questions

### For Dafne, Mark and Benjo

1. **The MoSa's pilot.** When should it start, and what do MoSa's owners and staff want first: stubs on the phone, time off, onboarding or policies?
2. **Time off.** Does MoSa's have a written PTO or sick-leave policy? How does it accrue, and who approves requests?
3. **Policies.** Which should MoSa's employees acknowledge: the handbook, the tip pool, others?
4. **Credentials.** Do MoSa's staff need Guam health certificates or food-handler permits tracked? Which credentials matter for other clients: licenses, certifications, H-2B dates?
5. **Languages.** Which languages do MoSa's staff read most comfortably?
6. **The airport.** These answers shape the year-end service.
   - What product does it buy for W-2s, and roughly what does it cost?
   - About how many W-2s does it issue?
   - What is painful about it?
7. **Who's next.** Which businesses would Cornerstone pitch first, and are any construction firms with H-2B workers?
8. **Pricing.** What do clients pay Cornerstone for payroll today? Would they pay a per-employee HR or time add-on?
9. **Electronic stubs.** Has Guam DOL said whether electronic pay stubs satisfy the copy requirement?
10. **Support.** Who answers employee questions from the portal: the client's manager, Cornerstone, or both?

The [year-end plan](W2GU_1099_YEAR_END_FILING_RESEARCH_2026-11-17.md), the [portal plan §8](EMPLOYEE_PORTAL_AND_PLATFORM_PLAN_2026-11-17.md#8-questions-for-cornerstone) and the [spec §11](PLATFORM_OFFERINGS_IMPLEMENTATION_SPEC_2026-11-17.md#11-questions-for-cornerstone) hold the earlier questions. These two are the most time-sensitive:
- **One of last year's ezW2 upload files,** to check whether it was filed as W-2GU.
- **Whether Cornerstone has its SSA Business Services Online and GuamTax logins** for filing.

### A caution about the airport

Dafne is in charge at the airport now. GIAA is a public corporation, so any sale by Cornerstone or Shimizu Technology to the airport would go through Guam procurement rules and raise a conflict-of-interest question. Before any pitch, Cornerstone should get advice on procurement and ethics, including whether Dafne would need to recuse herself. Learning from the airport's experience as a customer of other vendors is fine.

## Sources

1. https://quickbooks.intuit.com/learn-support/en-us/employees-and-payroll/re-efw2-files-for-guam/01/1383505/highlight/true
2. https://quickbooks.intuit.com/learn-support/en-us/employees-and-payroll/efw2-files-for-guam/00/1382871
3. https://topsourceworldwide.com/global-payroll/guam/
4. https://financeintegratedsolutions.com/
5. https://www.eguamdirectory.com/guam/payroll-service ; https://globalpeoservices.com/guam-peo-payroll-services/
6. https://www.guamairport.com/docs/pages/corporate/reports/bod-minutes-print/2020/january-17-2020-giaa-regular-board-meeting-minutes.pdf
7. https://notices.guam.gov/notice_detail/5192
8. https://doa.guam.gov/wp-doa-content/uploads/2024/02/DOA-Org-Cir-2024-025-Automated-GG-1-Tracking-Implementation.pdf
9. https://outsail.co/post/how-much-does-adp-workforce-now-cost ; https://www.costbench.com/software/hr/adp-workforce-now/
10. https://g2.com/products/adp-workforce-now/reviews?page=4 ; https://www.capterra.com/p/155895/WorkforceNow/reviews/?page=2
11. https://www.outsail.co/post/paycom-review-2026-pricing-features-pros-cons ; https://fitsmallbusiness.com/paycom-review/
12. https://www.g2.com/products/gusto/competitors/alternatives ; https://www.g2.com/products/rippling/reviews ; https://www.joinhomebase.com/blog/paylocity-alternatives
13. https://www.outsail.co/post/how-much-does-paylocity-cost-in-2026-pricing
14. https://rivermate.com/blog/gusto-pricing ; https://www.hireinsouth.com/post/gusto-pricing
15. https://www.capterra.com/p/131882/Gusto/reviews/
16. https://gusto.com/resources/guides/switch-payroll-providers/rippling-pricing ; https://peoplemanagingpeople.com/tools/rippling-pricing/
17. https://gusto.com/resources/guides/switch-payroll-providers/bamboohr-pricing
18. https://joinhomebase.com/pricing
19. https://www.trustpilot.com/review/joinhomebase.com?page=2 ; https://www.merchantmaverick.com/reviews/homebase-payroll/
20. https://wheniwork.com/pricing
21. https://www.capterra.com/p/121248/When-I-Work/reviews/?page=11 ; https://turnozo.com/blog/when-i-work-review
22. https://www2.slideshare.net/SoftwareAdvice/software-advice-buyerview-payroll-software-report
23. https://www.taxbandits.com/w2-forms/efile-w2gu-form-online/
24. https://tax1099.com/wage-tax-forms/efile-form-w-2gu
25. https://www.halfpricesoft.com/w2-software/ezw2-features-and-pricing ; https://www.halfpricesoft.com/forum/posts/t17897-process-w2-for-guam/
26. https://yearli.com/forms ; https://yearli.com/detailed-pricing
27. https://www.accessnewswire.com/newsroom/en/industrial-and-manufacturing/guam-w2-electronic-filing-and-efw2-generator-for-guamtax.com-w-2gu-wag-1125442
28. https://dol.guam.gov/wp-content/uploads/GDOL-FLSA-Handbook-as-of-2.16.2026.pdf
29. https://dol.guam.gov/wp-content/uploads/H-2B-Program-Booklet-2026-rev-8-22-26.pdf
30. https://www.kuam.com/story/53407012/bill-4-renews-debate-over-inflationtied-wage-increases-on-guam
31. https://col.guamcourts.gov/sites/default/files/01gc010.pdf
32. https://oagguam.org/cs-employers
33. https://www.law.cornell.edu/cfr/text/48/52.222-54 ; https://www.acquisition.gov/far/22.1803
34. https://www.dol.gov/sites/dolgov/files/WHD/prevailing-wage-presentations/DBA_Coverage.pdf ; https://www.dol.gov/sites/dolgov/files/WHD/legacy/files/DBRA_013026-Public.pdf
35. https://www.guamtax.com/help/help_w2w3.html ; https://irs.gov/pub/irs-prior/fw3ss--2025.pdf
