# Year-end wage basis, milestone 1A

Implementation base: `origin/main` at `54c33409`, November 19, 2026. Cornerstone's payroll operators prepare Guam employers' annual W-2GU and contractor 1099-NEC exports. This change covers the wage/payment amounts and Box 2 label. Reconciliation, readiness gates, official copies, filing files and payroll calculation changes belong to separate work.

## Wage sources

- Live payroll uses financially reportable, reportable items from reportable committed periods, selected by payment date and saved item employment type. Contractor items never enter W-2GU, even if the worker's current employment type changes.
- Live `gross_pay` already excludes reimbursements: hourly/salary gross contains taxable earnings; `PayrollCalculator#calculate_net_pay` adds `non_taxable_additions_total` separately. Subtracting `non_taxable_pay` from live gross would exclude it twice.
- Historical imports use only the latest applied bridge of locked imports, validated by `HistoricalPayrollFilingSource`. Inclusive QuickBooks gross differs from live gross. The bridge's stored FIT, Social Security wage/tip and Medicare wage fields already exclude non-taxable earnings and the appropriate pre-tax deductions. Raw historical paychecks are not added again.
- For live Box 1, use stored FIT wages when they agree to the saved gross minus employee traditional 401(k) and other pre-tax benefits. Null or inconsistent FIT wages fall back to those saved components. No current employee rate or configuration is used. Inconsistent non-null FIT bases produce a report warning.
- Deduction components use the existing report mirror resolution so flexible fields and generated itemized mirrors count once. Traditional 401(k) reduces Box 1 only; Roth and employer contributions reduce none of Boxes 1/3/5. Supported non-retirement pre-tax deductions are treated as FICA-exempt benefits (including Section 125 health).
- The payroll calculation currently sends unreduced gross to FICA (`PayrollCalculator#calculate_taxes`, `EmployeeYearFicaContext#increment`). Therefore stored FICA bases can overstate wages where Section 125 benefits exist. For an employee with any such live benefits, rebuild all live SS wage/tip allocations from saved gross, cash tips and benefits before applying the annual cap. Rebuilding the entire employee year prevents an old capped later paycheck from losing room restored by a benefit exclusion. Otherwise retain stored SS allocations and fall back to gross minus tips / tips when null. Medicare uses stored wages when they agree to gross minus FICA-exempt benefits, and that saved-component basis otherwise. Historical FICA bases remain authoritative.
- Box 3 receives wage-base room first; Box 7 receives the remainder. Tips stay in Boxes 1 and 5 and are excluded from Box 3. Signed correction components remain signed.

This changes annual preparation totals only. It does not fix the upstream FICA calculation, rewrite paid checks, or change quarterly/non-year-end reports. The separate reconciliation worker must account for resulting differences before release.

Rules: [IRS 2026 W-2/W-3 instructions](https://www.irs.gov/instructions/iw2w3), particularly Boxes 1, 3, 5 and 7 and elective deferrals; [Publication 15-B](https://www.irs.gov/publications/p15b), cafeteria plans and accident/health benefits. Existing SS wage-base configuration remains in force.

## AIRE gap

The lead's November 19 read-only follow-up establishes that the aggregate gap comes entirely from contractor payroll: 62 contractor items have $27,945.51 gross and zero FIT/SS wages; all 220 hourly items ($78,999.73) and 11 salary items ($6,750) have FIT equal to gross. Retirement and Roth payments are zero. No payroll-calculation bug is indicated by these results.

Code evidence: `ContractorPayrollCalculator#calculate` stores zero taxable wage bases; `HourlyPayrollCalculator#calculate` and `SalaryPayrollCalculator#calculate` pass gross less pre-tax deductions as `withholding_gross`; `GuamTaxCalculatorV2#calculate` returns that input as FIT wages before its separate W-4 withholding adjustment. `W2GuAggregator#live_items` excludes contractor-type items; `Form1099NecAggregator#aggregated_items` includes them. The synthetic mixed-worker regression recreates a 75% aggregate FIT/gross ratio and verifies that the W-2 employee still reports 100% of gross.

## One-off contractor checks

1099-NEC totals include active contractor-type checks, including standalone checks, by `effective_payment_date` (explicit payment date, linked payroll pay date, then existing creation-date fallback). The check's tax-period year is not its payment year. Voided and explicitly superseded checks are excluded, preventing the same physical payroll payment from counting twice.

The schema has no employee/TIN association on a one-off check. Exact payee names are grouped within that source, with check IDs and a stable payee key retained. These rows carry missing identity/address/W-9 and cross-source identity reconciliation warnings. They are not automatically merged with employee contractors by name. Totals include both sources; the existing tax-year threshold applies to each identified payroll contractor or unresolved payee group. Operators must resolve a payee paid through both sources before filing, particularly when combined compensation crosses the threshold. This PR does not invent an identity link or change the one-off check schema/UI.

## Read-only impact command

The lead can run this after checking out this branch, using their established production access:

```sh
cd api
RAILS_ENV=production bundle exec rake year_end:wage_impact YEAR=2026
# Optional single company:
RAILS_ENV=production bundle exec rake year_end:wage_impact YEAR=2026 COMPANY_ID=6
```

The task performs no writes and enforces PostgreSQL `SET TRANSACTION READ ONLY`. Output is CSV with company ID/year and old/new/delta for Boxes 1, 3 and 5. The old basis reproduces the pre-change rules, including prior-provider verified FIT handling, original null FICA fallbacks and per-employee SS caps. The new basis runs the real aggregator against the same eligible sources. Historical source validation fails rather than silently omitting a missing/stale bridge. No employee names, IDs, SSNs or EINs are printed. Run through Rails so component mirror resolution and historical bridge selection match the report; a standalone SQL approximation would miss these rules.

No production access was performed by the implementation worker. All worker verification uses synthetic data.

## Acceptance and verification ledger

Agent-executed affected-flow QA on this isolated branch, using synthetic data only:

| Acceptance | Coverage |
|---|---|
| A | Synthetic Section 125 health, traditional 401(k), Roth, live reimbursements, tips, null taxable bases, historical/live combined totals, employee SS cap, flexible field mirror resolution, and signed correction specs. |
| B | Mixed contractor/W-2 fixture reproduces aggregate FIT/gross gap; contractors appear only in the 1099 report. Lead's production findings are documented above. |
| C | One-off contractor checks, repeated payees, year-specific thresholds, linked-pay-date fallback, company isolation, voids and verified payroll supersession. Cross-source payee identity remains an operator reconciliation requirement. |
| D | CSV/PDF label specs and real XLSX request inspection; Chromium/WebKit at 375px and 1440px verify the visible Guam label and no horizontal page overflow. |
| E | `year_end:wage_impact` executed under database-enforced read-only mode against a synthetic $1,000 gross/$100 health company: old/new/delta = $1,000/$900/−$100 for each of Boxes 1/3/5. |
| F | No payroll calculator, quarterly/non-year-end report, migration, readiness or filing-responsibility code changed. Saved paycheck attribute snapshots remain unchanged in regression specs. |

Browser evidence is local to the retained worktree under `.codex-qa/year-end/{chromium,webkit}-{375,1440}.png`. Browser resizing covers web layout, not physical mobile hardware. No native-device behavior changed. All created browsers/tabs and API/Vite servers were stopped after QA.

Frontend gate: `npm ci` and `DEPLOYMENT_ENV=production VITE_DEPLOYMENT_ENV=production npm run gate` passed (201 files, 2,010 tests, typecheck, lint, production build). Impeccable 4.6.0 advisory scan of `web/src/pages/Reports.tsx` returned `[]`. Full backend suite on ASUS was attempted but SSH to the runner timed out; full-suite execution remains for CI/lead. RuboCop and Brakeman passed with zero security warnings. The exact final affected-spec count is recorded in the PR body and handoff.

## Follow-up: Section 125 and FICA in the paycheck calculation

`PayrollCalculator` feeds unreduced gross into Social Security and Medicare, so a Section 125 benefit would be taxed for FICA on the paycheck even though it is exempt. No live 2026 payroll has a Section 125 deduction (production check, Nov 19: the only live pre-tax deductions are 401(k)), so no paycheck is affected yet. QuickBooks-era opening balances keep their own stored Social Security and Medicare wages, which match what was taxed then.

Until the calculator is fixed, any W-2 for an employee whose paycheck withheld FICA on a Section 125 benefit is flagged (`fica_withheld_on_section_125`, with a compliance issue that tells staff to refund the employee and file a 941-X before filing). Fix the calculator before any client adds a Section 125 deduction.
