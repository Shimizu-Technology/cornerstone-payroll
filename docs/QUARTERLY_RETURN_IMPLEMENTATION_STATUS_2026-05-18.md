# Quarterly Return Implementation Status

Date: 2026-05-18

## Current filing model

Cornerstone Payroll separates quarterly payroll compliance into three tracks:

1. **Guam withholding track** — Form 500 deposits and GuamTax W-1 quarterly return.
2. **Guam wage reporting track** — GuamTax SWICA / SW-2 quarterly wage report.
3. **Federal employment tax track** — IRS Form 941 and Schedule B when required.

Quarterly compliance is selected by **pay date/check date**, not pay-period end date.

## Implemented in this slice

- Persistent quarterly compliance packets per company/year/quarter.
- Persistent packet tasks for:
  - Form 500 deposits
  - W-1
  - SWICA / SW-2
  - Federal Form 941
  - Schedule B
- Task status/confirmation/proof/notes fields exposed through the Reports UI.
- Form 500 payment tracking fields added to saved Form 500 filings.
- Quarterly packet now reconciles confirmed Form 500 payments against W-1 withholding.
- SWICA upload readiness validation for employee SSN/address requirements and duplicate SSNs.
- SWICA fixed-width wage-record ASCII export for GuamTax review/upload preparation.
- Review checks now flag unreconciled Form 500 payments and SWICA upload blockers.

## Important caveat

The SWICA export follows the wage-record field layout from the SWICA booklet for employee wage detail. Before relying on it as the sole production upload artifact for every GuamTax account, validate it with GuamTax using a known client file, especially for payroll processor accounts, multiple locations, and any transmitter/header/trailer requirements applied by the current GuamTax upload screen.

## Still needed for full production-grade filing

- Attach actual proof documents directly to packet tasks.
- Capture federal EFTPS deposits and reconcile Form 941 line 13/14.
- Add legal deposit due-date calculation for Form 500 and federal deposits, including weekend/holiday roll-forward.
- Add explicit company/org taxability matrix for every pay component.
- Add correction/amendment workflows for W-1, SWICA, and 941-X.
- Validate SWICA upload format end-to-end with GuamTax and add any required transmitter/location records.
