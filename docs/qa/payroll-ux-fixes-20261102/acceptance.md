# Payroll UX fixes — November 2, 2026

Implementation base: `origin/staging-v2` at `ec0e9c5027fed9886fa931c0dab3abf95ef9d8ff`.
Production-source comparison: `origin/main` at `6c78c3457812cbbb9351d70d80351d913db91526` (source inspection only).
Target: one PR to `staging-v2`, held for the November 7 release. No staging or production access.

Cornerstone lets Dafne, Chels, Mark and Benjo maintain employee pay setup, enter/import hours, calculate payroll, obtain approval and retain payment/filing history. These fixes change behavior and copy within existing layouts. Existing withholding decisions, supplied SSN format checks, retirement plan evidence and committed payroll protections remain required.

Sources: the task brief and business decision (Leon, November 2026); `api/app/models/employee.rb`; `api/app/models/pay_period.rb`; `api/app/models/payroll_intake_session.rb`; `api/app/models/payroll_intake_document.rb`; `api/app/services/payroll_retirement_calculation.rb`; the affected React components; Brain Dump `work/shimizu-tech/Cornerstone/payroll-priorities-and-aire-reconciliation-2026-09-19.md` (operator workflow and retained payroll history). Older notes provide context, not current deployment verification.

All five defects are present in the inspected main source. Main keeps the hours worksheet inside `PayPeriodDetail.tsx`; staging-v2 has extracted it into `PayRunHoursWorksheet.tsx`. Neither had an employee-link navigation guard. Both branches validate missing personal details on edits, expose the raw source error, unconditionally prevent source package/document destruction, and use the same unnamed Roth error and data-derived match destination.

## Required acceptance

Agent executes each journey on a synthetic local Rails/Vite stack at desktop 1440×900 and phone-width 390×844. Phone-width testing covers browser layout/interaction, not a physical phone or native keyboard. AIRE account failure is supplied by an isolated local source stub; no real provider connection is attempted.

| Case | Start and action | Required visible and saved outcome | Status |
| --- | --- | --- | --- |
| D3 | Existing employee missing SSN/hire date/address; edit wage and save | Inline warning, no native required-field block, persisted wage after reload | Passed, both widths |
| D4 | Payroll AIRE panel with unconnected staff account | Plain connection message, Settings → Time tracking account link opens the connection page | Passed, both widths |
| D5 | Type draft hours; click employee name; cancel leaving | Unsaved-changes confirmation; same route and hours retained; accepted leaving navigates | Passed, both widths |
| D6 | Calculated, unapproved Spike run with applied package/document/rows | Delete succeeds; run and dependent records gone; approved/committed/evidence blockers retain records with reasons | Passed, both widths |
| D8a | Calculate employee with unverified legacy employee Roth | Error names employee and exact setup path; link opens retirement setup | Passed, both widths |
| D8b | Retirement setup with legacy Roth employer destination, unconfirmed | Checkbox/Traditional guidance; draft retained; selecting Traditional permits saving and survives reload | Passed, both widths |

Automated gates and browser results will be recorded against the final implementation commit. Required acceptance failures remain blockers; screenshots alone do not count as completion.

## Executed evidence

All six cases passed on the local Rails API at port 4327 and Vite at 5327, with synthetic data only. Playwright Chromium used actual 1440×900 and 390×844 viewports after the collaborative preview twice timed out. This does not certify physical-phone keyboard behavior or real AIRE/OAuth access.

- D3: existing employee Jamie Missing had no SSN, hire date or mailing address. Saved and reloaded wages at both widths; repeated after restarting the API with the final employee model. Final saved rate $31/hour. The synthetic employee had a valid dated W-4 fixture; withholding controls were exercised separately by specs.
- D4: a loopback-only source stub returned HTTP 401 with the exact missing-header error. Both the live-preview panel and cockpit feedback showed connection guidance. The Settings link opened `/app/aire-account-connection`.
- D5: typed 17 hours on desktop and 18 on phone, clicked the employee name, dismissed the confirmation, and verified the route and hours remained. Then accepted leaving and verified the employee overview opened. Dialog text: “You have unsaved payroll changes. Stay here and calculate payroll to save them. Leave without saving?”
- D6: deleted two calculated, unapproved synthetic Spike runs through the actual desktop table and phone card. Both API responses were 204; a list reload retained the deletion. Database verification found zero matching runs, payroll items or source packages; request/model specs also verify source rows, documents, earnings and protected-history cases.
- D8a: calculated with Riley Roth's legacy employee Roth contribution; the error named Riley and gave the exact path. Repeated on phone, then followed the new-tab link to employee 10's `pay-setup#retirement-plan`, retaining the original payroll tab.
- D8b: Morgan Match's existing legacy Roth employer rate preserved the Roth destination. Both widths showed the checkbox/Traditional guidance while keeping the draft. Selecting Traditional saved; reload preserved it. Recorded a second dated desktop change to exercise the same recovery.

Screenshots: `D3-{desktop,phone}-warning.png`, `D4-{desktop,phone}-connect.png`, `D5-{desktop,phone}-retained.png`, `D6-{desktop,phone}-deleted.png`, `D8-{desktop,phone}-named-error.png`, `D8-{desktop,phone}-match-guidance.png`.

Frontend: 140 files / 1,370 tests passed; typecheck, lint and production build passed. Build retained the existing large-chunk advisory. Impeccable returned `[]` for changed UI paths. Full backend and final cleanup results are recorded in the PR.

## Round 2 review fixes — November 2, 2026

Scope and authority: Leon's PR #416 round-2 brief; existing source at `3717c7ab`; same branch and worktree, held for November 7. The original product brief and domain sources above still apply. No staging or production data was accessed.

Required outcomes (agent executed):

- Existing missing filing fields remain editable; completed fields cannot be cleared through the employee form or client direct-update service.
- Previously approved runs retain their approval history through unapproval/recalculation and cannot be deleted. The error tells the operator to keep and correct the run or ask an admin.
- Runs with source hours deferred to a later run remain recorded; the error identifies the target run by ID and period dates.
- Source objects purge through `R2StorageService` only after commit. Rollback keeps the object; purge failure logs without changing the committed deletion.
- Existing newest-first/inverse destroy chain, period lock/recheck, and financial/audit restrictions remain in place.

D3 real UI acceptance passed in local Playwright Chromium at 1440×900 and 390×844, using synthetic records and a dated synthetic W-4. Jamie Incomplete's missing SSN/hire date/address remained optional with the warning; wage changed from $25 to $28 on desktop and $29 on phone, confirmed after reload and in PostgreSQL. Casey Completed's filled hire date and address were required; attempted clearing was blocked with field guidance. Reload and database checks retained the original `2024-01-01` hire date and `123 Marine Corps Dr` address. No physical-phone or real authentication-provider certification. Desktop checked both hire date and address; phone checked address protection.

The collaborative browser opened but twice failed inspection with `Preview automation snapshot timed out after 15000ms.` It was closed before using Playwright. Evidence: `D3-round2-incomplete-saved.png`, `D3-round2-filled-hire-blocked.png`, `D3-round2-filled-address-blocked.png`, `D3-round2-phone-incomplete-saved.png`, `D3-round2-phone-filled-blocked.png`. Browser/Chromium, Rails and Vite stopped after this phase.

Frontend typecheck, lint, all 140 files / 1,372 tests and production build passed. Build used CI's explicit `DEPLOYMENT_ENV=production VITE_DEPLOYMENT_ENV=production` flags and retained the existing chunk-size advisory. Impeccable returned `[]`. RuboCop, Brakeman and bundler-audit passed. Final full RSpec and external check results are recorded in the PR follow-up and local handoff.
