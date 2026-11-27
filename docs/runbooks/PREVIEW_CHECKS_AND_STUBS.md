# PREVIEW checks and pay stubs before commit

## Normal procedure: Download preview

Staff can download a client review PDF directly from a **Calculated** or **Approved** pay run. No production console access is needed.

1. Confirm the run includes every employee and all pay, tips and deductions. Calculate payroll after any changes.
2. Open **Checks & payments**, then **Download preview**. The same action is beside **Approve** or **Commit** in the run header.
3. Choose **Checks and pay stubs**, **Checks only**, **Pay stubs only**, or **All pay stubs (including paper-check employees)**.
4. Open the downloaded PDF before sending it.
   - Check the first and last paper checks, several stubs, and a direct-deposit employee's stub.
   - Every page must say **PREVIEW**.
   - Check numbers are blank.
   - Check-stub YTD includes the current paycheck.
5. Send the PDF to the client's reviewer through your usual approved channel.

**What's in the PDF:**

- The combined PDF puts paper checks first, followed by a pay stub for every employee with earnings-statement activity, including direct deposit and $0 net statements.
- Checks use the company's selected stock and the staff member's printer settings, at the same size as final printing.
- Every page has a faint diagonal **PREVIEW** and a small **PREVIEW** banner. Stub footers say **PREVIEW**.

**File name.** It identifies the company, pay date and payroll review revision, for example `Example_Payroll_PREVIEW_2026-11-19_rev3.pdf`. Older calculated runs without a review package use `rev0`. Downloading doesn't create a review revision.

**What a download records.** Each download records the staff member, time, pay run, part and review revision in the audit log. It doesn't assign check numbers, record print events, change payroll data or change the run's status.

## After the client replies

- **Changes needed:**
  1. Roll back approval if needed, fix the entries and calculate again.
  2. Review and approve, then download a fresh preview.
  3. If the review revision changed, the card names the last downloaded revision and asks for a new one.
  4. Also download a new preview after changing an employee's name or address, or the check settings. Those change the PDF without creating a new review revision.
- **Client agrees:** follow the normal approval and **Commit** workflow, set check numbers for the physical stock, then prepare the final print package. Preview downloads don't count as client approval or printing.

Draft, committed and voided runs can't use this preview action. Calculate a draft first. Use the final print workflow for committed payroll.

## Support

The staff endpoint is `GET /api/v1/admin/pay_periods/:id/checks/preview_pdf`.

- Omit `part` for the combined PDF, or pass `part=checks`, `part=stubs`, or `part=all_stubs`.
- It enforces the same company access as the pay run and is open to every staff role.
- It audits every successful download.
- If the run or its review revision changes while the PDF is being prepared, it returns 409 with *"This payroll changed while the preview was being prepared. Download it again."*
