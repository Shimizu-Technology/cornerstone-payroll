# Test workspaces and saved check packages

Status: implemented. The release evidence checklist below is required whenever this workflow is deployed.

This document records the intended Cornerstone workflow and the safety rules behind it. A test workspace exists so staff can rehearse real payroll work without changing a production client. A saved check package exists so staff can reopen the exact PDF they already reviewed instead of silently generating a different document.

## Test workspace model

The client switcher separates live production clients from test workspaces. Every test workspace names its purpose and source client. Live actions remain blocked inside test workspaces: they cannot commit payroll, issue payments or checks, file returns, send reminders, communicate with clients, or sync external systems.

Organization administrators create and archive test workspaces. They can grant access only to active managers and accountants in the same organization. Available workspace roles are:

- Operator: performs the rehearsal or practice payroll.
- Reviewer: inspects results without processing the payroll.
- Workspace admin: manages the isolated workspace.

Organization administrators retain administrative access. Client users and employees do not receive test-workspace access through this workflow.

## Payroll training replay

A training replay uses the latest two regular payrolls whose status is Calculated, Approved, or Committed. Those two payrolls are excluded from the locked year-to-date baseline and become draft practice payrolls. Earlier committed payrolls in the same tax year are copied as locked baseline evidence so calculations start with the right YTD totals.

When the isolated copy is prepared, Cornerstone freezes an immutable benchmark for each practice payroll. The snapshot contains the expected employee-level results and the source status at capture time. Later edits, approval, or commitment of the live source payroll cannot change what the trainee is measured against.

The practice payroll receives the original inputs but not calculated results, check numbers, payment state, filings, messages, documents, or external connections. The benchmark is hidden until the trainee calculates the practice payroll. The comparison then shows the frozen expected totals and employee-level differences.

This is the correct Spike workflow: the last two payrolls are disregarded as production history in the clone, but their inputs and frozen results are used as the two exercises. The live Spike payrolls do not need to be committed solely to create the replay.

## Migration rehearsal and promotion

A migration rehearsal remains a separate purpose. It can be promoted only through the verified migration handoff: employee matching, payroll verification, a read-only backup of the clean destination, and a single transactional apply. Promotion must not send, print, file, pay, or sync anything externally.

The backup step runs asynchronously. The promotion panel should remain open, show progress, poll while the job is pending, and advance automatically when the backup is ready. Requiring the operator to press **Refresh verification** is a known UI defect, even though the manual refresh does not affect data safety.

## Saved check packages

Generating a check package creates an immutable PDF artifact and manifest. Closing the dialog must not lose access to it or generate another PDF. Reopening **Print checks** loads the latest saved package and lists up to 50 prior packages for that pay period.

Each saved package retains its check selection, check numbers, amounts, stock layout, creator, generation time, checksum, and confirmation state. Staff can view, print, or download the saved PDF again. Creating another package is an explicit **New package** action.

An unconfirmed package can be confirmed only while its manifest still matches the current payroll records. If a check number, amount, record timestamp, void state, or print activity changed, the old PDF remains available as history but is labeled as changed and cannot be confirmed. The operator must generate a new package from the current queue. Confirmed packages remain immutable history.

## Archive behavior still to finish

Test workspaces already have an archive lifecycle, and only one active training replay per source client is allowed. The remaining usability work is a clearer archive action and an archived-workspace view so old rehearsals do not crowd the normal client list. Archiving must keep the audit trail and immutable benchmark or backup evidence; it must not hard-delete payroll history.

## Release evidence

Before this work is called operationally verified:

1. Create a local training replay from one Committed and one Calculated source payroll, calculate both practice runs, and confirm the comparison reads the frozen snapshot.
2. Change the source after capture and prove the expected training result does not move.
3. Generate a local check package, close and reopen the dialog, and view the same package without creating another run.
4. Deploy the merged migration and application revision.
5. On production, use read-only checks to confirm Spike is eligible for a replay without committing the latest Calculated payroll and confirm MoSa's saved package history is visible. Do not create, confirm, print, or promote production records as part of deployment verification.
