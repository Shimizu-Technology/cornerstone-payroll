# Improvement backlog: ADP and Gusto review

**Status:** Parked by Leon on November 28, 2026: wanted, but not yet. Nothing here is scheduled. Pick items from this list once the current work (below) is done.
**Date:** November 28, 2026.
**Checked against code:** Payroll `origin/main` `55bc42f83`. Line references may drift; recheck them before building.
**Builds on:** [the milestone plan](PRODUCT_ARCHITECTURE_DECISION_2026-11-19.md) §6, [the client-managed employee lifecycle plan](CLIENT_EMPLOYEE_LIFECYCLE_BUILD_PLAN_2026-11-28.md) and [the Milestone 4 build plan](MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md).

Leon asked for a thorough review of the app, compared with how ADP and Gusto handle the same jobs, to find where the flows could be cleaner, simpler and more intuitive. The review covered the staff workspace, the client portal and the employee app on desktop and phone. It produced 70 findings, which became 58 items in three waves:

- **Wave A (32 quick fixes): done.** Shipped in #682 (staff workspace) and #684 (client portal and employee app). Live in production on November 28, 2026.
- **Wave B (17 flow cleanups): parked.** Listed below.
- **Wave C (9 bigger features): parked.** Listed below.

## 1. Order of work

1. **Finish the client-managed employee lifecycle** (lifecycle PRs 3–5). The feature stays switched off for every company until PR 5.
2. **Re-record the walkthrough video** with the lifecycle included. Leon watches it first.
3. **Cornerstone tests it.** Mark and Benjo work through the [Milestone 4 acceptance script](rollout/M4_ACCEPTANCE_SCRIPT.md), extended with the lifecycle scenarios from the lifecycle plan §11, on the demo company. This is step 3 of how every milestone goes live (milestone plan §6).
4. **Then choose from this backlog.** Fix what Cornerstone's testing turns up first, then pick Wave B and Wave C items.

## 2. Still-open risks from the review

The review flagged six "fix first" risks. Wave A closed three of them (FX-3, FX-6 and half of FX-4). Three need Wave B or C work. They aren't urgent enough to interrupt the lifecycle work, but they should come first when this backlog opens.

| ID | Risk | Fixed by |
|---|---|---|
| FX-1 | The client dashboard picks the "current" pay period with two different rules, so a client can send files for the wrong period or follow a "Next payroll" link to a period that isn't open yet. | B-04 |
| FX-2 | Hours typed into a draft run live only in the browser until Calculate. A refresh, crash or navigation loses them. | B-06 |
| FX-4 | Client managers can't see who at their company has portal access, so a former employee's access can go unnoticed. (The role label part shipped in Wave A.) | C-02 |
| FX-5 | One staff user can calculate, approve and commit the same run. Who did each step is recorded. This is a control decision for Cornerstone, not a bug. | C-04 |

## 3. Decisions waiting for Leon

These are recommendations, not decisions. Leon liked all of them and chose to wait.

| Question | Recommendation |
|---|---|
| Which Wave C features come first? | C-01 due dates next to the pay date, C-02 team access for client managers, and C-03 a firm-wide payroll queue. |
| Should one staff member be able to calculate, approve and commit the same run (C-04)? | A per-client setting, off by default. When it's on, the person who calculated a run can't approve or commit it. The existing admin override covers exceptions. |
| Regroup the staff sidebar into hubs (B-07)? | Yes, but only with a short note to Cornerstone staff, since links move. Nothing is removed. |

## 4. Wave B: flow cleanups

Ordered by impact divided by effort (High=3, Med=2, Low=1; S=1, M=2, L=3). Ties are broken by risk. Codes in brackets (S-, CP-, EA-) are the review's finding numbers.

| ID | Title | Surface | Problem | Fix | Evidence and status | Effort | Impact |
|---|---|---|---|---|---|---|---|
| B-01 | Keep the submission receipt in view | Client portal | After "Send to Cornerstone" the page stays scrolled to the bottom, so the receipt above is off-screen and managers may send again. | Scroll to and focus the receipt, or show it next to the button. | Confirmed by flow: receipt set via `setNotice` at `web/src/pages/payroll-submissions/PayrollPeriodPage.tsx:191`. (CP-12 part) Pattern: "One review screen and a submission receipt". | S | Med |
| B-02 | One place for W-2GU consent | Employee app | The full W-2GU legal disclosure is open in a nested scroll box with a Print button, and the same card appears on both Tax forms and My info. | Collapse it behind "Read the full disclosure" as in Go paperless. Keep it on Tax forms and link from My info. | Confirmed. `web/src/employee/taxes.tsx:107`; `web/src/employee/myinfo.tsx:636`. (EA-04) Pattern: "Explicit paperless consent with a paper fallback". | S | Med |
| B-03 | Add-hire form defaults | Staff | Guam hires need State typed every time, and the W-4 effective date doesn't default to the hire date. | Default State from the company and the W-4 date from the hire date. | Confirmed for defaults: `web/src/pages/employees/EmployeeForm.tsx:64,80`. Partly for "doesn't scroll to errors": a scroll-to-first-error helper exists at `:779-788`, so the miss is field-specific. Downgraded. (S-17) Overlaps #681. | S | Med |
| B-04 | Client dashboard shows one next step | Client portal | The dashboard shows two different "current" periods, keeps a loud "Send payroll files" card while approval is waiting, labels a period "Being prepared" both before and after files are sent, and never shows pending employee change requests. | Pick the period on the server once and return one prioritized state: approve, then send files, then waiting on Cornerstone. Show future periods as schedule info only. Add "Files sent", sort open periods first, and add pending change requests to "Needs your attention" (client `pending_changes` is hard-coded to 0). | Confirmed. See FX-1; `web/src/lib/clientPayrollStatus.ts:9-11`; `web/src/hooks/usePortalCounts.ts:35`. (CP-01, CP-12 parts, CP-19 part, CP-04 dashboard part) Patterns: "An explicit next owner", "Deep links from actionable reminders". | M | High |
| B-05 | Pay run workspace puts the work first | Staff | "Re-run a stuck job" shows for every admin on every run, the workbook import is the only item in a "…" menu, the Expected entries list pushes the hours grid below the fold, and committed runs show "Checks & payments" four times while corrective pay is a row-menu item called "Correct". | Show the retry only when a job has actually stalled, or move it to the menu. Put Import next to Calculate. Collapse Expected entries into a banner. Keep one Checks & payments action and rename "Correct" to "Issue corrective paycheck". Rename the "New" badge to "Not entered yet" and show Tips by default for tipped clients. | Confirmed. Retry depends on role, not job state: `api/app/controllers/api/v1/admin/pay_periods_controller.rb:1479`, `web/src/pages/PayPeriodDetail.tsx:153-154`. Import in menu: `web/src/pages/pay-periods/pay-run/PayRunProcessingActions.tsx:69-84`. Row menu: `PayRunResultsView.tsx:49`. Badge: `PayRunHoursWorksheet.tsx:353-354`. (S-04, S-21 parts) Patterns: "Hours grid with import validation", "Separate correction, cancellation and off-cycle actions". | M | High |
| B-06 | Save draft hours | Staff | See FX-2. | Debounced autosave of worksheet edits to the draft, or an explicit "Save draft" that doesn't calculate. | Confirmed. `usePayRunController.tsx:1321-1335`. (S-21 part) | M | High |
| B-07 | Staff navigation hubs | Staff | 39 sidebar links. Employee App has four links in two sections, client setup spans seven pages, and Client Portal pages sit 25 links below Client Inbox. | Group into hubs: one Employee App page with tabs (Rollout, Status, Branding & Help, Switch), a tabbed Client Settings page, and portal queues under Client Inbox. Build the sidebar and ⌘K from one route list. Fold `/departments` into Employees. | Confirmed. `web/src/components/layout/Sidebar.tsx:69-142`; (S-02, S-05 part, S-19 part, S-28 part) Pattern: Gusto "People, Pay, Reports and Documents map to familiar tasks". | L | High |
| B-08 | Reports open where you are | Staff, client portal | Staff Reports opens with a ~420px marketing banner and firm-wide Client profitability inside a client page. The client filter bar mixes native and styled controls, "Employee Pay History" is disabled with no reason, and SWICA, W-1 and Schedule B have no explanation. | Replace the banner with search and category chips. Open a report at the top or in a drawer. Move Client profitability to Tools. Use one Select component, explain disabled buttons, and add one-line descriptions of the tax forms. | Banner confirmed: `web/src/pages/Reports.tsx:4340-4361`. Partly for "opens far below": the panel already scrolls into view (`Reports.tsx:4253-4262`). Client controls confirmed: `ClientReports.tsx:335-337`. (S-13, CP-07 rest) Pattern: "Name the report for the question it answers"; "Report filters that follow the export". | M | Med |
| B-09 | Client navigation groups | Client portal | 13 flat links. "Pay period files" vs "Pay periods" and "Employee app" vs "Employee app status" are easy to confuse. Support access is a daily-level link. | Group into Payroll, People, Employee app (one tabbed page) and Company. Put Contact details and Departments under Employees, and Support access under Company. | Confirmed. `web/src/components/layout/Sidebar.tsx:84-98`. (CP-11, CP-06 tabs, CP-27) | M | Med |
| B-10 | List first, create second | Staff, client portal | Client Documents puts an upload form and a second Messages panel above the files. Messages shows the compose form above threads on desktop. Payroll Fields puts the create form above the list. Checks & Payments opens with two dark banners and "No committed payroll liabilities" above 36 outstanding checks. | Show the list first and put create/compose behind a button. Remove the Messages embed from Documents. Compact the Checks banners and say that liabilities are tax obligations and checks are net pay. Add search and filters to client Documents, and replace `window.confirm` with the app's dialog. | Confirmed: `web/src/components/client-portal/PortalMessagesPanel.tsx:658` (`hidden lg:block`); `web/src/pages/AdminClientDocumentsPage.tsx:441`; `web/src/pages/client/ClientDocuments.tsx:200`. Partly for Checks: not a data contradiction (`web/src/components/payroll/PayrollLiabilityCenter.tsx:121-122` covers tax obligations only); downgraded to a copy fix. (S-12, CP-13, S-18 part, S-15, CP-17) | M | Med |
| B-11 | Employee profile shows status actions and documents | Staff, client portal | Terminate, Mark inactive and Documents are at the bottom of Edit Employee, not on the profile. The client profile repeats the pay method and omits hire date, address and documents. | Add a status menu (Mark inactive, Terminate, Reactivate) and a Documents tab to the profile. Add start date, address and a documents link to the client overview. | Confirmed. `web/src/pages/employees/EmployeeForm.tsx:2445-2455`; `EmployeeWorkspace.tsx:454-458` shows documents only while missing. (S-07 part, CP-26, CP-17 part) Overlaps #681. | M | Med |
| B-12 | Real install support for the employee app | Employee app | The manifest is a `blob:` URL, icons are always the letter monogram, the touch icon uses the logo only when it is exactly square, `theme-color` is the brand color over a white header, and Help never explains Add to Home Screen. | Serve a per-company `/manifest.webmanifest` with the logo (same 10% square tolerance as settings), set theme-color to the header color, add `apple-mobile-web-app-status-bar-style`, and add a Help item on adding the app to the home screen. | Partly. Code confirmed: `web/src/employee/install.ts:27-29,34-37,54-67,79`. Android install failure not tested on a device. (EA-02) Pattern: "Pay essentials first on mobile". | M | Med |
| B-13 | Turn on the employee app in one step | Staff | Turning on the app for a client takes six switches with six reason prompts across four pages. | Add "Turn on standard employee app" that logs one reason for all ready switches. | Seen in the review screenshots. `web/src/pages/EmployeeAppSwitch.tsx`. (S-19) | M | Med |
| B-14 | Employees list density | Staff, client portal | A "Full employee details required" card, the Roles and departments panel and five filters push the roster down. On phones the first employee is below the fold. The mobile edit form has 32px section pills that clip. | Make the intake note a compact row, list departments and roles with headcounts, put secondary filters behind a toggle, and make the pills 44px in a padded scroller. | Seen in the review screenshots. (S-09 part, CP-15, CP-16) | M | Low |
| B-15 | Activity History usable for one client | Staff | No client filter. The empty detail card takes 35% of the width. | Add a client filter. Show details in a drawer only when a row is selected. | Seen in the review screenshots. (S-11 part) | M | Low |
| B-16 | User Management search | Staff | No search or role filter. "Client management" reads like a link but is a permission toggle. | Add search and a role filter. Rename the button to "Allow client setup". | Seen in the review screenshots. (S-25) | M | Low |
| B-17 | Show what changed in a resubmission | Client portal | Revision 2 lists all files and entries again with no summary of the change. | Add a "Changes from revision 1" line in the timeline. | Not code-verified (Low). `web/src/pages/payroll-submissions/PayrollPeriodPage.tsx:212-215`. (CP-25) | M | Low |

## 5. Wave C: bigger features from ADP and Gusto

Ordered by impact divided by effort.

| ID | Title | Surface | Problem | Fix | Evidence and status | Effort | Impact |
|---|---|---|---|---|---|---|---|
| C-01 | Show due dates next to the pay date | Client portal, staff | Clients see a pay date but not when files are due or when approval is needed. Staff see neither across clients. | Show "Files due", "Approve by" and "Pay date" together on the client dashboard, the pay period files page and the staff queue (C-03). Drive reminders from the same dates. No in-app bank debit was found, so leave out a debit date. | Gap. `web/src/components/payroll-submissions/PayrollFilesEntry.tsx:22-27` shows the pay date and opens-on only. Reminder config exists (`api/app/models/payroll_reminder_config.rb`). No NACHA or funding code under `api/app`. Pattern: "Run-by deadline, debit date and payday together". | M | High |
| C-02 | Team access for client managers | Client portal | See FX-4. | Add a read-only Team access page listing the company's portal users and their roles, with "Request a change" sent to Cornerstone as a message. | Confirmed (CP-08). Patterns: "Write permissions as concrete actions by company and role"; "Separate prepare, approve and submit permissions". | M | High |
| C-03 | Firm-wide payroll queue | Staff | The staff Home page covers one client. Staff can't see which clients are due, late or blocked without switching into each one. | A queue of every client's next run with pay date, files due, status, blocker and next owner (client, Cornerstone or approver), linking straight into the run. Extend the org-wide Client Inbox instead of building a separate page. | Gap. `web/src/pages/Dashboard.tsx:73-104` is per-client; Client Inbox is org-wide but covers portal work only (`web/src/components/layout/Layout.tsx:223`). Patterns: "One firm-wide payroll queue"; "An explicit next owner". Overlaps #681 ("To verify" queue). | L | High |
| C-04 | Optional preparer and approver split | Staff | See FX-5. | Per-client setting: the person who approves or commits a run can't be the person who calculated it, with the admin override that already exists for exceptions. Show who did each step on the run. | Confirmed. `api/app/policies/staff_role_policy.rb:13`. Pattern: "Separate prepare, approve and submit permissions". Overlaps #681 (permission bar and override). | M | Med |
| C-05 | Commit and approval receipt | Staff, client portal | Client approval records a revision and review ID, but there is no single receipt that says who calculated, approved and committed a run, when, and for what totals. | Add a receipt card on committed runs and in the client's pay period view, and email it to the account team. | Partly exists. Lifecycle users and timestamps are in reports (`api/app/controllers/api/v1/admin/reports_controller.rb:3280-3285`). Pattern: "One review screen and a submission receipt". | M | Med |
| C-06 | Show which period a pay change hits | Staff | Pay changes are already effective-dated with a reason, but the form doesn't say which pay period is affected first or flag committed periods that need a correction after a backdated change. | Show "First affected: Nov 22 – Dec 5" and, for backdated changes, list committed runs that need a corrective paycheck. | Backend exists: `api/app/models/employee_compensation_change.rb`, `api/app/services/employee_compensation_change_service.rb:114-133`; UI at `web/src/pages/employees/EmployeeForm.tsx:714`. Pattern: "Effective-dated pay changes". Overlaps #681 (per-period readiness, stale calculations). | M | Med |
| C-07 | Separate paths for correction, off-cycle and cancel | Staff | Corrective pay is a row-menu "Correct", corrections live in the overflow menu, and there's no single place to choose "pay someone extra", "fix a committed check" or "undo a run". | One "Fix or add pay" action on committed runs that asks what happened and routes to a corrective paycheck, an off-cycle run or a void. | Confirmed placement: `PayRunResultsView.tsx:49`; `PayRunProcessingActions.tsx:90`. Pattern: "Separate correction, cancellation and off-cycle actions". | M | Med |
| C-08 | Report context carried into exports | Staff, client portal | Some exports carry year and quarter in the filename. Client name and pay period are not checked consistently. | Put client, period and filters in every export's filename and header row. | Partly exists: `web/src/pages/Reports.tsx:464,2538`. Pattern: "Report filters that follow the export". | M | Low |
| C-09 | Former-worker reminder in offboarding | Staff, client portal | Former employees keep read-only app access, but the terminate flow doesn't tell staff or the worker. | Add one line to the termination confirmation about access until a date, and make sure a personal email is on file. | Exists in the backend: `api/app/services/employee_links/close.rb:50`, `api/app/services/employee_documents/tax_form_retention.rb:6`. Pattern: "Former-worker access to pay and tax records". Overlaps #681 (terminate). | S | Low |

## 6. Overlaps with work already planned

Don't build these twice.

**Client-managed employee lifecycle (#681 plan, PRs 3–5).**

- **B-11 profile status actions:** the lifecycle work adds client terminate and rehire. The staff profile menu should open the same dialog.
- **B-03 add-hire defaults:** the lifecycle work changes add-employee and readiness. Apply the State and W-4 date defaults inside that form work.
- **B-04 client "Needs your attention":** the lifecycle "Ready to pay" checklist items should appear in this one attention list, not a second panel.
- **C-03 firm-wide queue:** the lifecycle "To verify" queue and the unverified-changes check before commit should show as a blocker column in the queue. Build the queue on the same data.
- **C-04 preparer/approver split:** this must agree with the lifecycle readiness override and its permission bar (verify vs approve).
- **C-06 which period a pay change hits:** the lifecycle work's stale-calculation fingerprints and per-period readiness use the same "which period is affected" logic. Share it.
- **C-09 former-worker note:** the lifecycle terminate flow already covers final-pay prompts.

**Milestone 5 (leave and onboarding).**

- PTO and leave: show the balance next to the request and the decision, as Gusto and ADP do.
- Onboarding documents and I-9: keep document signing and verification as separate tasks. B-10 adds only search and filters to client Documents; signing and verification wait for milestone 5.
- Employee W-4 self-onboarding: a shared checklist for the employee and the client. Recheck the A-30 state default and the A-02 invite flow when self-onboarding lands.

## 7. Already good, keep

The review also found things that already match or beat ADP and Gusto. Don't regress these.

- **Client approval is tied to a revision.** The preview PDF has a watermark, a review ID and a required acknowledgement, and later edits create a new revision.
- **Committed runs can't be edited.** Corrections go through a corrective paycheck that shows original and corrected values side by side, a live delta and a required reason.
- **Print checks uses a saved snapshot**, with editable check numbers, the selected count and total, and paper checks separate from direct-deposit stubs.
- **The year-end checklist** gates steps 2–8 on "Who files 2026 forms", using plain-English choices.
- **Tax tables are safe.** Calculation picks rules by pay-date year and only uses verified tables, and 2027 is blocked until verified.
- **Guam details are right:** DRT Form 500, W-2GU, 941-GU, ChST timestamps, "Guam income tax" on stubs, and the overtime workweek kept separate from the pay schedule.
- **Demo and practice copies are isolated**, with Demo badges, an email allowlist and read-only notices.
- **Pay changes are effective-dated** with a reason, and future changes can be cancelled.
- **Break-glass actions** need an admin role, MFA, a reason and an audit record.
- **Pay period files** come with templates, structured extra hours tied to a saved job and rate, and timestamped revisions.
- **Address change requests** show current and requested values side by side, for managers and employees.
- **The employee app explains pay in plain English**, has Hide amounts, real PDF stubs, 16px inputs with no zoom, no horizontal overflow, and a calm "Decide later" paperless flow.
- **Former employees keep read-only access** to stubs and tax forms.
- **Viewer protection is enforced on the server**, not just hidden in the UI.
