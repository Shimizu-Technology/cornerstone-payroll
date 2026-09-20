# AIRE ↔ Cornerstone payroll reconciliation: local implementation record

## Decisions and release boundary

- AIRE work periods remain the 1st–15th and 16th–last day of the month. The **same** work period locks seven calendar days after its saved scheduled *regular* pay date, at 5 p.m. Guam. Adjustment runs do not change the deadline. The September 20 read-only production snapshot shows the August 1–15 regular run paid August 31 and the August 16–31 regular run paid September 15; the pay-schedule rule is `manual`, not next-day. The corresponding cutoffs under the new rule would be September 7 and September 22. Confirm future scheduled pay dates explicitly rather than inferring a next-day rule.
- The payroll operator has already delivered the physical checks discussed for Workers A, B, and C. Do not void the physical payments to repair a software ledger.
- Treat the standalone check records for Workers A and B as possible duplicate *representations*, not extra payments. Confirm their exact linkage and financial effects before any production mutation. Do not delete or void them merely because an adjustment pay period also exists.
- All implementation and testing remain local. No production write, merge, or deployment until Leon has manually tested and explicitly says to proceed.

## Why the workflow needs two phases

The regular payroll is paid before AIRE's seven-day lock. A finalized AIRE batch therefore cannot supply hours for that normal payment. Cornerstone needs a **pre-pay live snapshot** of approved AIRE entries, with source entry IDs, versions, employee UUIDs, work dates, categories, regular/OT splits, and an immutable capture time/checksum. Changes after capture must be visible as differences, not silently overwrite a calculated run. When the period locks, AIRE must publish a final view that Cornerstone compares with the captured and paid lines. Unpaid differences become explicit carryovers or corrections. A zero-hour final batch can be correct if those hours were already acknowledged as paid manually or from the pre-pay snapshot.

## Local work in progress

- AIRE records exact manual paid-hour allocations against a source time entry and Cornerstone payroll item, with committed, issued, and void events. Active allocations are subtracted from later payable batches. A legacy uncategorized entry uses its sole active assigned category without silently changing the historical entry.
- Cornerstone can link an existing committed payroll item to exact AIRE entry hours, show the result in the manual-hours review, and send payment-issued status only after check delivery. Failed syncs remain visible and retryable. Existing employee mapping can be made from a live AIRE identity, with conflicts blocked.
- The production-copy browser drill matched Worker A's permanent AIRE identity to the existing Cornerstone employee, bulk-linked all nine source entries to the supplemental paycheck, and retried a deliberately failed sync through the UI. Both local databases now show 9 committed allocations totaling 6.10 regular hours. The screen separately reports **0.00 unlinked** and **6.10 linked, awaiting payment evidence**; it does not claim those hours were paid merely because the check was printed. A test-only one-day AIRE delegation was created in the writable copies to exercise the real service path; no production delegation or credential was changed.
- The regular cutoff contract has been changed locally to pay-date-plus-seven at 5 p.m. Guam. Synthetic browser testing covered manual calculation, check delivery, exact AIRE acknowledgement, and a local finalization. The full finalized event-delivery loop was not covered by that browser test.

## Required before calling the connected path complete

1. Add the immutable pre-pay AIRE snapshot and Cornerstone import/apply flow, including employee and wage-category mapping, stale-version checks, held time, and OT review. The existing live summary import lacks exact entry-level payment provenance.
2. At check issue or confirmed direct-deposit settlement, acknowledge the exact imported AIRE entries as paid. Printing a stub or committing a payroll is not payment evidence. Reversals need audited, idempotent compensation.
3. Compare the final post-lock AIRE batch to the pre-pay snapshot and actual paid allocations. Show per-person paid, unpaid, held, carryover, and corrections; route differences to the next regular or a specific supplemental run without double-paying.
4. Make an AIRE-created employee visible in Cornerstone as a reviewable onboarding candidate. Preserve a one-to-one permanent UUID link; do not silently create a payable employee or infer rates/tax settings. Resolve historical inactive/duplicate identities before mapping.
5. Give the payroll operator one clear Cornerstone path for both manual and connected processing, with blocking issues and precise instructions. Keep the AIRE-side view equally clear about regular hours, OT, carryover, and paid status.
6. Test real next-day pay dates, end-of-month/leap-year boundaries, post-pay lock, revised hours, partial payments, payment voids, a direct-deposit confirmation, late approvals, supplemental checks, stale/duplicate commands, and worker retries in local synthetic databases. Then Leon tests the UI manually. Only afterward prepare production release and read-only verification.

## Production-shaped local test and remaining verification

A September 20 read-only production snapshot of both databases is held in an isolated local PostgreSQL cluster outside Git; writable test copies use local-only AIRE and Cornerstone URLs. The raw snapshots default to read-only and must never be used as app write targets. The private reconciliation findings, including worker names, check numbers, and amounts, are deliberately outside this repository.

The snapshot confirms the three supplemental payroll items and their source hours. It also shows earlier regular payroll items for the same workers, so those older payments need exact-entry paid-history attribution before the final AIRE ledger can safely say what remains owed. The standalone check records for Workers A and B have no pay-period link or bank-clearing evidence; they require an audited superseded-record disposition, not deletion or an assumed financial void. The adjustment payroll items have printed check events but no recorded delivery event, despite the owner's confirmation that the physical checks were handed out. Record the actual delivery evidence before automatically acknowledging payment in AIRE.

The local browser shows the August 16–31 regular run cannot publish the new AIRE calendar retroactively: the confirmed payroll setup takes effect August 23, after that work period began. Historical August reconciliation therefore needs an explicit backfill path; changing the setup effective date silently would rewrite employer-approved policy history. A future regular run can use the pay-date-plus-seven rule after its saved pay date is reviewed.

The production-copy dry run exposed a false negative-overtime correction when an unchanged paid week was reinterpreted under the current allocator. The local fix now yields only Worker A's nine late-approved source entries (6.10 regular hours, zero overtime) for that adjustment review. A synthetic regression test and the complete AIRE backend suite cover the fix. This is not yet proof of the full connected payroll workflow.

Confirm Worker D's rate, Workers E and F's payable employee setup, the historical paid-entry attribution, and the physical delivery dates with the payroll owners before any production reconciliation write.
