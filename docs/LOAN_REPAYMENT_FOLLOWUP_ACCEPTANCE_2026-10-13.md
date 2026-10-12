# Loan repayment follow-up acceptance — October 13, 2026

Base: main `dd06ee90`, following PR #311. Scope: named loan repayments, separate standalone deductions, and saved repayment defaults between calculation and finalization. Agent executed affected-flow QA on isolated synthetic databases. Production payroll and payment records were inspected read-only and were not changed.

Cornerstone staff enter or import reviewed wages, calculate and approve a run, then commit its accounting effects. Printing, issuance and clearing are distinct payment events. Loan balances move at commit, not calculation. A standalone deduction changes net pay but has no loan identity. A named repayment credits only its selected loan. This follow-up preserves those distinctions.

The review reproduced two remaining problems: worksheet calculation/approval rejected a valid separate deduction alongside a tracked repayment, and a changed assignment or field-definition default could escape the stale schedule check when the loan had no stored payment amount. Explicitly skipping a named repayment also incorrectly blocked an unrelated standalone deduction.

The follow-up permits calculated combinations and explicit zero skips while retaining the missing-ledger guard. It snapshots the effective default and rejects changed defaults before posting. Older default snapshots without an authoritative loan amount require recalculation. Posting locks the loan's schedule and definition rows; bulk edits acquire the company lock first to match payroll commit and avoid reverse-order deadlocks.

| Case | Expected observable and saved outcome | Coverage | Result |
|---|---|---|---|
| L13-1 | Choose $300 named repayment, enter $40 separate deduction, calculate/approve/commit one employee; $1,053.15 net, one $300 ledger payment, $2,959.97 balance | Real desktop browser; native Chrome saved ledger | passed |
| L13-2 | Explicitly skip named repayment with $0, enter $40 separate deduction and commit; $1,353.15 net, no ledger payment, $3,259.97 balance | Responsive 390×844 browser | passed |
| L13-3 | Change assignment default from $300 to $200 after approval; reject commit without ledger/check effects, recalculate, then post $200 once | Backend integration | passed |
| L13-4 | Change fallback definition default after approval; same rejection and recovery | Backend integration | passed |
| L13-5 | Older default snapshot lacks effective amount and loan amount is blank; require recalculation | Backend integration | passed |
| L13-6 | Assignment and definition edits compete with posting; edits wait until posting completes | Actual PostgreSQL concurrency | passed |
| L13-7 | Real bulk API edits two schedules in reverse order while payroll posts; request waits, then saves both defaults without deadlock | API and PostgreSQL concurrency | passed |
| L13-8 | Missing named repayment with anonymous deduction remains blocked; existing named, capped, refresh, void, reopen and delivery guards remain valid | Backend and ten real-stack browser cases | passed |

The original browser attempt stopped at workspace loading while the full gates ran concurrently. The unchanged fixture then passed all ten cases; initial failure evidence is retained privately. An in-app browser confirmation stalled computer control after calculation/approval; native Chrome completed the same saved fixture through finalization and verified the single ledger payment. This is a browser-control limitation, not a claim that the first native attempt completed.

Physical phone keyboards, installed PWA behavior, real payment transmission, historical FIT reconciliation and comprehensive AIRE integration acceptance are outside this focused run. No live repayment or historical paycheck was rewritten. Separate deductions remain separate from loan balances.

Validation at PR preparation: 422 frontend tests plus type checking, lint and build passed; ten real-stack loan/correction browser cases passed; 27 targeted backend/default/race cases passed. The final full backend and public-browser gates, PR review, release commit and resource disposition are recorded in the PR follow-up. Seven changed Ruby files are lint clean; the repository retains existing global lint debt.
