# Payroll intake compatibility

Track C starts with the [`mosa_revel` layout descriptor](../api/config/payroll_intake/mosa_revel.yml) and [golden request specs](../api/spec/requests/api/v1/admin/payroll_intake_golden_spec.rb). The descriptor records the layout and rules used today. The descriptor spec checks the workbook headers and merged cells against the current template generator and the frozen v2 fixture. It also checks the adapter and parser constants. The request specs upload files through staff preview and exercise the portal revision bridge and staff apply. They compare payroll inputs, totals, source completeness, warnings, and errors to checked-in JSON. The legacy warning snapshot takes its existing display label from the adapter so the fixture uses only the code name.

## Synthetic inputs

The [fixture directory](../api/spec/fixtures/files/payroll_intake_golden) contains workbooks built from literal synthetic data and the public template layout. The request spec builds synthetic Revel PDFs with the matching layout. It also pastes a synthetic email through the `spike_email` adapter. The workbooks can be rebuilt from `api` with:

```sh
bundle exec ruby spec/fixtures/files/payroll_intake_golden/build_workbooks.rb
```

| Workbook | Behavior captured in JSON |
| --- | --- |
| `normal.xlsx` | v2 regular and overtime hours, both tip pools, tips already paid, and a typed reimbursement. Also used for workbook-only review and a corrected portal revision. |
| `overtime_heavy.xlsx` | Source-reported overtime with inconsistent Revel totals. Also used for double-time characterization and re-import after a worksheet edit. |
| `new_hire.xlsx` | A mid-period hire matches by name in Revel and by ID in the workbook. |
| `terminated.xlsx` | Both sources flag the terminated worker for review and leave the rows unmatched for pay. |
| `legacy.xlsx` | Row-4 legacy headers, both tip pools, direct loan deduction, explicit zero bonus, totals and summary rows, and an off-by-one workbook date and workweek offset. |
| `owner_period_pay.xlsx` | Variable salary amount for a single employee and the required attestation for that pay date. |
| `missing_id_column.xlsx` | A changed row without its Employee ID is rejected. |
| `extra_hour_corrections_sheet.xlsx` | A populated `HOUR CORRECTIONS` sheet is rejected. |
| `loan_totals_mismatch.xlsx` | A loan ending balance that fails reconciliation is rejected. |

A Revel totals line ends the table and its declared totals are skipped. The PDF parser reads double-time hours, but `ImportService` drops them before the adapter's review check. The golden tests capture both current results.

## Blockers for the next steps

- **Adapter selection.** The staff Revel preview and template controller, portal revision creation and import bridge, portal serializer, and client and staff UI use explicit `mosa_revel` gates or source selection. The generic preview service has a static map, and the company and session models allow only the two known keys. The pending request spec describes discovering a client's enabled adapters through the intake profile endpoint.
- **Pay-period length.** `PayrollIntake::WorkweekEvidence` requires 14 inclusive days even when the source supplies overtime. The three pending examples cover accepting a complete weekly workweek and accepting semimonthly and monthly periods with source-reported overtime. Payroll-calculated overtime should use complete seven-day legal workweeks.

B2 adds registry-backed descriptors and the read-only profile. B3 records import origin. B4–B6 move the staff and portal gates, form fields, and roles to descriptors. B7 adds tip and overtime settings, and B8–B9 add the default workbook and CSV and converge the apply paths. The `mosa_revel` move to descriptor-driven intake follows a side-by-side staging comparison.
