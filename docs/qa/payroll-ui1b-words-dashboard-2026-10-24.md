# Payroll UI-1b: words, dashboard and source coverage

Owner: `payroll-impl-ui1b`. Base: `28b14349`. PR target: `staging-v2`; the integration lead owns merging. This is the first of two changes; draft money estimates follow separately.

Chels processes several Guam clients. AIRE owns time approval and locking; Payroll owns pay, calculation, approval, commitment and payment evidence. A clock reaching cutoff is not proof of locked hours. A scheduled source run with no imported hours needs a coverage warning, while manual and salary-only processing must remain possible.

The dashboard now starts with the earliest unfinished regular pay period, followed by other unfinished runs if no regular run exists. This prevents a later empty draft from displacing unfinished work. Draft totals are omitted. Calculated totals use saved amounts. The last regular payroll and last adjustment remain visible independently, including when adjustments fill the recent-history list. Imported history remains included.

## Action inventory

| Previous surface/action | Current action and destination |
|---|---|
| Continue pay cycle / Open period / Process payroll | Continue → selected pay run's Work tab; recent payroll links retain Overview |
| Create pay period | Create the next pay period → pay-period list/create flow |
| Manage Pay Periods / Run Payroll | Manage pay periods / Run payroll → same pay-period list |
| Add employee / Add Employee | Add employee link → same scoped employee form |
| Open reports / Guam Reports | Open reports link → same reports workspace |
| Read-only Browse Employees / Browse Pay Periods | Browse employees / Browse pay periods; no mutation prompts |
| Import Time Tracking | Review & add hours for scheduled runs awaiting import; Import time tracking otherwise; same import dialog |
| Calculate Payroll | Retained; missing source coverage requires a reason and acknowledgement before the request |
| Cutoff Refresh / Retry sync / publish/update | Retained with the same capability and state guards |
| Import mappings / review / apply / technical audit data | Retained; Hours and pay rates, plain entry counts; IDs/checksum in Technical details |
| Committed checks, reports, corrections, source history | Retained without moving panels or changing guards |

The removed hero, decorative KPI icons, and progress display supplied no unique action. Every destination remains reachable. Raw desktop/phone button/link inventories and before/after captures are in the evidence directory below.

## Verification

Agent-executed, isolated synthetic databases, Ruby 3.3.7 and Node 22.22.3. Desktop 1280×800 and browser phone viewport 390×844; browser timezone America/New_York verifies fixed ChST display. No real provider, payment, filing or production/staging access.

- API full suite: 5,019 examples, zero failures; final dashboard/audit regressions: five examples, zero failures. Schema/integrity, RuboCop (1,472 files; final changed API paths rechecked), Brakeman and bundler-audit passed.
- Web gate: 123 files / 1,141 tests passed, lint/typecheck/build passed; npm audit: zero vulnerabilities.
- Browser lanes: public 131, release 45, refresh 10, pay-items 23 passed. Initial failures and subsequent runs are retained: a renamed public selector, restored recent-history Overview destination, and one refresh five-second timing failure under machine load.
- Dashboard, connected draft, committed run, adjustment, runs 3/4, worksheet, and import checkpoint captured at both sizes. Required axe families clean at both sizes. Source warning requires both reason and acknowledgement; Escape/return focus verified. The shared dialog also includes notification controls in its focus cycle, as its existing contract specifies.
- A real manual flat-fee run with zero imports was calculated → approved → committed through the UI, reloaded on desktop and phone, and its coverage reason verified in AuditLog. Manual/salary roster, imported-state and source refresh unit/browser regressions remain covered.
- Import checkpoint rendering uses a synthetic preview contract; no fake batch was applied. The release lane separately verifies real import persistence and post-commit guards. Real AIRE transport and physical/native phone behavior are outside this check.
- Impeccable 4.6.0 advisory scan returned `[]`.

Evidence: `/Users/leonshimizu/Desktop/ShimizuTechnology/output/payroll-aire-review-2026-10-24/impl/payroll-ui1b/`. Key files: `pr1-complete-qa.json`, `before-qa.json`, `pr1-source-saved.json`, `pr1-source-audit.log`, `pr1-web-gate-accepted.log`, `pr1-api-gate-summary.log`, and the four final lane logs. Screenshots support the recorded interaction and saved-state checks; they do not certify live payroll.

No migration or calculator changes. The dashboard response gains purpose/action/coverage and separate history summaries; calculation accepts an optional source-coverage reason for audit metadata. Existing server financial guards remain authoritative. CodeRabbit status and final heads are recorded in the task RESULT.md.

Review follow-up: CodeRabbit completed a first review with eight small findings. Coverage copy now describes calculated/approved runs accurately; batch inclusion is separate from payment evidence; committed reconciliation says Hours by pay type because rates are hidden. Read-only and draft-money assertions now test the actual elements, elapsed cutoff minutes are asserted, and new test callbacks have explicit return types where requested. Final regression/gate evidence and review status are recorded in RESULT.md.
