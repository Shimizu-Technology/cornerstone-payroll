# Operational Controls, Unified Printing, and Transmittal Plan

**Date:** July 16, 2026
**Status:** Approved implementation sequence before Payroll Phase 1B

## Why this work comes before Phase 1B

Payroll Phase 1B will record real liability payments, allocations, confirmation numbers, receipts, and settlement status. Those are sensitive financial actions. Before adding them, Cornerstone needs three operational foundations:

1. trustworthy user activity and audit history;
2. one controlled print workflow for every check created by a payroll run; and
3. one coherent transmittal workflow that can begin with a pay period or a standalone delivery.

These foundations reduce operational mistakes, make responsibility traceable, and give Phase 1B a stable place to surface payment evidence later.

## Agreed implementation sequence

### PR 1 — User activity and comprehensive audit logging

Purpose: make privileged and financial activity attributable, searchable, durable, and reviewable.

Required behavior:

- Track `last_login_at` as the start of an authenticated Clerk session.
- Track `last_active_at` from authenticated activity using throttled writes.
- Show who created or invited a user and when.
- Show role, company-access, invitation, activation, deactivation, and deletion history for each user.
- Record every successful state-changing admin/client request unless explicitly classified as a read-only preview.
- Record important security-sensitive reads and exports explicitly.
- Scope audit records to the organization, with an optional payroll-client scope.
- Treat the full audit history as an organization-governance surface: organization administrators see the complete firm history regardless of the currently selected client, while managers and accountants remain excluded from the organization-wide log.
- Preserve actor name, email, and role snapshots even if the user is later removed.
- Capture safe before/after values for user-management changes and safe field-name metadata elsewhere.
- Present activity in plain business language with the affected employee, user, pay period, or client named; keep request paths, HTTP methods, response codes, IP addresses, and request IDs under an advanced technical disclosure.
- Separate each user's actions performed from changes made to that user's account.
- Protect one permanent primary platform owner (`shimizutechnology@gmail.com`) at the database and application layers while allowing that owner and other super admins to create additional super admins.
- Never store passwords, tokens, SSNs, bank-account values, encrypted fields, or uploaded file contents in audit metadata.
- Make persisted audit records application-read-only.
- Support full-history pagination, filters, newest/oldest ordering, and CSV export rather than returning only the latest 200 rows.
- Clearly identify records created before detailed audit tracking when the actor cannot be reconstructed.

Non-goals:

- Logging harmless UI clicks, searches, or every page view.
- Inventing historical actors for actions that were never recorded.
- Replacing domain-specific immutable journals such as check events, invoice events, payroll correction events, or liability postings.

Exit criteria:

- A newly invited accountant has an attributable creation event.
- Editing that accountant records exact safe before/after values.
- Activating, deactivating, resending an invitation, and deleting a user are attributable.
- New authenticated sessions and recent activity update the correct fields without writing on every API request.
- Mutations in controllers that previously lacked `Auditable` coverage create organization-scoped audit events.
- Administrators can page from the newest audit event to the oldest retained event and export the filtered result.
- CSV export streams the full filtered history without loading every audit row into application memory.
- The primary platform owner cannot be demoted, deactivated, deleted, or reassigned, even by another super admin.
- Organization isolation, authorization, pagination, immutability, and sensitive-field redaction are covered by tests.

### PR 2 — Unified employee and non-employee check printing

**Implementation status (July 17, 2026):** Implemented on `codex/unified-check-printing`. The workflow creates an immutable, SHA-256-verified PDF artifact and a manifest snapshot before printing. Employee and non-employee records remain unmodified until the operator explicitly confirms the exact generated package; confirmation is rejected if any selected source record changed in the meantime.

Purpose: let the payroll processor prepare the complete check run from one place without wasting First Hawaiian four-up stock.

Required behavior:

- One `Print checks` action on the pay-period page.
- One selection queue containing employee and non-employee checks.
- Select all, clear all, and individual selection.
- Filters for employee/non-employee and printed/unprinted checks.
- Default selection of eligible unprinted checks.
- Check number, payee, amount, type, and print status visible before printing.
- Mixed First Hawaiian four-up output packed continuously in check-number order.
- Operator-selected starting slot.
- Selected-only preview, print, and PDF download.
- Explicit post-print confirmation before marking selected checks printed.
- Audit evidence for package generation and print confirmation.

The existing `FirstHawaiianFourUpCheckGenerator` already accepts payroll items and non-employee checks together. The implementation should extend that proven generator rather than create a second layout engine.

### PR 3 — Unified transmittal builder

Purpose: make the pay-period transmittal the authoritative starting point while preserving fully customizable standalone transmittals.

Required behavior:

- Start a transmittal from a pay period or from a blank standalone document.
- Auto-populate client, payroll dates, employee checks, non-employee checks, reports, and calculated tax obligations from the selected period.
- Include, exclude, reorder, relabel, and annotate individual items.
- Add fully custom items and notes.
- Use a shared professional document design.
- Preserve generated versions as immutable artifacts with actor and timestamp evidence.
- Keep existing saved pay-period and general-transmittal records backward compatible.
- Label payroll tax values as calculated obligations; do not represent them as paid before Phase 1B supplies settlement evidence.

Phase 1B will then enrich this document with actual payment status, dates, confirmation numbers, methods, receipts, and calculated-versus-paid differences.

## Phase 1B after these foundations

With the three PRs above complete, Phase 1B can safely add:

- liability payment records;
- allocations against exact committed payroll liabilities;
- due dates and unpaid/due/paid/overdue status;
- payment methods and confirmation numbers;
- receipt and evidence attachments;
- calculated-versus-paid reconciliation; and
- transmittal settlement sections backed by actual payment evidence.

## Delivery guardrails

- Keep each area in a separate PR with focused migrations and rollback-safe behavior.
- Prefer additive schema changes and preserve legacy records.
- Do not change payroll calculation formulas in these operational PRs.
- Do not automatically backfill invented audit history.
- Require backend request/model coverage, frontend type/build checks, security scans, and browser smoke testing proportionate to each PR.
