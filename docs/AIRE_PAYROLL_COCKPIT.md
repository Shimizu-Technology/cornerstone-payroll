# AIRE payroll workspace in Cornerstone

## Purpose

This workspace gives Cornerstone payroll staff the AIRE facts and actions they need for a normal payroll run without requiring them to sign in to AIRE. AIRE remains the system of record for time. Cornerstone remains the system of record for payroll calculation, checks, taxes, liabilities, reports, and payment status. AIRE retains an acknowledgement mirror of Cornerstone's batch, payroll-item, and payment events so AIRE can show each source entry's downstream state; the mirrored processing history does not become a second authority for whether Cornerstone paid someone.

The pay-period page presents:

- the exact AIRE punches, breaks, work dates, categories, capture methods, and hours;
- which entries are payable now and which are pending, denied, incomplete, or waiting on overtime approval;
- AIRE employees and their Cornerstone employee mapping;
- pending time and leave exceptions;
- hours held at an earlier cutoff and whether they remain unresolved, entered a later payroll, or were paid;
- cutoff readiness, the finalized batch identity and checksum, and Cornerstone processing history; and
- a due-period lock action plus approval or denial of manual time.

Ordinary clock and kiosk entries need no extra payroll approval. Manual and manually corrected entries remain held until an authorized AIRE administrator approves them. Time that is not eligible at cutoff is not lost or silently moved: AIRE records why it was excluded and carries it forward for the next available payroll.

## Trust and operator identity

Read requests use the client connection's shared secret. Commands also use a personal AIRE delegation token. Cornerstone encrypts that token at rest and never returns it to the browser after it is saved.

Each operator must save their own token under **Settings → Time Tracking Source → Your AIRE payroll access**. The setting reports only whether a token exists. Removing it disables that operator's AIRE commands without affecting read-only visibility or another operator's access.

Saving or removing delegated access writes a security audit event without recording the token. Removal permanently deletes the encrypted credential itself; the non-secret audit event remains as the access history.

AIRE remains the authority for command permission. On every command it verifies that:

- the token is valid, active, unexpired, and has the required capability;
- the linked AIRE user is still active, has personal access, and is still an administrator; and
- the submitted version is current.

Cornerstone records the signed-in Cornerstone operator and command ID in its audit log. AIRE separately records the delegated AIRE administrator. This gives both businesses an independent, traceable record without treating the shared system credential as a person.

Until AIRE has a grant-management screen, an AIRE administrator issues a token with `PayrollIntegrationGrant.issue!` from an authenticated Rails console. Use `time_approval` for time decisions and `payroll_finalization` for cutoff locking. Copy the one-time raw token directly into the intended operator's Cornerstone setting. Never place it in email, logs, tickets, or source control. Revoke the AIRE grant and remove the Cornerstone copy when access changes.

## Cornerstone endpoints

All routes are staff-authenticated and tenant-scoped. Cockpit routes are scoped to the active company and pay period:

- `GET /api/v1/admin/pay_periods/:pay_period_id/aire_payroll_cockpit`
- `GET /api/v1/admin/pay_periods/:pay_period_id/aire_payroll_cockpit/time_entries`
- `GET /api/v1/admin/pay_periods/:pay_period_id/aire_payroll_cockpit/exceptions`
- `POST /api/v1/admin/pay_periods/:pay_period_id/aire_payroll_cockpit/time_entries/:time_entry_id/approval`
- `POST /api/v1/admin/pay_periods/:pay_period_id/aire_payroll_cockpit/finalize`

Personal-delegation routes are scoped to the active company, named time-tracking source, and current operator:

- `PUT /api/v1/admin/time_tracking_sources/:id/delegation`
- `DELETE /api/v1/admin/time_tracking_sources/:id/delegation`

Read access follows the existing staff-workspace policy. Approval, denial, finalization, and personal-token management require the client-configuration capability. The AIRE service independently enforces the delegated administrator and capability.

The proxy keeps AIRE's pagination boundaries: 100 employees, 250 time entries, and 100 leave exceptions per page. The UI provides page controls whenever more records exist, so it does not silently omit staff or timecards.

## Failure behavior

Every response containing live payroll detail is marked `no-store`. The proxy retains AIRE's `409 Conflict` and `422 Unprocessable Entity` meanings so the interface can distinguish stale data from an invalid action. Authentication failures from AIRE become a failed dependency; unexpected transport failures become a bad gateway. Only a short JSON `error` message is eligible for display. Non-JSON bodies, arrays, and oversized responses are not surfaced.

Each command UUID identifies one logical approval, denial, or finalization decision together with the AIRE record version. An ambiguous transport retry reuses that UUID and version while the record is unchanged, so AIRE can replay the original receipt without executing the command twice. A changed record returns a conflict; the workspace reloads current data and creates a new UUID only when the operator makes a new decision against that new version.

## Deliberate boundary

This phase does not add direct editing of punches, missing-punch repair, or a new supplemental-payroll decision model. Those require the correction/case workflow planned next. The cockpit shows those facts and their carryover state now; it does not make an unsafe row edit look like a complete payroll correction.

Finalizing AIRE time does not calculate Cornerstone payroll, issue checks, pay liabilities, or mark wages paid. Direct deposit remains outside scope.

## Release checks

Before production promotion:

- migrate up, down, and up on a disposable database, then load `schema.rb` into an empty database;
- run the complete Rails and frontend gates;
- run the two applications locally with an isolated shared secret, published period, AIRE admin grant, employee mapping, ordinary and manual time, and a due cutoff;
- verify read-only access without a delegation, delegated approve and deny, stale-version conflict, cutoff lock, immutable batch verification, carryover visibility, and processing history;
- inspect the desktop and narrow/mobile layouts in the signed-in black Chrome profile; and
- verify the browser and both audit logs never expose either raw secret.
