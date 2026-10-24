# PR #384 review responses

Owner: `payroll-redesign`. These are owner fixes and verification; the lead must recheck them before merging. Reviewed starting head: `d0a3291b`. Application fixes: `0452f035` (phone) and `3e394380` (F1/F2).

## F1 — read-only Reports (P2)

`ReportsDownloadPanel` now accepts an explicit read-only contract, passed by the read-only workspace branch. It presents six permitted GET-backed reports: payroll register, employee summary, deductions/contributions, paycheck history, retirement plans and installment loans. Sign-off, transmittal, full print package and Form 500 editors and save-capable generation are excluded. Their metadata requests are skipped and generation handlers are guarded. Existing writer presentation remains the default.

Six regressions use the real ReportsDownloadPanel for direct `/reports` and Payroll → Reports entry in training baseline, backup snapshot and reviewer workspace access. They assert permitted reports, no writer controls, and no writer/metadata calls. Together with the restored-help regression, all seven failed before the fix. The focused three-file run passes 31 tests, including the existing six report-dialog handoff tests.

Real API permissions were also tested, without response overrides: three distinct synthetic test-workspace companies, an active accountant, reviewer/operator assignments, an approved included payroll item each, and baseline source lineage. Baseline records were created while the training workspace was pending; the workspace was then marked ready through normal model writes. [Twelve browser cases](review-qa-results.json) cover both entry routes at 1280×800 and 390×844. They record **27 successful GET previews, three verified PDF downloads, zero POST attempts and zero 403s**. [Saved-state receipt](review-saved-state-receipt.json) confirms unchanged pay periods, payroll items, transmittals, sign-off sheets, Form 500s and tax checks. Audit/user activity writes are excluded from that financial/document snapshot.

GET was not substituted for excluded writers: transmittal/full-package and some sign-off GET endpoints can save state and are forbidden in these workspaces. The six retained artifact types use the existing permitted read endpoints.

## F2 — parallel comparison explanation (P3)

The existing HelpTip is restored beside the header status with the original text: “This run is isolated from live payroll actions. It can be calculated and reviewed, but never committed, paid, printed, or filed.” Its regression failed before and passes after. An actual approved parallel run on a writable synthetic live company was captured against exact baseline `34c99bb2` and the fixed application: all four tabs at both widths retain one accessible **About parallel comparison** trigger and the same explanation. Commit remains disabled in B. Before/after inventories and screenshots accompany this report.

## Phone design findings

Desktop cell divider padding now applies only from `sm` upward. Each phone column shares a label/value left edge; order is Employees, Gross, Deductions, DRT, then full-width Net. Phone tabs read Payroll · Checks · Reports · Activity, retain full accessible labels/counts and active-tab scroll positioning, and stay inside their own bounded scroll row. Eight browser geometry checks and the release-lane assertions verify these conditions. Both seven-state contact sheets and all 56 tab captures were refreshed. See [PHONE-REVIEW.md](PHONE-REVIEW.md).

## Gate observations and limits

Full web gate: 126 files / 1,189 tests, type/lint/build pass. Four browser lanes: public 131, release 45, refresh 10, pay-items 24; no final failures/skips. API gate is reused against its unchanged tree: 5,090 examples, zero failures/pending; RuboCop 1,481 files / zero offenses and schema/integrity/security checks pass. Thirty axe scans have zero required #377-family violations. Legacy-results advisories remain recorded for C; Impeccable 4.6.0 returns no findings.

Verification exposed test-readiness races. Dashboard request handlers now drain before browser context teardown; the standalone deduction journey awaits calculate/approve/commit responses before persisted-state assertions; the recurring deduction journey awaits Pause/Resume/Stop saves; the notification focus test waits for initial navigation focus before dismissal. Payroll amount, status, focus and balance assertions remain. Red logs and saved-state receipts are retained in task output. No global timeout or application financial behavior changed for these repairs.

First-screen employee name/net and compact results/collapsed steps remain explicitly pending C. Physical devices/printer, real provider/payment/filing/email calls, late-hours financial execution and the separate two-app certification lane were not executed. The lead’s final independent recheck and current-head CI remain external merge gates. CodeRabbit’s one requested review was rate-limited; no bot approval is claimed.
