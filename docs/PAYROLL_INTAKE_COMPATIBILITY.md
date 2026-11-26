# Payroll intake compatibility

Track C starts with the [`mosa_revel` layout descriptor](../api/config/payroll_intake/mosa_revel.yml) and [golden request specs](../api/spec/requests/api/v1/admin/payroll_intake_golden_spec.rb). The descriptor spec checks the workbook headers and merged cells against the current template generator and the frozen v2 fixture. It also checks the adapter and parser constants. The descriptor lists the existing parser, matching, and reconciliation specs that form part of the compatibility gate. The golden specs compare preview rows, apply gates, and persisted payroll results against checked-in JSON. Regular and overtime hours are numeric. Double-time hours and money use decimal strings. Legacy messages take the existing display label from the adapter at comparison time.

## Synthetic inputs

The [fixture directory](../api/spec/fixtures/files/payroll_intake_golden) contains workbooks built from literal synthetic data and the public template layout. The request spec builds synthetic Revel PDFs with the matching layout. It also pastes a synthetic email through the `spike_email` adapter. The workbooks can be rebuilt from `api` with:

```sh
bundle exec ruby spec/fixtures/files/payroll_intake_golden/build_workbooks.rb
```

| Workbook | Behavior captured in JSON |
| --- | --- |
| `normal.xlsx` | v2 hours, both tip pools, and a first apply with tips paid out and a non-taxable reimbursement. Also used for workbook-only rejection, a wrapped Revel name with conflicting report dates, and an applied portal revision with an audit entry. |
| `overtime_heavy.xlsx` | Source-reported overtime with inconsistent Revel totals. Also used for the double-time apply block and to remove an omitted reimbursement on re-import after a worksheet edit. |
| `new_hire.xlsx` | A mid-period hire matches by name in Revel and by ID in the workbook. |
| `terminated.xlsx` | Both sources flag the terminated worker for review and leave the rows unmatched for pay. |
| `legacy.xlsx` | Row-4 legacy headers and date and workweek warnings. Apply requires saved tip treatment, deducts a direct loan, and clears an imported bonus with explicit zero. |
| `legacy_installment.xlsx` | F2/F3 date fallback and an installment reconciled to its named loan without adding a second direct deduction. |
| `v1.xlsx` | Generated v1 sheet order and separate bonus and one-payroll deduction columns. |
| `one_time_components.xlsx` | First apply persists a taxable bonus and a post-tax deduction with its payee. |
| `owner_period_pay.xlsx` | Apply persists the variable salary override and evidence for one employee and pay date. |
| `blank_employee_id.xlsx` | A changed row with an Employee ID header and a blank ID cell is rejected. |
| `extra_hour_corrections_sheet.xlsx` | A populated `HOUR CORRECTIONS` sheet is rejected. |
| `loan_totals_mismatch.xlsx` | A loan ending balance that fails reconciliation is rejected. |
| `loan_setup_change.xlsx` | A recurring setup change on `DEDUCTIONS & LOANS` is rejected. |

The PDF-only fixture applies after staff records the missing-workbook waiver. The email fixture covers both a total mismatch and a successful apply with weekly overtime and already-paid tips.

A Revel totals line ends the table. The parser skips its declared totals. The preview retains double-time hours as a decimal, and positive double-time hours block apply. Staff can review the hours and enter the double-time pay manually or contact Cornerstone.

## Blockers for the next steps

- **Adapter selection.** The staff Revel preview and template controller, portal revision creation and import bridge, portal serializer, and client and staff UI use explicit `mosa_revel` gates or source selection. The generic preview service has a static map, and the company and session models allow only the two known keys. The pending request spec describes discovering a client's enabled adapters through the intake profile endpoint.
- **Pay-period length.** `PayrollIntake::WorkweekEvidence` requires 14 inclusive days even when the source supplies overtime. The three pending examples cover accepting a complete weekly workweek and accepting semimonthly and monthly periods with source-reported overtime. Payroll-calculated overtime should use complete seven-day legal workweeks.

B2 adds registry-backed descriptors and the read-only profile. B3 records import origin. B4–B6 move the staff and portal gates, form fields, and roles to descriptors. B7 adds tip and overtime settings, and B8–B9 add the default workbook and CSV and converge the apply paths. The `mosa_revel` move to descriptor-driven intake follows a side-by-side staging comparison.
