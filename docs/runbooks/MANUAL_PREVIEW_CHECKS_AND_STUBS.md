# Manual PREVIEW checks and pay stubs (before commit)

**Stopgap.** Use this only until the app has a built-in preview download. It lets a client review checks and pay stubs before a pay run is committed.

First used on Nov 16, 2026 for MoSa's Hotbox Nov 2–15 run (#132, pay date Nov 19). That run had 9 paper checks and 51 pay stubs, with $51,584.61 net.

## Why it's needed

- Checks and pay stubs only open after **Commit** (`ChecksController`, `PayStubsController#batch_pdf`).
- The existing VOID check preview (`rehearsal_preview_pdf`) works only for practice and test workspaces.
- Committing and then undoing doesn't work. **Reopen unpaid** refuses any run with a positive direct-deposit paycheck (`PayrollRevisionPaymentPreflight`). MoSa pays about 80% by direct deposit.
- Undoing a commit by hand in the console isn't safe. A commit:
  - updates employee and company YTD totals
  - applies loan payments
  - posts tax liabilities
  - assigns check numbers
  - queues the tax sync

## What the script produces

`api/script/ops/preview_checks_and_stubs.rb` uses the app's own generators, so the layout is exactly what will print after commit:

- **Paper checks:** `CheckGenerator` (or the First Hawaiian 4-up generator) for every paper check with positive net pay. No VOID marks. No check numbers, because none are assigned before commit.
- **Pay stubs:** `PayStubGenerator` for every employee with earnings-statement activity, direct deposit included.
- **Watermark:** every page gets a faint diagonal "PREVIEW" and a small "PREVIEW" banner. On pay stubs, "PREVIEW" also covers the "This is your official earnings statement" footer.
- **Check stub YTD:** check stubs normally show saved YTD, and commit writes that. The script adds the current uncommitted check once, as `PayStubGenerator` already does, so the check stub and the pay stub agree. Without it, the check stub's YTD totals leave out this paycheck while its earnings rows include it.

**It changes nothing.** The script runs inside a `SET TRANSACTION READ ONLY` transaction that is rolled back. Any write would fail. The run's status is printed before and after.

The checks carry no bank routing or account numbers. MoSa's stock (`top_check`) already has them printed.

## Steps

You need production access with the Render CLI (`render ssh`) and a staff user id to resolve check print settings. Leon is user 1.

1. **Confirm the run is ready.** It must be **Calculated** or **Approved**, with every employee on it, including anyone outside the import (for MoSa: Mo, Sarah and Addison). Recalculate and re-approve after any change, then regenerate the preview.
2. **Upload the script** to the web service:
   ```sh
   render ssh srv-d74hd8v5r7bs73ctg8a0 --output text -- -T 'cat > /tmp/preview_checks_and_stubs.rb' < api/script/ops/preview_checks_and_stubs.rb
   ```
   Once this file is deployed, it's already on the server at `script/ops/preview_checks_and_stubs.rb`, and you can skip the upload.
3. **Run it:**
   ```sh
   render ssh srv-d74hd8v5r7bs73ctg8a0 --output text -- -T \
     'cd /opt/render/project/src/api && PAY_PERIOD_ID=132 COMPANY_ID=6 ACTOR_USER_ID=1 bin/rails runner /tmp/preview_checks_and_stubs.rb'
   ```
   Check the printed counts and net totals against the pay run header (net pay and number of employees), and confirm the status is unchanged.
4. **Download the PDFs.** Use base64 so the binary survives the SSH session:
   ```sh
   render ssh srv-d74hd8v5r7bs73ctg8a0 --output text -- -T 'base64 -w0 /tmp/payroll_preview/<file>.pdf' 2>/dev/null \
     | grep -v 'WARNING\|vulnerable\|pq.html\|hostkeys' | base64 -d > ~/Downloads/<file>.pdf
   ```
5. **Remove the server copies.** The PDFs contain payroll data:
   ```sh
   render ssh srv-d74hd8v5r7bs73ctg8a0 --output text -- -T 'rm -rf /tmp/payroll_preview /tmp/preview_checks_and_stubs.rb'
   ```
6. **Look at the PDFs before sending.** Open the first and last check and a few stubs. Confirm there are no VOID marks, the PREVIEW watermark is on every page, and check YTD matches stub YTD.
7. **Send them** to the person who reviews for the client. On Nov 16 they went by email from Leon to Cornerstone, who forwarded them to MoSa.

## After the client replies

- **Changes needed:** **Unapprove**, fix the entries, **Calculate**, review, **Approve**, then run this again for a fresh preview.
- **Approved by the client:** **Commit**, set the check numbers to the physical stock (see the workflow plan), then generate the print package and print.
