# PREVIEW checks and pay stubs before commit

Staff can download a client review PDF directly from a **Calculated** or **Approved** pay run. Production console access is no longer needed.

1. Confirm the run includes every employee and all pay, tips and deductions. Calculate payroll after any changes.
2. Open **Checks**, then **Download preview**. The same action is beside **Approve** or **Commit** in the run header.
3. Choose **Checks and pay stubs**, **Checks only**, or **Pay stubs only**.
4. Open the downloaded PDF before sending it. Check the first and last paper checks, several stubs, and a direct-deposit employee's stub. Every page must say **PREVIEW**. Check numbers are blank, and check-stub YTD includes the current paycheck.
5. Send the PDF to the client's reviewer through your usual approved channel.

The combined PDF contains paper checks first, followed by a pay stub for every employee with earnings-statement activity, including direct deposit and zero-net statements. Checks use the company's selected stock and the staff member's printer settings, at the same size as final printing. Every page has a faint diagonal **PREVIEW** and a small **PREVIEW** banner. Stub footers say **PREVIEW**.

The filename identifies the company, pay date and payroll review revision, for example `Example_Payroll_PREVIEW_2026-11-19_rev3.pdf`. Older calculated runs without a review package use `rev0`; downloading does not create a review revision.

Each download records the staff member, time, pay run, part and review revision in the audit log. It does not assign check numbers, record print events, change payroll data or change the run's status.

## After the client replies

- **Changes needed:** roll back approval if necessary, fix the entries, calculate again, review and approve, then download a fresh preview. If the review revision changed, the card identifies the last downloaded revision and asks for a new one. Also download a new preview after changing an employee's name or address, or the check settings: those change the PDF without creating a new review revision.
- **Client agrees:** follow the normal approval and **Commit** workflow, set check numbers for the physical stock, then prepare the final print package. Preview downloads do not count as client approval or printing.

Draft, committed and voided runs cannot use this preview action. Calculate a draft first. Use the final print workflow for committed payroll.

## Support

The staff endpoint is `GET /api/v1/admin/pay_periods/:id/checks/preview_pdf`; omit `part` for the combined PDF or pass `part=checks` or `part=stubs`. It enforces the same company access as the pay run and audits every successful download.

The former `api/script/ops/preview_checks_and_stubs.rb` stopgap has been removed. The built-in action covers its outputs and records download evidence; there is no longer a separate console path with temporary server copies or in-process generator patches.
