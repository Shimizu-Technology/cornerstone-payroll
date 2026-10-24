# PR B source action baseline and move checklist

Owner: payroll-redesign. Baseline: `922b089015c481d60b543cf1e36164699e8f44cd` (PR A merge). Inspected source only; no browser/runtime/database changes. Current parent-owned test edits were excluded by reading baseline content from Git. This checklist supplements the per-state browser inventory; it does not claim that every guarded action occurs in the seven captured states.

All paths below are relative to `web/src/`. Proposed destinations are a preservation checklist, not a claim that the implementation already moved them.

## Checks implementation seam: concrete risks

- [ ] Restore `Check Settings ›` (`pages/pay-periods/pay-run/PayRunChecks.tsx:33`, `/check-settings`) if replacing the processing section with Workspace's existing Checks implementation. Workspace does **not** contain this link.
- [ ] Preserve the processing `ChecksPanel`'s `searchTerm` functionality. Workspace currently passes no search term. The parent panel uses that prop to filter the employee check list; its separate earnings-statement search does not replace that filter. Add a Checks search input or deliberately carry the existing filter into this tab, and inventory its destination.
- [ ] Mount a single employee `ChecksPanel`, `NonEmployeeChecksPanel`, and `UnifiedCheckPrintDialog` per run. Keeping extracted processing sections plus Workspace Checks duplicates all three, the print queue, loaded lists, and potentially financial-action entry points.
- [ ] Keep the richer Workspace implementation: rehearsal VOID preview, promoted record-only unpaid recovery, payment method change callbacks, mobile payment cards, desktop payment table, full-record dialog, and latest-request-wins summary reload. The processing section alone cannot replace these functions.
- [ ] Coordinate refresh ownership. Original processing check callbacks await `loadPayPeriod(..., true)` and throw if reload fails; Workspace catches summary-refresh failure and shows a notice. Both preserve saved actions but differ in error propagation. Keep source invalidation and refreshed totals/results after check actions, method changes, printing, and non-employee changes.
- [ ] Preserve committed print eligibility: active payroll check OR known active non-employee check. Workspace starts non-employee knowledge as `null`, performs a print-queue lookup, and updates it from panel loads. Do not enable printing on unknown/failed queue data.
- [ ] Keep read-only/rehearsal gates. Workspace does not mount operational Checks/NonEmployee/Print panels for read-only or rehearsal contexts; reviewer rehearsal preview is intentionally allowed. Baseline processing sections render on committed status and rely on inner permission checks. The new unified route must retain Workspace's stronger workspace guard.
- [ ] Move **both** `AirePaymentEvidenceHolds` and `AireManualPaymentReconciliation` into Checks; neither is in Workspace Checks today. Preserve `#manual-time-reconciliation`, source refresh token, and `invalidateAireSource(); loadPayPeriod(id, true, true)` callbacks.
- [ ] Keep the uncommitted payment-method entry point. SupportingDetails currently offers `Change payment method` for each payable item before commit. Workspace offers changes according to `payRunPaymentDisplay(...).canChange`; verify calculated/draft/approved non-voided cases explicitly rather than assuming the panels have identical guards.

## Workspace actions and routing

| Existing location | Actions / labels | Guard or behavior | B destination |
| --- | --- | --- | --- |
| Workspace load failure | `Try again`, `Back to pay runs` | Failed run lookup; retry the same scoped request; return context preserved | Same error state |
| Header | `Back`, `Open processing` | Open processing only writer and active tab not work; preserves `return_to` | Header Back; next action / Payroll link |
| Tabs | `Overview`, `Process payroll`, `Checks & direct deposit`, `Activity` | Baseline hides work for all read-only; Checks remains for workspace-access reviewer only | `Payroll`, `Checks & payments`, `Reports`, `Activity`; overview alias must preserve return context and hash |
| Overview | Employee-name links; `Open payroll item for {name}` (visible `Open`); `Process payroll`; empty `Process payroll` | Open payroll item allowed writer or workspace-access reviewer; sealed baseline/backup disallow it; employee links preserve return | Writer Payroll results / read-only Payroll summary; do not remove read-only item dialog |
| Checks payment list | Employee-name links; `Change payment method for {name}`; phone `Open record`, desktop `Open`; `Review payment methods and amounts` disclosure | Method change only non-read-only and `display.canChange`; committed operational list collapsed into disclosure | Checks |
| Checks rehearsal | `Preview rehearsal checks`; PDF preview Print/Download/Close | Rehearsal + calculated/approved; disabled busy or no positive-net paper checks; includes read-only reviewer preview | Checks |
| Checks promoted unpaid | `Prepare checks for payment`; dialog `Cancel`, `Assign check numbers` | Non-rehearsal committed promoted record-only with no active checks; admin; preview eligible; explicit unpaid confirmation/date/number; no duplicate financial posting | Checks |
| Checks normal | `Print checks` | Non-read-only, non-rehearsal, committed; disabled if neither active employee nor active non-employee checks | Checks |
| Checks / Activity empty | `Back to overview` | Must resolve through alias, preserve workspace return context | Payroll alias/link |
| Activity | RecordActivityTimeline `Try again`, `Load older activity` / `Try loading older activity again`, audit-detail disclosures; milestone list | Full per-record change history plus lifecycle timestamps retained | Activity |

## Processing header / overflow

| Original action | Existing guard / disabled reason | B location |
| --- | --- | --- |
| `View linked time record` | Linked AIRE record exists; opens retained record dialog | Header overflow |
| `Review checks and payments` | Committed and not voided | Filled primary to Checks & payments |
| `Link time tracking record` | Committed, not voided, `canLinkAireRecord`, no linked record; opens import modal without auto-preview | Header overflow |
| `Correct Pay Date` | Committed and not voided; clerical correction dialog | Header overflow |
| `Import (MoSa)` | Editable run and source type `mosa_revel` | Header overflow |
| `Import Spike Email` | Editable run and source type `spike_email` | Header overflow |
| `Review & add hours` / `Import time tracking` | Draft, editable, at least one active time-tracking source | Filled primary when source coverage missing; otherwise overflow / Hours entry |
| `Refresh current setup` | Editable, existing payroll items; disabled processing, saved-import reload required, staged worksheet edits; staged-edit reason remains visible | Header overflow |
| `Calculate Payroll` | Draft; disabled processing or financial hold; missing source routes through explicit acknowledgement/reason dialog | Filled primary after source coverage; alternate calculation remains available when source missing |
| `Recalculate` | Calculated; disabled processing or financial hold | Header overflow |
| `Approve` | Calculated; disabled processing/financial hold/standalone loan conflict/calculation failure/no items/pending changes/required client review not approved | Filled primary with same reason |
| `Roll Back Approval` | Approved; disabled processing | Header overflow |
| `Commit & Finalize` | Approved, not parallel; disabled processing or financial hold; opens PayrollCommitDialog | Filled primary; parallel remains blocked with reason |

Editable means `!isCommitted && !isVoided && !savedImportReloadRequired`. Preserve handler-level guards in addition to rendering predicates. The source acknowledgement dialog retains `Cancel` and `Calculate without imported hours`, disabled until reason and acknowledgement exist. Refresh setup retains `Cancel` and `Refresh and recalculate`. Pay-date dialog retains `Cancel` and `Save Pay Date Correction`. Client approval dialog retains `Cancel` and `Record Email Approval` (loading variant), with authorized approver/evidence/explicit-confirmation prerequisites. Commit dialog and all import/correct/replace dialogs remain mounted once and retain their internal confirmation, cancellation, retry, and close controls.

## Payroll actions that remain in Payroll for B

| Original section | Labels / interactions to preserve | Conditions |
| --- | --- | --- |
| Feedback | `Review affected employees`, `Reload saved payroll`, `Try again` | Calculation failures; saved-import reload hold; missing controller data; reload disabled during processing/import |
| Blockers | `Record Email Approval`, `Review current source`, `Review settings`, `Use confirmed workweek` | Pending client revision; stale intake + eligible importer; compliance warning; employer-confirmed workweek available. Same explanatory text and loading guards |
| Source checkpoint | Existing cockpit disclosures, source refresh/review/finalize, time/overtime approve/deny, source corrections, mapping, settlement routing, pagination and dialogs | Regular connected run; preserve source grants/readiness/permission/epoch guards. Keep late-hours seam in this Hours/source area |
| Roster | `Enter pay`, `Remove from this run`, `Calculate with {n} added`, `Recalculate with {n} added` | Calculated or special draft; employees missing an item and not explicitly excluded; add count > 0 for calculate action; financial hold/processing block calculate |
| Worksheet | Expand/collapse `Payroll Entry`; employee links; `Review paycheck`; `+ Tips & Deductions` / `Tips & Deductions ✓`; `+ Payroll Fields ({n})` / `Payroll Fields ({n}) ✓`; `Use employee default`; `Clear this payroll amount` | Draft/calculated; recurring-exclusion and field editability guards; imported source hours and correction pay-basis holds stay locked |
| Worksheet controls | Employee type, Department, Sort, Search employees; hours/pay/bonus/tips/loans/named loans/payroll fields | Preserve all input values, filters and unsaved edits across tab navigation; mobile and desktop duplicate presentations represent same actions |
| Employee results | Employee links; `View details`; `Edit payroll` (phone) / edit-icon action (desktop); `Correct`; `Replace check`; Employee type/Department/Sort/Search employees | Edit calculated; Correct committed non-contractor + server `can_issue_corrective_paycheck`; Replace committed non-contractor, nonsupplemental, nonvoided check with number. Keep dialogs/saved reload callbacks |
| Comparison | `Retry comparison` | Items exist, nonsupplemental, calculated/approved/committed, failed comparison; disabled loading |
| Empty | `Add employee` | Draft with no eligible employees and no payroll items; scoped return link |
| Timecard OCR | All upload/process/review/apply/discard/close controls in TimecardOcrPanel | Draft only; preserve onPayrollUpdated callback |

Do not include compact-result/step-collapse changes in B. Lead explicitly deferred first-screen employee-name/net acceptance to C. B still must report totals/results Y and scroll height before/after.

## Checks & payments nested action preservation

These controls live inside the moved panels and should move intact; do not recreate their financial logic in the header.

- [ ] Employee ChecksPanel: `Retry`; `Review time tracking sync`; `Confirm bank payment`; `Print all earnings statements` / `Print {n} selected statement(s)`; `Download all earnings statements` / `Download selected statements`; `Print direct-deposit statements`; `Download direct-deposit statements`; Select visible checkbox; `Clear selection ({n})`; statement row `Change method`, `View`, `Print`, `Download`; check-number `Discard`, `Save check numbers`; check row `Preview` / `Void PDF`, `Stub`, `Record Issued`, `Reissue`, `Void`, `Reverse paycheck`; preview `Print Stub`, `Download Stub`; shared print/PDF, delivery/reissue/void/reverse/bank-payment dialogs and all cancellation/confirmation controls.
  Guards: company write access, statement-only status, active/voided state, payroll inclusion, check number, prepared/printed status, source payment blocker, per-item loading, saving-number errors. Printing/previewing does not issue payment.
- [ ] NonEmployeeChecksPanel: check-stock starting slot; copy helper (`Copy` / copied state); `Generate FIT Check` / `Assign FIT number`; `+ Add Check` / `Cancel`; number `Discard`, `Save check numbers`; `Create Check`; `Open GuamTax`; `GRT filing help` / `GRT help`; `BPT e-file guidance`; `Open saved Form 500`; `All DRT Forms`; `Reload checks`; per-check history toggle; `Preview`, `Print`, `Edit`, `Void`, `Confirm`, `Cancel`, `Delete`; nested edit/Form500/PDF controls.
  Guards: voided run, list unavailable, operation busy, existing FIT check, valid number edits. Delete only unprepared/unprinted/nonvoided; edit/void only nonvoided. Keep Form500 detection based on auto-generated FIT marker with legacy fallback.
- [ ] Unified print dialog: `All checks`, `Employees`, `Non-employees`; status filter; `Select not prepared` / `Select visible`, `Clear`, `Show all checks`; check selection and number entry; `Discard`, `Save check numbers`; profile `Manage`, `Retry printer profiles`, `Choose or create a printer profile before generating.`; slots 1–4; `Enlarge`, `Retry preview`; `Open saved PDF to print`, `Download`; `Audit details`; saved `Package #{id} · {n} checks`; `Close`; `Generate and save package`; `Generate replacement package`; `Create another package`; expanded preview `Return to package`; unsaved-number/discard/replacement confirmation and profile-manager controls.
  Guards: queue known, printer profile exists, selected checks, no unsaved/errors/saving, generation locks; print requires verified saved artifact and prepared/confirmed package. Do not conflate package generation with issued status.
- [ ] Payment method dialog: `Try again`, `Cancel`, `Save payment method` / `Record cancellation and save`; source-blocker/cancellation acknowledgements and readiness remain; read-only disables mutation.
- [ ] Payment evidence holds: `Refresh payment evidence`; `Match existing payment`; `Retract hold`; `Original reported-payment evidence`; `Retry saved match`; resolved-report disclosure; `Confirm existing payment match`; `Confirm retraction`; `Record reported-payment hold`; `Cancel match review`; `Cancel retraction`.
  Guards: source resolution access/context available, no pending report, valid current selection/exact capacity, 20-character reason, no loading/busy; preserve retained evidence and retries.
- [ ] Manual reconciliation: `Refresh reconciliation`; `Connect my time tracking account`; `Payroll item {id}`; `Refresh status for entry {id}` / `Retry sync for entry {id}`; `Link hours to payroll item`.
  Guards: own linked source account, canManage, nonvoided allocation, complete validated form/canSubmit, no loading/busy. Preserve active-company and return-context links.

## Reports nested action preservation

- [ ] Final Payroll Record (committed): `View record`; `Export final payroll record` menu → `Excel workbook (.xlsx)`, `PDF record (.pdf)`; `Reload final payroll record`; `Close final payroll record`; `Close`; statement/source/liability detail disclosures. Disabled while loading or record absent; stale context guards retained.
- [ ] ReportsDownloadPanel (not draft + items): all eight cards: Payroll Register, Payroll Summary by Employee, Deductions & Contributions, Paycheck History, Retirement Plans Report, Transmittal Log, Employee Installment Loans, Full Print Package.
- [ ] Each report retains `View`, saved-cover `Edit`, `Download` menu. Register formats `Excel register (.xlsx)` / `Detailed PDF (.pdf)`; other spreadsheet-capable cards `Excel spreadsheet (.xlsx)` / `PDF document (.pdf)`; Transmittal Log/Full Print Package PDF-only. Keep per-report busy state and saved-cover revision behavior.
- [ ] Check Sign-Off Sheet retains `Edit` (when saved), `View`, `Download`; editor include/exclude all, reset to payroll, row remove/add employee, note remove/add, `Cancel`, generate action; retained PDF preview Print/Download/Close.
- [ ] Cover/transmittal editors retain check-number add/remove, custom detail add/remove, notes add/remove, report add/remove, saved Form500 link and DRT forms, `Retry cover details`, `Cancel`, generate action, close; report/PDF previews retain Print/Download/Close and format menus. Preserve all saved inputs, initialization and generation guards.
- [ ] Payroll liabilities (committed) retain reconciliation detail disclosure; no direct mutation button was found in PayrollLiabilityPanel.

## Activity / overflow nested action preservation

- [ ] Metadata `Retry Tax Sync` → Activity; committed sync failed/pending, disabled while retrying. Keep tax attempts/error and pay-date correction evidence.
- [ ] `Run notes and processing history` disclosure → Activity; notes and processing timeline retained alongside Workspace's RecordActivityTimeline/milestones (avoid needless duplicated lifecycle lists).
- [ ] Timecards (not draft): `Show Timecards` / `Collapse All`; individual employee/timecard disclosure; `View Full Image` / `Collapse Image`; `Rotate Left`, `Rotate Right`, nonzero-rotation `Reset` → Activity.
- [ ] Linked Corrections: `Supplemental period · pay date {date}` (committed nonsupplemental, has supplementals) and `the original committed period` (supplemental with parent) → Activity; preserve return links and relevant Payroll summary link.
- [ ] CorrectionPanel → header overflow entry plus Activity: `Reopen unpaid payroll`; `Void This Pay Period` / `Void This Correction Run`; `Create Correction Run`; `Delete Draft Correction Run`; `View Correction History` / `Hide Correction History`; `View correction run →`; `source period #{id}`; linked history run buttons; financial-source connection flow; preflight review, cancellation and confirmation dialog actions.
  Guards: server `can_void`, `can_create_correction_run`, `can_delete_draft_correction_run`; any action in flight disables actions; preflight can block reopen/void; typed confirmation/unpaid acknowledgements/reasons/date constraints retained. Reopen and corrective-run navigation preserve `return_to`.

## Automated direct-source inventory

The table below is extracted from **Git HEAD baseline**, not edited files. It covers all direct Button/button/Link/a/summary/role-button nodes in PayRunWorkspace plus the extracted pay-run modules. Dynamic JSX labels and disabled expressions remain source expressions to avoid hiding conditional variants. Nested moved panels are grouped above. This is a source checklist; the parent must still produce a runtime, per-state before/after inventory with explicit moved destinations.

Direct control definitions: **79** (responsive duplicates intentionally retained).

| Baseline file:line | Tag | Label / aria-label expression | Disabled expression |
| --- | --- | --- | --- |
| `pages/pay-periods/PayRunWorkspace.tsx:175` | `Button` | `Try again` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:175` | `Link` | `Back to pay runs` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:202` | `Link` | `Back` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:202` | `Link` | `Open processing` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:285` | `Link` | `Process payroll` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:287` | `Link` | `{item.employee_name}` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:287` | `button` | `{'Open payroll item for ${item.employee_name}'}` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:459` | `Link` | `{item.employee_name}` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:469` | `Button` | `{'Change payment method for ${item.employee_name}'}` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:470` | `button` | `Open record` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:484` | `Link` | `{item.employee_name}` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:493` | `Button` | `{'Change payment method for ${item.employee_name}'}` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:495` | `button` | `Open` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:530` | `Button` | `Prepare checks for payment` | `{paymentPreviewBusy \|\| !paymentPreview?.eligible}` |
| `pages/pay-periods/PayRunWorkspace.tsx:550` | `Button` | `{mockPreviewBusy ? 'Preparing…' : 'Preview rehearsal checks'}` | `{mockPreviewBusy \|\| mockPreviewEligible === 0}` |
| `pages/pay-periods/PayRunWorkspace.tsx:555` | `Button` | `Print checks` | `{countActivePayrollChecks(items) === 0 && hasNonEmployeeChecks !== true}` |
| `pages/pay-periods/PayRunWorkspace.tsx:567` | `summary` | `Review payment methods and amounts` | `—` |
| `pages/pay-periods/PayRunWorkspace.tsx:631` | `Button` | `Cancel` | `{paymentBusy}` |
| `pages/pay-periods/PayRunWorkspace.tsx:632` | `Button` | `{paymentBusy ? 'Preparing checks…' : 'Assign check numbers'}` | `{readOnly \|\| paymentBusy \|\| !paymentStartingNumber \|\| !paymentCheckDate \|\| !paymentConfirmed}` |
| `pages/pay-periods/PayRunWorkspace.tsx:684` | `Link` | `{actionLabel}` | `—` |
| `pages/pay-periods/pay-run/PayRunBlockers.tsx:56` | `Button` | `{clientApprovalLoading ? 'Loading…' : 'Record Email Approval'}` | `{clientApprovalLoading}` |
| `pages/pay-periods/pay-run/PayRunBlockers.tsx:75` | `Button` | `Review current source` | `—` |
| `pages/pay-periods/pay-run/PayRunBlockers.tsx:96` | `Link` | `Review settings` | `—` |
| `pages/pay-periods/pay-run/PayRunBlockers.tsx:105` | `Button` | `{adoptingConfirmedWorkweek ? ( Applying… ) : 'Use confirmed workweek'}` | `{adoptingConfirmedWorkweek}` |
| `pages/pay-periods/pay-run/PayRunChecks.tsx:33` | `Link` | `Check Settings ›` | `—` |
| `pages/pay-periods/pay-run/PayRunChecks.tsx:34` | `Button` | `Print checks` | `{paperCheckCount === 0 && !nonEmployeeChecks.some((check) => !check.voided)}` |
| `pages/pay-periods/pay-run/PayRunComparison.tsx:56` | `Button` | `Retry comparison` | `{comparisonLoading}` |
| `pages/pay-periods/pay-run/PayRunDialogs.tsx:236` | `Button` | `Cancel` | `{clientApprovalLoading}` |
| `pages/pay-periods/pay-run/PayRunDialogs.tsx:237` | `Button` | `{clientApprovalLoading ? 'Recording…' : 'Bind Approval to This Revision'}` | `{clientApprovalLoading \|\| clientApprovers.length === 0 \|\| !clientApproverId \|\| !clientApprovalEvidence.trim() \|\| !clientApprovalConfirmed}` |
| `pages/pay-periods/pay-run/PayRunDialogs.tsx:292` | `Button` | `Cancel` | `{payDateCorrectionSubmitting}` |
| `pages/pay-periods/pay-run/PayRunDialogs.tsx:300` | `Button` | `{payDateCorrectionSubmitting ? 'Saving...' : 'Save Pay Date Correction'}` | `{payDateCorrectionSubmitting}` |
| `pages/pay-periods/pay-run/PayRunEmployeeResults.tsx:149` | `Link` | `{item.employee_name}` | `—` |
| `pages/pay-periods/pay-run/PayRunEmployeeResults.tsx:161` | `button` | `View details` | `—` |
| `pages/pay-periods/pay-run/PayRunEmployeeResults.tsx:162` | `Button` | `Edit payroll` | `—` |
| `pages/pay-periods/pay-run/PayRunEmployeeResults.tsx:163` | `Button` | `Correct` | `—` |
| `pages/pay-periods/pay-run/PayRunEmployeeResults.tsx:164` | `Button` | `Replace check` | `—` |
| `pages/pay-periods/pay-run/PayRunEmployeeResults.tsx:247` | `Link` | `{lastName \\|\\| '—'}` | `—` |
| `pages/pay-periods/pay-run/PayRunEmployeeResults.tsx:313` | `button` | `Open payroll item` | `—` |
| `pages/pay-periods/pay-run/PayRunEmployeeResults.tsx:544` | `button` | `Edit` | `—` |
| `pages/pay-periods/pay-run/PayRunEmployeeResults.tsx:568` | `button` | `Correct` | `—` |
| `pages/pay-periods/pay-run/PayRunEmployeeResults.tsx:577` | `button` | `Replace` | `—` |
| `pages/pay-periods/pay-run/PayRunEmptyState.tsx:22` | `Link` | `Add employee` | `—` |
| `pages/pay-periods/pay-run/PayRunFeedback.tsx:31` | `Button` | `Review affected employees` | `—` |
| `pages/pay-periods/pay-run/PayRunFeedback.tsx:40` | `Button` | `Reload saved payroll` | `{processing \|\| timeTrackingImportOpen}` |
| `pages/pay-periods/pay-run/PayRunHoursWorksheet.tsx:90` | `Link` | `Review paycheck` | `—` |
| `pages/pay-periods/pay-run/PayRunHoursWorksheet.tsx:95` | `div` | `{isCalculated ? 'Adjust Hours' : 'Enter Hours'} {!hoursTableOpen && ( Click to expand )} {hoursTableOpen && ( e.stopPropagation()}> setEmployeeTypeFilter(event.target.value as typeof employeeTypeFilter)} className="w-full sm:w-36" > All Types Salary Hourly 1099 setDepartmentFilter(event.target.value)} className="w-full sm:w-44" > All Departments {departmentOptions.map(([deptId, deptName]) => ( {deptName} ))} { const [sortBy, direction] = event.target.value.split(':') as [typeof hoursSortBy, typeof hoursSortDirection]; setHoursSortBy(sortBy); setHoursSortDirection(direction); }} className="w-full sm:w-44" > Name A-Z Name Z-A Rate High-Low Rate Low-High Hours High-Low Hours Low-High Est. Gross… [compound content; see source]` | `—` |
| `pages/pay-periods/pay-run/PayRunHoursWorksheet.tsx:167` | `button` | `{showTipsLoans ? 'Tips & Deductions ✓' : '+ Tips & Deductions'}` | `—` |
| `pages/pay-periods/pay-run/PayRunHoursWorksheet.tsx:184` | `button` | `{showPayrollFields ? 'Payroll Fields (${worksheetPayrollFields.length}) ✓' : '+ Payroll Fields (${worksheetPayrollFields.length})'}` | `—` |
| `pages/pay-periods/pay-run/PayRunHoursWorksheet.tsx:238` | `Link` | `{name}` | `—` |
| `pages/pay-periods/pay-run/PayRunHoursWorksheet.tsx:257` | `button` | `{payPeriod.includes_recurring_items === false ? 'Clear this payroll amount' : 'Use employee default'}` | `—` |
| `pages/pay-periods/pay-run/PayRunHoursWorksheet.tsx:341` | `Link` | `{emp.first_name} {emp.last_name}` | `—` |
| `pages/pay-periods/pay-run/PayRunHoursWorksheet.tsx:605` | `button` | `{payPeriod.includes_recurring_items === false ? 'Enter an amount or clear this payroll amount' : 'Enter an amount or use the employee default'}` | `—` |
| `pages/pay-periods/pay-run/PayRunHoursWorksheet.tsx:613` | `button` | `{payPeriod.includes_recurring_items === false ? 'Override · clear this payroll amount' : 'Override · use ${defaultLabel}'}` | `—` |
| `pages/pay-periods/pay-run/PayRunLinkedCorrections.tsx:42` | `Link` | `Supplemental period · pay date {sp.pay_date}` | `—` |
| `pages/pay-periods/pay-run/PayRunLinkedCorrections.tsx:86` | `Link` | `the original committed period` | `—` |
| `pages/pay-periods/pay-run/PayRunMetadata.tsx:71` | `Button` | `{retryingSyncTax ? 'Retrying...' : 'Retry Tax Sync'}` | `{retryingSyncTax}` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:60` | `Button` | `View linked time record` | `—` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:64` | `Link` | `Review checks and payments` | `—` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:66` | `Button` | `Link time tracking record` | `—` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:73` | `Button` | `Correct Pay Date` | `—` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:81` | `Button` | `Import (MoSa)` | `—` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:86` | `Button` | `Import Spike Email` | `—` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:91` | `Button` | `{needsSourceCoverageAcknowledgement(payPeriod) ? 'Review & add hours' : 'Import time tracking'}` | `—` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:102` | `Button` | `Refresh current setup` | `{processing \|\| savedImportReloadRequired \|\| hasStagedWorksheetChanges}` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:120` | `Button` | `{processing ? 'Calculating...' : 'Calculate Payroll'}` | `{processing \|\| financialActionsHeld}` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:127` | `Button` | `Recalculate` | `{processing \|\| financialActionsHeld}` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:130` | `Button` | `Approve` | `{processing \|\| financialActionsHeld \|\| standaloneLoanConflicts.length > 0 \|\| calculationFailures.length > 0 \|\| payrollItems.length === 0 \|\| hasPendingCalculationChanges \|\| (payPeriod.client_payroll_approval_required === true && payPeriod.payroll_review?.status !== 'approved')}` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:150` | `Button` | `Roll Back Approval` | `{processing}` |
| `pages/pay-periods/pay-run/PayRunProcessingActions.tsx:155` | `Button` | `{processing ? 'Committing...' : 'Commit & Finalize'}` | `{processing \|\| financialActionsHeld}` |
| `pages/pay-periods/pay-run/PayRunRoster.tsx:50` | `button` | `{'Remove ${emp.first_name} ${emp.last_name} from this run'}` | `—` |
| `pages/pay-periods/pay-run/PayRunRoster.tsx:62` | `button` | `Enter pay` | `—` |
| `pages/pay-periods/pay-run/PayRunRoster.tsx:80` | `Button` | `{isDraft ? 'Calculate' : 'Recalculate'} with {additionalEmployeeIds.size} added` | `{processing \|\| financialActionsHeld}` |
| `pages/pay-periods/pay-run/PayRunSupportingDetails.tsx:52` | `Button` | `{'Change payment method for ${item.employee_name}'}` | `—` |
| `pages/pay-periods/pay-run/PayRunSupportingDetails.tsx:74` | `summary` | `Run notes and processing history` | `—` |
| `pages/pay-periods/pay-run/RefreshSetupDialog.tsx:49` | `Button` | `Cancel` | `{processing}` |
| `pages/pay-periods/pay-run/RefreshSetupDialog.tsx:50` | `Button` | `{processing ? 'Refreshing…' : 'Refresh and recalculate'}` | `{processing}` |
| `pages/pay-periods/pay-run/SourceCoverageDialog.tsx:42` | `Button` | `Cancel` | `—` |
| `pages/pay-periods/pay-run/SourceCoverageDialog.tsx:43` | `Button` | `Calculate without imported hours` | `{!sourceCoverageAcknowledged \|\| !sourceCoverageReason.trim() \|\| processing}` |
| `pages/pay-periods/pay-run/usePayRunController.tsx:1033` | `Button` | `Try again` | `—` |
