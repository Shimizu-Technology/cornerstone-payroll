# Pay-period submissions acceptance (PR 5)

Built on main 461cc14f to the November 12 MoSa mailbox findings and Leon's decisions:
- periods come from the company pay schedule;
- any staff with access may acknowledge or post;
- files are kept indefinitely.

Nothing changes payroll or employee records automatically, and there is no import. PR 6 bridges to the MoSa importer.

**Environment**
- The implementation agent ran the browser QA on November 12, 2026.
- Isolated synthetic Rails test DB, auth-disabled identity proxy (client/staff by cookie), local storage, email disabled.
- CSS viewports 390×844 and 1280×900.
- Each width used its own two ended periods on a manual biweekly schedule with no anchor. That matches MoSa's configuration, so the offered periods are the pay periods Cornerstone created.

| Case | Observable and saved outcome | 390 | 1280 |
| --- | --- | --- | --- |
| Q1 Complete package | Client opens the period from Payroll Files and attaches the Revel PDF. They add all seven change kinds (hours, owner pay "each", paid leave, new hire, wage change, deduction continue, direct-deposit addition), a note and a timesheet, then send. After reload, revision 1 is shown with "Sent, waiting for Cornerstone to confirm". SQL: one revision, 7 change rows, roles revel_payroll and attachment, status submitted. | passed | passed |
| Q2 No changes | Revel PDF plus explicit "No changes this period". After reload, "No changes this period." is shown. SQL: no_changes true, 0 rows. | passed | passed |
| Q3 Replace Revel PDF | "Send an update or replace a file", choose the replacement PDF, send. After reload, revision 2 is current and revision 1 is marked Superseded; both are visible with their own Revel PDFs. SQL: revision 2 keeps the timesheet and all 7 changes; the original PDF remains unarchived. | passed | passed |
| Q4 Staff acknowledge and post | Staff find the "Pay period files" row in Client Inbox (Waiting on staff) and open it with "Back to Client Inbox". They confirm receipt of revision 2 (Received), then post the paycheck and direct-deposit PDFs. After reload: Draft 1 for review, status Draft ready. SQL: acknowledged_by is the staff user, status draft_ready. | passed | passed |
| Q5 Request change, then approve | Client requests a change with a note; the note appears in the period conversation; after reload, status is Changes requested. Staff post draft 2. Client sees draft 1 superseded and approves draft 2; after reload, Approved. SQL history: submit, submit, acknowledge, post_draft, request_changes, post_draft, approve, with correct audiences. | passed | passed |
| Q6 Staff see approval | Inbox (All activity) lists the period row and the period's conversation separately. Opening the period shows "Approved · client" in History. Mark paid, confirm; Paid persists after reload. Activity History has eight named entries. | passed | passed |

Every case checks for horizontal overflow at both widths; none was found. Runtime evidence:
- notification events: 6 sent, 2 acknowledged, 4 drafts posted, 4 decisions;
- all 16 deliveries skipped as `email_delivery_disabled`;
- 0 payroll items written;
- 0 employee records changed after seeding.

**Findings fixed during QA**
- Amounts and hours displayed as "$1200.0" and "35.0". Money is now stored as two decimals and hours without a trailing ".0".
- A carried-forward attachment was listed before a replacement Revel PDF. Documents now keep role order: Revel PDF, workbook, attachments.
- Superseded revisions said "Not yet confirmed". That wording now appears only on the current revision.

Both widths were rerun end to end on reset data after these fixes.

**Automation corrections** (test-driver issues, not app defects):
- a label substring matched a remove button;
- an inbox selector matched both the period row and the period conversation row.

**Not certified here:** real Clerk/Cable authentication, native phone keyboards, Safari and real email delivery. The advisory Impeccable scan of the new UI paths reported no findings.
