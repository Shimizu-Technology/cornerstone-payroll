# Payroll earning-line rounding (A5)

## Monetary policy

New hourly and contractor payroll calculations round each wage component to cents with decimal half-up rounding, then sum those cents into gross. Regular, overtime, holiday and PTO are separate components within every saved rate bucket. Custom taxable earnings use the same line boundary. Bonus, tips, service charges and taxable payroll-field additions remain part of gross. Captured source hours, rates, dimensions and provenance are unchanged, including signed reversals and zero-cent reversal lines.

The calculation context records `earnings_rounding: saved_lines_v1`. The frozen-source guard uses the same rounding function for its expected tuples. At calculation, approval and commit, the guard checks taxable saved earnings against gross and checks gross plus non-taxable saved additions minus total deductions against net. Non-taxable/reimbursement categories are excluded from taxable gross. The shared worksheet estimate now rounds wage components the same way; no pay-run page or layout files changed.

The reproduced two-bucket case changes from gross $0.21 with two $0.11 lines to gross $0.22 with those same two lines. FICA and withholding are calculated from the resulting gross before net is saved.

## Historical replay and deploy impact

There is no migration, backfill or committed-payroll rewrite. Existing committed scalars and earning rows read back unchanged, including an old mismatch. A historical correction whose original context lacks the policy marker uses the old aggregate rounding for its absolute target. New-policy originals replay the captured line rule. #381's supplemental component ledger continues to subtract original plus active saved supplementals from the target.

For old-rule history, the component ledger verifies the saved rounding gap against unrounded captured wage tuples. It accounts for that gap in memory and saves only the change in the gap as an explicit signed **Historical earnings rounding** earning on the new supplemental. It does not allocate the gap into any frozen earning, hour or rate. Repeated and negative supplementals reconcile to the saved scalar deltas; missing or inconsistent wage evidence remains held. This exception is required to conserve historical saved values while retaining their original monetary policy.

Calculated-but-uncommitted payroll can be recalculated with the new rule. The #376/#381 pre-deploy tracking gate already requires older calculated payroll to recalculate; this change does not repair it with SQL. The regression suite also replaces an uncommitted old rounding snapshot and proves recalculation saves the new policy and $0.22 gross. Deploy API and web together so the worksheet estimate agrees with calculation. No change to historical amounts, historical tax filings or tax rules is performed. Once new-policy payroll is committed, a rollback must retain policy-aware correction replay; the old calculator would ignore this policy marker. Existing #381 holds on ambiguous or multiple original rate rows remain in place; the corrective tests exercise its supported captured-row replay with separate REG/OT amounts.

## Gross and tax effects

The effect depends on the number of independently rounded wage lines, not just employees or rate IDs. No customer payroll distribution was sampled. Representative ordinary structures have these conservative per-paycheck limits relative to old aggregate rounding:

| Wage structure | Independently rounded wage lines | Maximum gross change |
| --- | ---: | ---: |
| One rate, regular pay only | 1 | 0 cents |
| One rate, regular plus overtime | 2 | 1 cent |
| Two source buckets, each regular plus overtime | 4 | 2 cents |
| Five buckets, each regular plus overtime | 10 | 5 cents |
| Ten buckets, each regular plus overtime | 20 | 10 cents |
| Large split with 200 wage lines | 200 | 100 cents ($1) |

Each line contributes at most half a cent of rounding error, and the old aggregate boundary contributes at most another half cent; the saved difference is a whole number of cents. The change may increase or decrease gross. For example, 100 employees with four wage lines each have a conservative company gross-change bound of $2, not a promise of an actual $2 change. The executed 101 × (0.01h × $10.50) example changes gross from $10.61 to $11.11, an increase of 50 cents.

Employee/employer FICA, income-tax withholding, percentage deductions and percentage additions use the resulting gross and can also change. For the exact two-bucket regression, employee Social Security remains $0.01, Medicare/FIT remain $0.00, and net rises from $0.20 to $0.21. Historical committed tax and net amounts are not recalculated during reads.

## Acceptance evidence

Scope: affected-flow QA, agent executed, synthetic local databases, Ruby 3.3.7 / Node 22.22.3. Initial production code was verified at `34393dd5`. The branch was then rebased onto `d3b150b8`, which includes merged #381 and #384; the rebased implementation/test head is `4ec2a73f`. The API subtree stayed byte-identical (`323056794f8c821d3dcc0967beffb3c796157c90`), so the final full backend gate remains valid across that rebase. Frontend gates and real-UI acceptance passed again against the combined UI.

Required case R1: open the seeded split-bucket run, calculate/recalculate through Process payroll, open saved detail, close it, reload, reopen it, and compare with the saved API response. **Passed, 1/1 cases accepted**: desktop 1280×800 and phone 390×844 both show Current $0.11 + Carryover $0.11 = gross $0.22, deductions $0.01, net $0.21. Both retained 0.01h and $10.50 per bucket. This UI fixture uses two manually seeded retained buckets; the real frozen current/carryover/correction allocation path is covered in the backend specs. The dialog closes back to the same run. Headless Chromium touch/viewport emulation was used; physical phone, native keyboard and live AIRE transport were not run.

Evidence is in `output/payroll-aire-review-2026-10-24/impl/payroll-round/`: `ui-result.json`, `ui-check.cjs`, `ui-*-reloaded*.png`, `ui-*-reloaded.txt`, and `ui-*-saved-api.json`. Screenshots were visually inspected. UI servers and the owned headless browser were stopped after this phase.

Automated coverage includes the exact two-bucket case; 101 buckets; signed current/carryover/correction dimensions with frozen allocation tuples; bonus, tips, service charges, taxable and non-taxable additions; single-rate REG/OT/holiday/PTO; hourly contractors; uncommitted recalculation; original and repeated positive/negative legacy/new-policy supplementals; unchanged committed history; gross/net tampering at approval and commit; item detail, register JSON/CSV/PDF, employee summary PDF and paystub totals; and the shared estimate contract.

Final engineering-gate counts and reviewer status are recorded in the PR and the task output's `RESULT.md`. An early full suite loaded the superseded aggregate-rounding fixture and failed that one expectation ($0.05 versus $0.06); the shared fixture was updated to the new line policy before the final full suite. An initial Node 26 frontend run was invalid for the pinned toolchain. A browser run interrupted by dependency reinstallation was discarded and its fixture rebuilt. Those logs are retained separately.

## Original implementation engineering gate

| Check | Result |
| --- | --- |
| API schema load / `db:integrity` | Passed; PostgreSQL guards verified |
| RuboCop | 1,502 files; 0 offenses |
| Full RSpec | 5,275 examples; 0 failures |
| Focused A5/readers/shared estimate contract | 63 examples; 0 failures |
| Brakeman | 0 errors; 0 warnings |
| bundler-audit | 0 vulnerabilities; 1,269 advisories checked |
| `npm ci` / audit | 297 packages audited; 0 vulnerabilities |
| Web gate | 126 files; 1,195 tests passed; typecheck, lint and build passed |
| Public E2E | 131 passed |
| Release E2E | 45 passed |
| Refresh E2E | 10 passed |
| Pay-items E2E | 24 passed |

API gate logs use the `final-` prefix; combined web/public logs use `rebased-`; release/refresh/items logs are the final unprefixed files. `gates.jsonl` retains all attempts. Required acceptance has no remaining local blocker. CodeRabbit/CI status and the final process/database cleanup receipt are reported separately in `RESULT.md`; no merge or deploy was performed by this worker.

## Review follow-up: custom earning input compatibility

The follow-up to CodeRabbit comment `4366994692` starts from reviewed head `aa5456ff`. `PayrollEarningsRounding.line_amount` now retains exact decimal parsing for valid finite amounts and falls back to the legacy `to_f` conversion for other inputs. Blank, nil, non-numeric, `"NaN"` and `"Infinity"` custom amounts therefore calculate as zero; numeric-prefix strings retain their previous numeric value. The original custom earning input is preserved. Captured wage inputs, the rounding policy and historical committed amounts are unchanged.

The caller audit found raw custom JSON in `custom_earnings_total`; wage and saved-line callers supply computed numeric components, and custom saved-line construction already uses `to_f`. The frozen-source guard validates finite hours and rates before multiplication and the rounding call, so this fallback does not weaken source validation.

Twelve new integration regressions cover six input forms for both hourly employees and hourly contractors. Each calculates, saves and reloads the split-bucket item, then checks taxable earnings, gross, additions, deductions/net, saved custom lines and unchanged input. Failing-first evidence: `review-fix-red.log` (8 examples / 8 failures), followed by `review-fix-nonfinite-red.log` (4 examples / 4 failures). The final affected suite passes **153 examples / 0 failures** (`review-fix-focused-final.log`). The first full-suite attempt was deliberately interrupted after 1,391 examples / 0 failures to add the four nonfinite-string cases; it is not counted as a complete gate.

The complete follow-up backend gate passes: schema load and `db:integrity`; RuboCop **1,502 files / 0 offenses**; full RSpec **5,287 examples / 0 failures**; Brakeman **0 errors / 0 warnings**; bundler-audit **0 vulnerabilities / 1,269 advisories checked**. Logs use the `review-fix-final-` prefix; all six command exits are zero in `gates.jsonl`.

This follow-up changes no web files. The desktop/phone saved-outcome evidence and frontend gates above belong to the original implementation and were not rerun for this backend input compatibility fix. CodeRabbit was not requested again; the existing thread receives the fix and verification results after push.
