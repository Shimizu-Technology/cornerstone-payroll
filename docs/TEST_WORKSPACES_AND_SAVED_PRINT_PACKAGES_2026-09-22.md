# Test workspaces and saved check packages

Status: implemented. Complete the release evidence checklist below whenever this workflow changes.

This document records the intended Cornerstone workflow and its safety boundaries. The default test workspace is a flexible copy of a production client. Staff can explore setup, process practice payrolls, and review reports without changing production. Structured migration promotion remains available only when an administrator deliberately selects that advanced workflow.

## The default: a general test workspace

An organization administrator starts from **Client Management**, selects a production client, and chooses **Create test workspace**. The administrator can name the workspace, set an expiration, grant staff access, and choose how much payroll history to copy:

- Setup and employees only.
- All committed payroll history.
- Committed history before the latest 1–12 regular payrolls. The omitted payrolls may be Draft, Calculated, Approved, or Committed; they do not need to be committed first.
- Committed history through a selected pay period.

The preview explains exactly what will be copied or omitted before creation. Copying happens in the background, and the list updates automatically until the workspace is ready. More than one general test workspace can exist for the same production client.

Copied employee setup includes departments, pay rates, tax setup, direct-deposit setup, recurring additions and deductions, and employee payroll fields. Selected committed payrolls become locked reference history: they support year-to-date calculations but cannot be edited. Check numbers, payment state, filings, messages, documents, and external connections are not copied. Imported opening YTD balances are not copied, so administrators should use the migration rehearsal workflow when exact imported migration history is required.

The production client is never changed by creating or using a test workspace.

## Access

Organization administrators always retain administrative access. They can grant access only to active managers and accountants in the same organization:

- Operator: works in the isolated workspace and processes practice payrolls.
- Reviewer: inspects the workspace without processing payroll.
- Workspace admin: manages the isolated workspace.

Client users and employees do not inherit access. A staff member sees only production clients and test workspaces assigned through the normal company-access rules.

## Safety boundaries

Test workspaces support setup changes, employee changes, practice payrolls, calculations, approvals, and reports. They cannot commit payroll, issue or print negotiable checks, initiate payments, file returns, send reminders, communicate with clients, or sync external systems. These are server-side restrictions, not merely hidden buttons.

Copied reference history is immutable. Expired and archived workspaces are read-only for everyone, including organization administrators. An administrator can extend an expired workspace by 90 days or restore an archived workspace without losing its records or audit history.

## Lifecycle and cleanup

General test workspaces expire after 30, 60, 90, or 180 days. Expiration makes the workspace read-only; it does not delete it. Administrators can archive a workspace at any time, hide or show archived workspaces from Client Management, and restore one later. Hard deletion is not part of this workflow.

## Optional advanced workflows

### Migration rehearsal and promotion

Use a migration rehearsal when setup and real payroll results must move into a clean destination. It can be promoted only through the verified migration handoff: employee matching, payroll verification, a read-only destination backup, and a single transactional apply. Promotion must not send, print, file, pay, or sync anything externally.

The backup step runs asynchronously. The promotion panel remains open, displays progress, polls while the job is pending, and advances automatically when the backup is ready.

### Legacy training replays

Existing structured training replays remain readable and retryable for backward compatibility. New practice work should use a general test workspace and the appropriate copy boundary instead of requiring a two-payroll scenario.

## Saved check packages

Generating a check package creates an immutable PDF artifact and manifest. Closing the dialog does not lose access to it or generate another PDF. Reopening **Print checks** loads the latest saved package and lists up to 50 prior packages for that pay period.

Each package retains its check selection, check numbers, amounts, stock layout, creator, generation time, checksum, and confirmation state. Staff can view, print, or download the same PDF again. Creating another package is an explicit **New package** action.

An unconfirmed package can be confirmed only while its manifest still matches the current payroll records. If a check number, amount, record timestamp, void state, or print activity changes, the old PDF remains available as history but cannot be confirmed. The operator must generate a new package from the current queue. Confirmed packages remain immutable history.

## Correcting numbers on an unissued employee-check package

Generating a package does not issue its checks. Staff can correct the numbers on prepared, unissued employee checks from the pay run's **Checks** worksheet and choose **Save check numbers**. The save validates the entire batch, retains a renumbering audit trail, updates the transmittal and sign-off sheet, and advances the company's next check number when needed. Wages, taxes, deductions, and net pay do not change. This is a number correction; individual reissues are unnecessary when only the package was generated.

The saved package retains its original manifest and becomes outdated after a number correction. Open **Print checks**, choose **Generate replacement package**, review the current selection and numbers, and generate the new package. The old package cannot be used as the current package for download or issuance. Checks that have been issued, cleared, voided, or marked replacement-required retain their existing lifecycle restrictions. Prepared other-payment checks retain their separate restrictions.

The batch-save correction aligns the worksheet with the existing single-check correction path. Release evidence must cover generated-only checks on desktop and narrow layouts, corrected numbers after reload and in the new package manifest/render inputs, matching payees and amounts in the rendered PDF, unchanged payroll amounts, stale-package rejection, document/audit synchronization, duplicate-number rejection, and atomic rejection of a batch containing an issued check. Implementation and final deployment evidence will be recorded in the release comment on [PR #348](https://github.com/Shimizu-Technology/cornerstone-payroll/pull/348); local tests alone do not establish Cornerstone operator acceptance.

## Release evidence

Before this work is called operationally verified:

1. Create a local general test workspace that omits the latest two payrolls when one or both are not committed.
2. Confirm the workspace copies employee setup and recurring payroll fields, includes only the selected committed history, clears check/payment data, and leaves the production client unchanged.
3. Process a new practice payroll in the workspace and confirm commit, negotiable checks, payments, filings, messages, and integrations remain blocked.
4. Verify administrator, operator, reviewer, and unassigned-user access.
5. Archive the workspace, show it in the archived list, restore it, expire it, and extend it without losing data.
6. Run the application test, lint, security, and production-build gates.
7. Deploy the merged migration and application revision.
8. On production, use read-only checks to confirm the new builder, access controls, lifecycle actions, and exact deployed revision. Do not create, archive, restore, print, pay, or promote production records as part of deployment verification.
