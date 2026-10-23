# Pay-period and AIRE workflow acceptance — October 23, 2026

## Scope and release boundary

Accountants need to review payroll, resolve source exceptions, prepare reports and checks, and distinguish commitment, preparation and payment. This change addresses Leon's retained desktop QA findings and simplifies the pay-run workspace. The implementation started from staging-v2 `50f9a2af57664bbb0fe6bb9a42f26c8aacba3639` and integrates the report and salary slices recorded below. Production promotion requires Leon's staging acceptance.

Context: the operator's `DESKTOP-QA-RESULTS-20261023.md`, `operator-scenarios.json` and saved artifacts under `/Users/leonshimizu/Desktop/ShimizuTechnology/local-qa/chels-staging-v2-20261018`; the Brain Dump's `work/shimizu-tech/Cornerstone/payroll-aire-qa-findings-2026-10-14.md`; and the repository's `ops/staging-v2/README.md`. Original fixture databases, saved PDFs and the unrelated dirty root checkout are preserved.

## Acceptance and implemented behavior

- Saved gross, deductions, net and DRT totals lead the processing page. A concrete next step follows the payroll status. Notes, audit history, connection details and finalized source timecards remain available through expandable sections. Held time, mapping issues and payment-pending status remain visible.
- Employee result review opens in a keyboard-accessible dialog. Closing it retains the current route, filters, scroll position and keyboard focus. The full canonical record remains available.
- An adjustment displays selected-employee guidance and exact reconciliation without the whole regular-period time-tracking readiness dashboard.
- Published regular calendars refresh automatically without resetting unsaved worksheet inputs, locking time, importing, calculating, approving or recording payment. Hidden work tabs pause polling; late responses from another route/client/source are discarded; failures show retry guidance.
- Initial regular calculation consumes the shared server default roster, including eligible salary/contractors after hourly imports. Explicit selections, exclusions, disabled base salary, corrections and previously calculated rosters remain authoritative. See `salary-defaults-2026-10-23.md`.
- The Checks tab includes non-employee checks, FIT generation and saved Form 500 controls with existing capability guards.
- FIT previews, default notes and covers include additional withholding. Omitted export options reuse saved cover choices; intentionally empty notes remain empty. The full package lists and includes its actual five reports, including a valid empty loan report. Its editor keeps that inventory fixed and blocks generation if saved preview data cannot load.
- Register, summary and history reports expose readable labels, units and totals. CSV/XLSX retain full values; XLSX uses company and pay-period headings with headers on row four. New non-employee Created dates use Guam, while sealed historical PDF compatibility is retained.
- DOMPurify, Vite and Vitest receive compatible security patches after the dependency audit identified affected locked versions.

## Local verification

Agent executed on macOS, pinned Ruby 3.3.7 / AIRE 3.3.4, Node 22.22.3, Chromium. Synthetic actors and isolated test databases only; no production writes or real payments.

Passed before final review:

- Full API: 4,881 examples, zero failures. Four original fixed-date calendar failures were reproduced on the original controller; test clocks now precede their fixed cutoff. No calendar policy was relaxed.
- API RuboCop, Brakeman and dependency audit passed. Web lint, typecheck, unit suite and production build passed before the final dependency patch; final repeat recorded below.
- Release browser lanes: 45 payroll release, 10 refresh/correction and 24 pay-item scenarios passed against fresh isolated Rails databases.
- Live retained-fixture browser: Pacific run 2 saved totals stayed $3,996.67 gross / $3,483.83 net / $207.09 DRT; Ben's review showed $950 gross and $849.40 net. Escape closed the dialog, restored the row button and retained the route. Checks exposed the FIT check and Form 500 controls. The package editor restored the saved preparer/date/FIT note and displayed the fixed report inventory.
- Real HTTP certification passed versioned calendar publication, approval replay/stale rejection, cutoff finalization, verified import, calculation, commitment, prepared-versus-issued status, exact acknowledgements and held-hour carry-forward. Its browser selector was updated to open the collapsed audit section; the complete repeat remains a release gate.
- Pinned Impeccable advisory scan returned no findings.

## Remaining gates and limits

Final patched-dependency web gate, full public browser repeat, connected manual browser, independent review, PR review and exact-pair staging certification/deployment must pass before this release is called ready. Record final SHAs and results here after they complete. Leon's final staging walkthrough remains pending. Operator narrow-screen testing was deferred; automated responsive scenarios still ran.

Fixed physical check stubs retain their existing bounded label ellipsis to avoid printing over adjacent check fields. Full saved labels are available in the detail dialog and revised reports. Physical printer alignment remains an operator hardware check; no paper was issued by this implementation.

Root lifecycle session: `01a146c0-aff7-78d2-af07-431b9d7a27e8`. Runtime cleanup and any intentional staging handoff are recorded in the final release evidence.

## Combined release review update

Code head `b951804c230bcce1670d3e1e3eb5d3095f0058fa`, PR [#372](https://github.com/Shimizu-Technology/cornerstone-payroll/pull/372), targets staging-v2. Two independent static reviews found four P2 issues: hidden historical warnings, hidden source failures, a lazy detail-load failure escaping to the route boundary, and an omitted cleared check-number override. All were fixed in `7a0836ce`; the second review verified the fixes with no material findings. The final `b951804c` change completes a test fixture timestamp.

Final local results: 115 frontend test files / 1,087 tests; lint, typecheck and production build passed. Public browser 131 scenarios passed; payroll release/refresh/pay-item browser lanes passed 45/10/24. Dependency audit reports zero vulnerabilities. API integrity and RuboCop passed; full API remains 4,881 passing examples. Staging gate tests: 59 passed; shell syntax passed.

The canonical real HTTP certification and assigned-accountant browser journey passed. A second isolated run replaced only the operator lock command with `Payroll::ScheduledCutoffFinalizer.call_due`: the worker automatically finalized exactly one due period; the remaining import, commit, exact issuance, carry-forward, cancellation and connected browser assertions all passed. This variant used the canonical synthetic future cutoff and clock guards, not historical data repair.

An additional unchanged AIRE policy-spec run at `6fa4b7c2` produced 40 passes and five fixed-October-18 scheduled-cutoff fixture failures: newly recorded database revision history correctly refuses reconstruction before its capture date. These are recorded as a pre-existing test-fixture limitation, not a passing AIRE full suite. The separate future-cutoff real HTTP run verifies automatic behavior without relaxing ledger coverage. The late-approval/finalized-batch and concurrency examples passed. No AIRE source was edited.

Live browser also opened the empty installment-loan PDF successfully, preserving its company/as-of headings and empty-state message. Eli's retained adjustment stayed $100 gross / $92.35 net with exact source 17 linked and payment evidence pending; whole-period AIRE readiness was absent. The saved full-package editor restored its preparer/date, combined $207.09 FIT note and five fixed reports. Physical printer alignment and Leon's staging walkthrough remain operator acceptance.

Staging service gate bootstrap: clean service checkout moved from `ad535d3b` to previously reviewed `50f9a2af`; verifier, shared evidence reader, common/poller/deploy file hashes match the reviewed source. The trigger was not loaded and remains paused until a certified deployment is verified. No volumes or existing fixture data were replaced.
