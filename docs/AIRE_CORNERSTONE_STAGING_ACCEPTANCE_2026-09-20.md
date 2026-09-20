# AIRE ↔ Cornerstone: staging acceptance and production setup

This is the operator checklist for the local implementation. Staging is a review
target, not permission to deploy. Do not merge staging into main or write to
production until Leon has tested the local UI and explicitly approves promotion.

## What the operator should be able to do in Cornerstone

1. Open a regular AIRE payroll period and see its scheduled pay date and the
   same-period cutoff: seven calendar days later, 5 p.m. Guam. Adjustment runs
   do not move that cutoff. Confirm the saved **regular** pay date before
   publishing the calendar; do not infer a next-day date from the work period.
2. Use the AIRE workspace to see team members, approved regular/OT hours,
   carryovers, held entries, and reasons. Existing numeric-only employee links
   appear for explicit permanent-ID verification. New AIRE people appear as
   onboarding candidates; creating a payable payroll profile still requires
   an admin to review identity, pay rate, tax settings, and payment method.
3. For connected payroll, capture the live, exact-entry AIRE snapshot before
   paying. Review source versions, employee and wage-category matches, held
   time, OT, and the calculated checks. Refresh and recalculate if AIRE changed.
   Commit the payroll only after those checks pass. A committed item is not
   marked paid in AIRE until a paper-check delivery or bank-settlement event is
   recorded. AIRE should show the actual delivery or settlement date, not the
   check-printing timestamp or the scheduled pay date.
4. For manual payroll, enter and calculate checks as usual. After commit,
   attach each paid AIRE entry to the exact payroll item from the manual-hours
   review. The link records regular/OT hours and original work date; it remains
   awaiting payment until actual delivery/settlement evidence exists. A failed
   AIRE sync remains visible and retryable. Historical issued allocations with
   no recorded payment date must say that the date is unknown; do not infer it.
5. After the AIRE cutoff, compare its verified final batch with the selected
   payroll's links and later payments of exact source entries. The final batch
   contains **residual hours at cutoff**: AIRE already subtracts active manual
   allocations before exporting it. Do not add paid and residual columns or
   subtract a pre-cutoff allocation twice. Held, identity-mismatched, and
   correction lines need review; they are not automatic new checks.
6. If a standalone software check duplicates a delivered adjustment-payroll
   check, link the duplicate to the exact issued payroll item with a reason.
   This preserves the audit trail and removes the duplicate representation
   from active totals; it does **not** void or delete the physical check.
   Once linked, neither its payroll item nor the containing pay period can be
   voided without a separate, reviewed reversal workflow; the app and database
   both reject an ordinary void. Reprints, replacements, and check-number
   corrections are also blocked because they would invalidate the verified
   physical-check evidence.
   Live-client links are disabled by default. Only after local acceptance and
   Leon's explicit production approval should an active organization admin
   create the append-only, company-specific rollout approval with a documented
   reason. No production approval is seeded by migration. The database also
   rejects links from unauthorized reviewers or unapproved live clients.

## Local acceptance cases for Leon

- Follow one employee through AIRE onboarding, permanent ID verification,
  live snapshot, calculation, commit, check delivery, and AIRE paid status.
- Repeat with direct deposit: the AIRE link may commit, but must stay unpaid
  until a unique bank reference and settlement date are recorded. Printing a
  stub is not payment evidence.
- Verify a paper check remains unpaid in AIRE after printing, then records the
  actual delivery date after the operator documents issuance. Do not backfill
  unknown historical dates from pay dates or audit timestamps.
- Verify regular and overtime splits, a late-approved/held entry, a carryover
  from a prior work period, a source edit after snapshot, and a source identity
  conflict. No stale or held hour should slip into the paid amount.
- Run the manual path and confirm the same entry cannot be over-allocated or
  silently linked to another employee. Confirm a failed sync has a clear retry.
- Review an inactive legacy-linked employee: permanent-link verification must
  not reactivate the profile or invent pay settings.
- Link a synthetic duplicate standalone check, verify it disappears from
  active totals, and verify the original record and reason remain in history.
  A check with no delivered payroll match must not offer that disposition.

## Production-shaped local data and release boundary

The raw AIRE and Cornerstone production snapshots are private, read-only local
databases outside Git. All migrations and edits use separate writable copies;
tests must never target the raw snapshots. The snapshot confirms that the
regular pay dates differ from the earlier next-day assumption. It also shows
older numeric-only employee links and historical paid hours that need explicit
entry-level attribution. No names, credentials, or payroll amounts from that
snapshot belong in this repository.

Before a production rollout, the payroll owners must attest the actual check
delivery dates for historical adjustments and confirm any bank settlement
evidence. The adjustment payroll items and the standalone check records must
be compared by exact number, amount, employee, and issued payment; do not
delete or void a record to make totals look right. Verify historical AIRE
entries against the earlier regular payroll items too, so paid history is not
mistaken for still-owed time. Confirm unresolved employee rates and onboarding
profiles with the payroll owners. Reconcile the old periods through the manual
historical path; do not silently backdate an employer-approved workweek policy
or publish a new calendar retroactively.

Promotion requires compatible AIRE and Cornerstone revisions, successful
migrations and workers, a read-only production preview, a named rollback plan,
and Leon's explicit approval. Run a new regular period in parallel first;
compare every person's regular/OT, gross/net, payment method, and AIRE paid or
held status before treating the connected path as the sole payroll process.
