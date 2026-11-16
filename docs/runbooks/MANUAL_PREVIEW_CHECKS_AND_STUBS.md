# PREVIEW checks and pay stubs before commit

> **Superseded (November 16, 2026, PR #470).** Use **Download preview** on a calculated or approved pay run. The steps in [MoSa biweekly payroll cycle](MOSA_PAYROLL_CYCLE.md#5-download-preview-for-the-client) are the normal procedure. The manual console method at the end of this page is an emergency fallback only.

## Normal procedure: Download preview

Staff can download a client review PDF directly from a **Calculated** or **Approved** pay run. No production console access is needed.

1. Confirm the run includes every employee and all pay, tips and deductions. Calculate payroll after any changes.
2. Open **Checks & payments**, then **Download preview**. The same action is beside **Approve** or **Commit** in the run header.
3. Choose **Checks and pay stubs**, **Checks only**, or **Pay stubs only**.
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

- Omit `part` for the combined PDF, or pass `part=checks` or `part=stubs`.
- It enforces the same company access as the pay run and is open to every staff role.
- It audits every successful download.
- If the run or its review revision changes while the PDF is being prepared, it returns 409 with *"This payroll changed while the preview was being prepared. Download it again."*
## Emergency fallback: the retired console script

**Use this only if the built-in preview is down, a client needs previews before a fix can be released, and Leon has approved production console access.** Agents never run it.

`api/script/ops/preview_checks_and_stubs.rb` **no longer exists on `main`.** PR #470 removed it in commit `5d4367d0`, because the endpoint covers its output and adds an audit trail.

The last version is in git history at commit `d337d4e7` (merged as PR #466). The runbook steps from that version are kept here for reference only.

How the script worked:

- **Read-only.** It ran as a `rails runner` inside a `SET TRANSACTION READ ONLY` transaction that was rolled back. Nothing was written.
- **Generator patch.** It prepended a patch to `CheckGenerator` for its own process, so check-stub YTD included the uncommitted check.
- **Output.** It stamped every page "PREVIEW" and wrote two PDFs (paper checks and pay stubs) to a fresh folder under `/tmp/payroll_preview` on the server.
- **No audit.** It recorded no audit entry, so the download isn't recorded anywhere in the app.

**It hasn't been run or tested against the code on `main` since its removal.** The check and stub generators have changed since then, so run it against staging or a local copy before trusting its output.

Retired steps:

1. **Confirm the run is ready.**
   - It must be **Calculated** or **Approved**.
   - It must include every employee, including anyone outside the import (for MoSa: Mo, Sarah and Addison).
2. **Get the script** from history: `git show d337d4e7:api/script/ops/preview_checks_and_stubs.rb > preview_checks_and_stubs.rb`.
3. **Upload it** to the Payroll web service's `/tmp` with `render ssh`.
4. **Run it** from the API directory:
   ```sh
   PAY_PERIOD_ID=<run> COMPANY_ID=<company> ACTOR_USER_ID=<staff user> bin/rails runner /tmp/preview_checks_and_stubs.rb
   ```
   `ACTOR_USER_ID` only selects whose printer settings to use.
5. **Compare** the printed counts and net totals with the pay run header, and confirm the status is unchanged.
6. **Download** each PDF over `render ssh` with base64 so the binary survives the session.
7. **Delete the server copies straight away:** `rm -rf /tmp/payroll_preview /tmp/preview_checks_and_stubs.rb`. The PDFs contain payroll data.
8. **Check before sending.** Open the PDFs and confirm there are no VOID marks, PREVIEW is on every page, and check YTD matches stub YTD. Then send them.
9. **Record it.** Note in the pay run's activity, or in the client thread, that a manual preview was sent and for which revision. The script leaves no audit entry.
