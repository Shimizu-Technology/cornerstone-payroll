# Report Viewing, Exports, and Compliance Packets

## Why this work exists

Cornerstone operators and clients need to review a report before deciding whether
to keep a file. A workbook-only workflow is especially difficult on phones and on
devices without Excel. It also makes it too easy to download the wrong period or
discover a problem only after leaving the application.

Cornerstone therefore follows a **view first, export when needed** reporting
policy:

1. Build the report from one server-owned, tenant-scoped data snapshot.
2. Show a readable in-application preview.
3. Offer only the file formats that match the report's purpose.
4. Keep the preview and every export reconciled to the same normalized rows.

This change is reporting-only. It does not recalculate payroll, change committed
payroll rows, alter tax rules, or mutate check state.

## Format policy

| Report | In app | PDF | Excel | CSV | Filing output |
| --- | --- | --- | --- | --- | --- |
| Quarterly Compliance Packet | Yes | Combined packet | Workbook | — | Official forms and SWICA wage file |
| Payroll Register | Yes | Yes | Yes | Yes | — |
| Payroll Summary by Period | Yes | Yes | Yes | Yes | — |
| Employee Pay History | Yes | Yes | Yes | Yes | — |
| Tax Withholding Summary | Yes | Yes | Yes | Yes | — |
| W-2GU Preparation | Yes | Yes | Yes | Yes | Official filing workflow remains separate |
| Federal Form 941 | Yes | Official PDF | Yes | — | Official PDF |
| 1099-NEC Preparation | Yes | Yes | Yes | Yes | — |
| Checks & Payments Register | Yes | — | — | Yes | — |
| Employer Tax Liability | Yes | Yes | Yes | Yes | — |

The pay-period page keeps its focused previews and downloads. Client-portal users
can view their payroll register and payroll summary in the application and export
those reports as PDF, Excel, or CSV.

## What each format means

- **In-app preview** is the default review and reconciliation surface.
- **PDF** is the readable, printable, shareable copy.
- **Excel** is the multi-sheet analytical workbook used for deeper reconciliation.
- **CSV** is a portable flat data extract for the report's primary grain.
- **Official filing output** is a government form or prescribed wage file. It is
  not interchangeable with a review PDF.

## Quarterly Compliance Packet

The combined PDF contains:

1. A Cornerstone cover page with the reporting period, due dates, core totals,
   and reconciliation checks.
2. Federal Form 941.
3. Schedule B when the report determines it is required.
4. Guam W-1.
5. Guam SW-2/SWICA.

The packet is generated from the same quarterly report snapshot as the on-screen
packet and Excel workbook. The individual official-form downloads remain
available when an accountant needs to file or review one form separately.

## Data consistency and historical accuracy

- Existing report builders remain the source of payroll and compliance values.
- PDF, Excel, and CSV adapters consume the same normalized sheet rows where the
  formats represent the same report.
- Payroll-field disclosures continue to read snapshotted payroll-item field
  entries, so renamed or retired fields do not rewrite historical reports.
- Custom periods remain pay-date based and include committed payroll only.
- Admin and client endpoints keep their existing tenant and committed-period
  authorization boundaries.

## Manual verification checklist

Use a company with committed payroll and payroll-field entries.

1. Open **Reports** and confirm every report card has a working **View** action.
2. Open Payroll Summary, Tax Summary, Employee Pay History, W-2GU, 941, and
   1099-NEC previews without downloading a file.
3. Open each **Export** menu and confirm its options match the format matrix.
4. Compare the same employee and total in the preview, PDF, Excel, and CSV.
5. Open the Quarterly Compliance Packet, then download the combined PDF and
   confirm the cover, 941, conditional Schedule B, W-1, and SW-2 pages.
6. Verify an invalid or incomplete custom period returns a user-facing error.
7. Sign in as a client-portal user and repeat Payroll Register and Payroll
   Summary preview/export checks.
8. On a phone-sized viewport, confirm previews are readable without requiring
   Excel and export menus remain usable.

## Deferred work

This phase intentionally does not add e-filing, scheduled reports, email
delivery, saved report templates, or Phase 1B liability-settlement behavior.
Those should build on this consistent preview/export foundation in later work.
