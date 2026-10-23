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
