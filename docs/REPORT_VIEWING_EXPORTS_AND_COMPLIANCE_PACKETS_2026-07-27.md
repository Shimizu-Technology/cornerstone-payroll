# Report Viewing, Exports, and Compliance Packets

## Why this work exists

Cornerstone operators and clients need to review a report before deciding whether
to keep a file. A workbook-only workflow is especially difficult on phones and on
devices without Excel. It also makes it too easy to download the wrong period or
discover a problem only after leaving the application.

Cornerstone therefore follows a **view first, export when needed** reporting
policy:

1. Build the report from server-owned, tenant-scoped normalized report builders
   over committed payroll data.
2. Show a readable in-application preview.
3. Offer only the file formats that match the report's purpose.
4. Keep the preview and every export reconciled to the same normalized rows.

This change is reporting-only. It does not recalculate payroll, change committed
payroll rows, alter tax rules, or mutate check state.

## Format policy

| Report | In app | PDF | Excel | CSV | Filing output |
| --- | --- | --- | --- | --- | --- |
| Quarterly Compliance Packet | Yes | Draft review packet | Workbook | — | Draft government forms; SWICA Code W review file |
| Payroll Register | Yes | Yes | Yes | Yes | — |
| Payroll Summary by Period | Yes | Yes | Yes | Yes | — |
| Employee Pay History | Yes | Yes | Yes | Yes | — |
| Tax Withholding Summary | Yes | Yes | Yes | Yes | — |
| W-2GU Preparation | Yes | Yes | Yes | Yes | Official filing workflow remains separate |
| Federal Form 941 | Yes | Draft government form | Yes | — | Filing remains outside Cornerstone |
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
- **Draft government forms** are preparation copies placed on agency templates.
  They are not proof of filing, payment, or acceptance.

## Quarterly Compliance Packet

The combined review PDF contains:

1. A Cornerstone cover page with the reporting period, due dates, core totals,
   and reconciliation checks.
2. A draft Federal Form 941.
3. A draft Schedule B when the report determines it is required.
4. A draft Guam W-1.
5. A draft Guam SW-2/SWICA.

Every page is visibly marked **Draft — Not Filed**. The packet and workbook use
the same quarterly report builder as the on-screen packet. Individual draft-form
downloads remain available for accountant review.

Cornerstone's current SWICA text export contains only the 275-character Code W
employee wage-detail records. The Guam DRT specification also requires Code A,
B, T, and F records for a complete upload, so Cornerstone labels this output as
a review draft and does not represent it as a GuamTax filing upload.

Form 941 remains a preparation copy because adjustments, credits, federal
deposits, balance due or overpayment, and signer/preparer fields require records
or decisions that Cornerstone does not currently store.

## Read-only reporting and workflow state

Viewing or exporting a quarterly packet does not create compliance workflow
records or tasks. An operator must choose **Start Filing Workflow** before
Cornerstone creates the quarter's persistent filing/payment tracker. This keeps
GET previews and downloads read-only while preserving explicit workflow tools.

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
   confirm the draft/not-filed banner on the cover and generated forms.
6. Confirm viewing and exporting do not create a compliance workflow, then use
   **Start Filing Workflow** and confirm its tasks appear.
7. Confirm the SWICA text action says Code W wage records and never describes
   the file as a filing upload.
8. Verify an invalid or incomplete custom period returns a user-facing error.
9. Sign in as a client-portal user and repeat Payroll Register and Payroll
   Summary preview/export checks.
10. On a phone-sized viewport, confirm previews are readable without requiring
   Excel and export menus remain usable.

## Deferred work

This phase intentionally does not add e-filing, scheduled reports, email
delivery, saved report templates, or Phase 1B liability-settlement behavior.
Those should build on this consistent preview/export foundation in later work.
