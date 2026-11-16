# MoSa biweekly payroll cycle

**For:** Cornerstone staff running MoSa's payroll in Cornerstone Payroll (Dafne, Mark).
**Matches:** `main` after PRs #465–#475 (November 17, 2026).

This guide covers one biweekly MoSa run, from the client's email to printed checks. Button and label names are in **bold** exactly as they appear in the app. Who can do each step is in the [role matrix](../ROLE_PERMISSION_MATRIX_2026-05-14.md#mosa-payroll-workflow-permissions-november-17-2026).

Use your own login. Every import, entry, approval, preview download and commit is recorded under the person who did it.

## MoSa's settings (November 17, 2026)

- **Pay schedule:** biweekly, Monday to Sunday, paid Thursday (4 days after the period ends), starting with the period that begins November 16, 2026. New pay runs suggest these dates.
- **Overtime workweek:** Monday 12:00 AM, matching the pay periods.
- **Next check number:** 22026, after run #117 printed through 22025.
- **Expected entries** (Standing Changes): Owner A's pay, Owner B's pay and Jordan Parker's maintenance hours. Each is required, with **None this period** allowed.
- **Require client approval before payroll commit:** off.

## Before you start

- Select MoSa in the company picker and open the pay run for the period's dates. Check the work dates and pay date before entering anything.
- Set up any **installment loan** in **Employee Loans** before importing. The import won't create one (see [Loans](#loans-one-time-vs-installment)).
- Check that the client's mapped employees for expected entries are still active. Open **Standing Changes** in the client settings menu. A row that needs fixing says **Needs attention in Settings: …**.
- Check the next check number against the real check stock before the first commit of the cycle. It's in **My Printer & Checks** (**Next Check Number**).

## 1. Import the client's files

MoSa emails two files each period:

- **Revel hours PDF**: regular and overtime hours. Revel pay rates and pay amounts are ignored.
- **Tips & loans workbook**: tips, loans, owner pay and one-time items.

Open the pay run, choose **More payroll actions** (the **⋯** button), then **Import (MoSa)**. The **Import Payroll Data** window opens.

**Upload in either order.** Under **Files for this payroll**, add either file now and the other later. When one is missing, its row says **Not added yet**. **Preview Import** reads what you've added so far. Reopen **Import (MoSa)** later and add the second file. The button then reads **Add to import version N**. Adding a missing file doesn't need a reason, and outcomes you already chose are kept.

**No tips or loans this period.** If MoSa says there's no workbook this time, tick **No tips or loans this period** in the file checklist. Apply stays off until the workbook is added or this box is ticked. If the client already made that choice in the portal, the checklist says **The client chose: No tips or loans this period.**

**Replacing a file.** Upload a corrected file only when MoSa sends a correction. A file whose contents differ from the one already received counts as a replacement, and you'll be asked why. The other file is kept. Adding a file to an import that was already applied also needs a reason.

**Removing a file.** If a wrong file was added (for example, last period's workbook), choose **Remove** next to it, fill in **Why remove it?**, then **Remove Tips & loans workbook** (or **Remove Revel hours PDF**). Choose **Keep it** to cancel. The other file is matched again as a new import version. You can only remove a file while the import is still in review. You can't remove the only file, or files that came from a client revision.

## 2. Review the import

The review groups everything into two boxes:

- **Needs your action (n)**: what keeps **Apply Import** off. Each item has a button that jumps to the row.
- **For your information (n)**: notices that don't block, such as period-end mismatches, workweek notes, $0 tips and client choices. Open a line to see its details.

The text above the footer says why Apply is off, for example **Apply is off: …**.

### Matching

- **Suggested name matches.** Check each suggested match against the actual person, then tick **I reviewed these suggestions and they point to the correct employees.**
- **Every source row needs an outcome:** **Include in this payroll**, **Exclude from payroll**, **Move to a future payroll** or **Informational only**. Every outcome except Include needs a reason. Move to a future payroll also needs the future payroll it moves to.
- **Rows that didn't match** are listed under **Source rows not matched for payment**.

### Reactivating an inactive worker from the import

If an unmatched row is someone who is inactive or terminated in Cornerstone, the row says *"Name is inactive in Cornerstone."* or *"Name is terminated in Cornerstone."*

- **Any payroll staff member** (accountant, manager or admin) sees **Reactivate Name** for an inactive worker. A terminated worker is a rehire: only managers, admins and accountants with client-management delegation see the button. Everyone else sees *"Name was terminated. A manager or admin can rehire them."* It opens the reactivation window with the pay period start as the default **Reactivation effective date**. Use the first day they're working again.
- **After reactivation**, the import matches the same files again by itself. There's no re-upload and no reason to type. The row becomes ready, other outcomes stay, and a status line says **Matched again after Name was reactivated**.
- **Open profile** opens the worker's profile in a new tab. If your access doesn't allow reactivation (for example, a read-only test workspace), the row says *"You don't have access to reactivate Name."* instead of showing the button.

For a review that came from a client portal revision, reactivating reopens that client revision instead.

### Hours entered by hand

If someone's saved hours were changed by hand after an earlier import, and the new Revel hours would change them, the review shows **Revel hours will replace hours entered by hand (n)** with old → new hours per person. Tick **Replace the hand-entered hours with the Revel hours above.** only if the Revel figures are right. Otherwise fix the source first.

Owner pay you entered (Mo's and Sarah's period pay) doesn't trigger this prompt.

### Loans: one-time vs installment

The workbook has two loan tabs, and the import treats them differently:

- **LOANS (NO INSTALLMENTS)** is for one-time or varying loan deductions.
  - If the employee has no recurring loan in **Employee Loans**, the amount is deducted as entered.
  - If they do have one, the amount must match that loan's scheduled amount for this payday. Otherwise you get *"[loan] is $X for this payday, but the workbook says $Y…"*.
  - If that loan is paused, you get *"…is paused or not scheduled for this payday…"*.
- **INSTALLMENT LOANS** must match a balance-tracked loan already set up in **Employee Loans**.
  - If there isn't one, the row is blocked with *"Set up the named installment loan for Name in Employee Loans before importing this amount."* Set it up, then preview again.
  - The workbook's beginning balance plus any new amount must equal the Cornerstone balance, and the payment must match the schedule.
  - A new advance in the workbook is noted, not added twice.

### Older workbooks

If the workbook is an older layout, the review asks **Were the tips in this older MoSa workbook already paid out daily?** Answer it before applying.

When **Needs your action** is empty, choose **Apply Import (N employees)**. Applying saves the hours, tips and loans to the pay run.

## 3. Expected entries and missing regulars

The **Expected entries** panel on the pay run lists the entries MoSa needs every period. These are set per client in **Standing Changes** (labels, help text, the employee, owner pay or extra hours, **Required each period**, **Allow None this period**, and order). For MoSa they are Mo's pay, Sarah's pay and Jordan's hours. Addison isn't in Revel.

For each entry:

- Type the amount or hours, then choose **Save and calculate**.
- If the entry allows it and there's nothing this period, choose **None this period**. You can add an optional note. **Undo none for [label]** reverses it.
- Each entry shows **Filled**, **None this period**, **Excluded this period** or **Missing**.
- If the client sent the entry through the portal, it says **From client: revision N**.

**Usually paid.** Below the entries, the panel lists active employees who were paid in recent regular runs but have no pay in this one. The default rule is paid in 3 of the last 4 committed regular runs. Change it under **Missing regulars** in **Standing Changes**. For each person:

- **Enter pay for Name** adds them to the hours worksheet so you can enter hours, then calculate.
- **Not paid this period** records that they're intentionally not paid this run. You can add an optional note. **Undo not paid for Name** reverses it.

The panel's first line says **Resolve these entries before approval: …** until everything is filled or answered. Then it says **All expected entries are resolved.** Approve and Commit stay off until it's resolved. The panel only shows while the run is a draft or calculated, so unapprove first if you need to change an entry after approving.

## 4. Calculate, review, approve

1. Choose **Calculate Payroll** (or **Recalculate**). If you changed anything after calculating, the run says **Recalculate to include your changes**.
2. Review the results, the **Prior-period comparison**, and every warning.
3. Choose **Approve**.

**The "Prior-period payroll review remains open" note.** Since PR #467 this note appears only when the worker's earlier payroll this year has an unresolved problem in Cornerstone. That means a reversed paycheck, a voided pay period, or a legacy disposition that isn't verified-empty. Imported paycheck history and verified-empty $0 rows no longer trigger it. The note names the specific paycheck or pay period IDs, for example *"…needs accountant review: reversed paycheck #123…"*. It doesn't block approval, and it says the current paycheck's Social Security and Medicare are unaffected. Treat it as a to-do for the historical review, not a problem with this run.

Approval is blocked by a different FICA message: *"Recalculate — another payroll for this employee changed their year-to-date…"* (see [Troubleshooting](#troubleshooting)).

## 5. Download preview for the client

A calculated or approved run has **Download preview**. It's on the **Checks & payments** tab and next to Approve or Commit in the run header. Choose one of:

- **Checks and pay stubs**: paper checks first, then a pay stub for every employee, including direct deposit and $0 net.
- **Checks only**
- **Pay stubs only**

Every page is marked PREVIEW and check numbers are blank. Check-stub year-to-date includes this paycheck. The file name ends in the review revision, for example `…_PREVIEW_2026-11-19_rev3.pdf`.

Open the PDF before sending it. Check the first and last checks, a few stubs and a direct-deposit stub. Then send it to MoSa the usual way.

A download doesn't number checks, record printing or change the run. Each download is recorded with who downloaded it and which revision. If the run changes after you download, the card says **The last preview was revision N; download a new one.** Also download a new preview after changing an employee's name or address, or the check settings. Those change the PDF without creating a new revision.

If MoSa asks for changes: **More payroll actions** → **Roll Back Approval**, fix the entries, **Recalculate**, **Approve**, then download a new preview.

## 6. Client approval in the portal (only when turned on)

This step applies only when the client's **Require client approval before payroll commit** setting is on. The setting is on the client's edit page (**Client Management** → **Edit**). Managers, admins and accountants with client-management delegation can change it. When it's off, staff approve and commit, and the client isn't notified. MoSa had it off as of November 17, 2026. Check the setting before each cycle.

When it's on:

1. **Approve publishes the preview.** Approving the run publishes that revision's PREVIEW checks and stubs to the client portal and notifies the client. The run shows **Client review revision N · Awaiting client review**.
2. **The client reviews it** in the portal under **Review preview** (**View preview** or **Download preview**).
3. **The client decides:**
   - **Approve this revision**: the client ticks the acknowledgement. A note is optional.
   - **Request changes**: a note is required. The run shows **Name requested changes** with the note, and Commit is blocked with *"Name requested changes: … Unapprove to make changes."* Choose **Unapprove to make changes**, fix it, recalculate and approve again. That publishes a new revision for the client.
4. **Email approval.** If the client approves by email instead, choose **Record Email Approval** on the approved run. Pick the assigned client user and record where the email is kept. "Thanks" or "received" isn't approval.

A pending change request blocks commit even if the setting is later turned off. Unapproving withdraws the revision and its client approval. Even with unchanged amounts, the client has to approve the new revision.

### Outstanding file requests

If a file request to the client in **Pay Period Files** is still open for this period, the commit dialog lists it under **Outstanding client file requests**. To commit anyway, tick **I reviewed these outstanding requests and will finalize payroll without the requested files being accepted.** The acknowledgement and the request details are recorded. The requests stay open.

## 7. Commit

Choose **Commit**. The **Commit and finalize payroll?** dialog shows the company, run, dates, item count and total net pay.

- **Check numbering.** If anyone is paid by paper check, it says **Paper checks will be numbered from N (last used: M)**.
  - If N is at or below M, a warning asks you to check the stock first.
  - Managers, admins, and accountants with check-settings delegation get a **Review check settings** link.
  - Fix the number before committing if it doesn't match the next check on the stock.
- **Warnings.** Any compliance warnings are listed under **Review these warnings before committing**.
- **Confirm.** Choose **Confirm commit**, or **Keep reviewing** to back out.

Commit locks the payroll and updates year-to-date totals. Later changes go through the corrections workflow.

## 8. Print and download

On **Checks & payments**:

1. Choose **Print checks**.
2. Check each **Check number** against the stock. Change any that don't match, then **Save check numbers**.
3. Choose **Generate and save package**, then **Open saved PDF to print** (or **Download**).

Direct-deposit stubs are separate from paper checks. Printing a stub doesn't start a bank transfer. The **Reports** tab has the **Full Print Package** with the transmittal. Reports downloaded before commit are marked "PREVIEW, payroll not yet committed". After commit they aren't.

## Mark inactive

Use **Mark inactive** on an employee's profile when the person still works for MoSa but won't be paid for a while: leave of absence, seasonal, or no hours scheduled. Inactive workers aren't paid until they're reactivated. Use **Terminate Employee** when employment has ended.

- **Who:** any payroll staff member: accountants, managers and admins. Terminating, and reactivating a terminated worker, stay with managers, admins and accountants with client-management delegation.
- **How:**
  1. Open the employee, choose **Mark inactive**, and set the **Inactive effective date**. It can't be in the future.
  2. Pick a reason and add notes if useful, then confirm with **Mark inactive**.
  3. If the person is on open pay runs, the window lists them. Remove them from runs that start on or after the date before approving. Runs that start earlier keep them for the days they worked.
- **Undo:** choose **Reactivate** on the inactive profile banner, or reactivate them from the import review (see [Reactivating an inactive worker](#reactivating-an-inactive-worker-from-the-import)).

Every change is recorded in the employee's status history and the audit log.

## Troubleshooting

| Message | What it means | How to clear it |
| --- | --- | --- |
| **Add the Tips & loans workbook, or confirm there are no tips or loans this period.** | The import is missing a required file. | Add the workbook, or tick **No tips or loans this period**. |
| **Name is inactive in Cornerstone.** or **Name is terminated in Cornerstone.** (unmatched row) | The row belongs to an inactive or terminated worker. | Choose **Reactivate Name**. The import matches again by itself. For a terminated worker, a manager or admin does this. |
| **Revel hours would replace hours entered by hand for …** | Hours saved by hand differ from the new Revel hours. | Tick **Replace the hand-entered hours with the Revel hours above.**, or fix the source. |
| **Set up the named installment loan for Name in Employee Loans before importing this amount.** | The workbook has an installment payment with no matching loan. | Set up the loan in **Employee Loans**, then preview the import again. |
| **Unapprove this pay run before applying an import** | You're importing into an approved run. | **Roll Back Approval**, then apply. |
| **Resolve expected entries before approval or commit: …** | A required entry is empty, or a usual employee has no pay. | Fill or answer each item in **Expected entries**. |
| **Resolve ineligible workers before approval or commit: …** | Someone on the run is inactive or terminated for these dates. | Remove them from the run, or reactivate them. |
| **Enter Pay this period and recalculate payroll for … before approval or commit.** | A variable-salary owner has no period pay. | Enter the amount (Expected entries or the worksheet), then recalculate. |
| **Recalculate — another payroll for this employee changed their year-to-date. …** | Another run changed this employee's year-to-date after you calculated. | **Roll Back Approval** if approved, recalculate, review, approve. |
| **Recalculate — this payroll lacks annual context verification. …** | The run was calculated before annual FICA checks existed. | Same as above. |
| **Payroll source revision changed after calculation. …** | Files changed after you calculated. | Apply the current import, then recalculate. |
| **Review the pending portal revision: import it or record a source disposition before approval or commit.** | The client sent a new portal revision. | Open it from **Pay Period Files** and import it, or record why it's set aside. |
| **Client approval is required for this revision before commit.** | Client approval is on and the current revision isn't approved. | Wait for the client, or **Record Email Approval** with evidence. |
| **Name requested changes: … Unapprove to make changes.** | The client asked for changes on this revision. | **Unapprove to make changes**, fix, recalculate, approve again. |
| **Acknowledge the outstanding client file requests before committing payroll.** | A file request is still open. | Tick the acknowledgement in the commit dialog. |
| **Remove draft check numbers for direct-deposit employees before approving payroll for …** | A direct-deposit employee has a check number. | Clear the check number for those employees. |
| **This payroll changed while the preview was being prepared. Download it again.** | The run changed during the download. | Download the preview again. |
| **Preview is only available for calculated or approved pay runs …** | The run is a draft, committed or voided. | Calculate a draft first. Use **Print checks** for committed runs. |
| Starting check number field is disabled | Only managers, admins, and accountants with check-settings delegation can change check numbering. | Ask someone with that access. |

## Related

- [Manual preview fallback](MANUAL_PREVIEW_CHECKS_AND_STUBS.md), superseded by **Download preview**
- [Role and permission matrix](../ROLE_PERMISSION_MATRIX_2026-05-14.md)
- [MoSa rollout cycle runbook](../rollout/02-MOSA-CYCLE-RUNBOOK.md), for parallel-run and cutover evidence
