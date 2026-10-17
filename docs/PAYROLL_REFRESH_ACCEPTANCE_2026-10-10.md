# Payroll setup refresh and unpaid correction acceptance

Scope: manual/native payroll setup refresh, named linked loan repayments, transactional check retirement and unpaid reopening. Historical payment reconciliation and a new supplemental withholding method are outside this software change.

Execution: agent-run synthetic local fixtures and browser journeys. No production payroll mutation is authorized by these tests. Desktop and responsive phone browser coverage are required below; physical phone/PWA keyboard behavior is not claimed.

Base: main c7d44fec. Tested integration: da0146f8 plus the fixture/CI/test-only changes saved with this acceptance record. Application source was unchanged during the final backend run except a result-column wording clarification verified by frontend and browser tests. Native Chrome desktop and responsive 390×844 computer use ran against an independent synthetic database; automated browser fixtures used a different database. No customer payroll was changed.

| Case | Required journey and expected saved result | Coverage | Status |
|---|---|---|---|
| L01 | On a special run with recurring setup off, choose an existing named loan, calculate, approve and commit; one linked repayment, expected net, no unselected employee added | Desktop browser | passed |
| L02 | Repeat named loan entry through the employee card; visible balance, reachable controls, saved repayment and amount | Responsive phone browser | passed |
| R01 | Refresh an approved run after a loan is added; approval/client review withdrawn, entered hours/rate and roster preserved, current loan applied once | Desktop browser | passed |
| R02 | Unsaved input or invalid loan request cannot be lost by refresh/recalculation; clear recovery keeps entered values | Desktop and responsive phone | passed |
| V01 | One period void retires employee and automatic FIT checks, reverses loan/YTD/liabilities once, retains history and obsolete payment state | Desktop browser | passed |
| O01 | Reopen an unissued native committed run; fresh linked editable revision, original scope/hours, correct refreshed loan, new payment identities and no double posting | Desktop browser | passed |
| B01 | Delivered/paid/cleared evidence blocks void/reopen before any change; reason visible and source remains committed | Responsive phone browser and backend | passed |
| B02 | Cross-period liability payment, paid/filed tax evidence, direct deposit or later dependent payroll blocks unsupported automated correction atomically | Backend integration | passed |
| B03 | Finalized AIRE imports/entry allocations block automated reopening with an explicit reason until provenance revision support exists | Backend integration | passed |
| I01 | Cascade void produces original earned-row tax evidence with a distinct idempotency key; AIRE per-entry void callback preserved, no unsupported batch status | Backend integration | passed |
| P01 | Special-run comparison respects intended roster instead of flagging omitted company employees; regular missing-employee warnings retained | Backend and frontend tests | passed |
| T01 | Legacy transmittal FIT obligation includes stored additional withholding exactly once; current check/Form 500 totals remain consistent | Backend PDF/report test | passed |
| A01 | Accountant can perform payroll operations in their own client context; client/foreign-client access rejected | Backend requests | passed |

Engineering results: 3,614 backend examples; 418 frontend tests with type checking/lint/build; 107 public browser cases; 45 existing real-stack release cases; eight new real-stack payroll workflow cases, all passed. Brakeman reports zero warnings; Ruby and npm audits report zero vulnerabilities. Global RuboCop still reports 2,280 existing offenses (verified base had 2,282); new/changed behavior does not add lint debt. The full Ruby gate therefore retains that pre-existing lint limitation.

The desktop computer-use journey applied a named $300 repayment to $1,620.80 gross, $103.66 FIT and $1,093.15 net, then finalized and cascade-voided both employee/FIT checks; the loan balance returned from $2,959.97 to $3,259.97. Unpaid reopening produced a fresh linked draft and finalized with captured $16/hour even after the current profile changed to $18/hour. Approved refresh withdrew approval, preserved entered hours and applied the new recurring loan. Responsive phone computer use selected repayment, calculated and approved; automated responsive coverage also finalized and tested unavailable-loan recovery and delivered-payment blocking. Physical phone keyboards and installed PWA behavior were not tested.

Backend-only cases verify provider callbacks, atomic rollback, cross-period/filing/direct-deposit guards, authorization, financial reversal and transmittal amounts. Multi-rate real-stack browser coverage preserves captured $12/$20 rates after profile changes to $16/$30 and deactivation; endpoint tests additionally replay physically deleted original rates and reject foreign/invented IDs.

Independent review completed at 75789636 with no unresolved material findings after fixes. Repository-selected PR review, required CI checks, merge and deployment verification are recorded in the PR/release follow-up; local acceptance does not itself certify delivery.

Integration limits: Cornerstone Tax stores correction evidence; no claim is made that it automatically reverses a separate tax ledger. Finalized AIRE import reopening remains deliberately blocked. Tests simulate provider behavior and financial bookkeeping on disposable data, not actual payment transmission.

Lifecycle: task-owned native QA tab was closed and the original Messages tab restored; local QA servers and headless test workers were stopped. All newly started resources belong to session 01a11fc4-fcad-74d1-92a0-732f27ebdfd4 and cleaned after QA. Borrowed machine resources remain unchanged.
