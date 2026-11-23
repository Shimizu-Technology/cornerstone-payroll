# Payroll history review: plan of record (Nov 23, 2026)

Approved by Leon on Nov 23, 2026, after the AIRE run 127 hotfix (PR #535). This document is the spec for the work. Builders implement from it, and reviewers check against it.

## Why

When the annual FICA engine finds prior-year history it can't fully verify, it calculates the current paycheck with the conservative below-threshold method (`BelowThresholdFicaContext`). It then saves an accountant note on that paycheck: "Prior-period payroll history needs accountant review … Historical tax and filing review remains open." Each note names the history it couldn't verify, which is one of:

- a **voided pay period**, such as AIRE #2 (replaced by correction run #3) or AIRE #83 (replaced by #85);
- a **financially reversed paycheck**;
- a **legacy paycheck** saved before Social Security and Additional Medicare bases were recorded (`unverified_legacy_ids`, added in #535);
- an **unresolved legacy disposition**;
- **imported paycheck history**.

The note text says the review "remains open", but nothing can close it. The same yellow wall repeats on every pay run and in the commit dialog for the rest of the year. On Nov 23 that was 10 AIRE employees in run 127 and 7 Spike employees in run 134. MoSa's (reconciled imports), Cornerstone, Sweep and Shimizu Technology show no notes.

Clients and employees never see these notes. They appear only on the staff pay-run screen (`FicaHistoryReviewNotice` in `PayRunBlockers`, via `PayPeriod#annual_fica_review_note`) and in `PayPeriod#compliance_warnings`, which feeds `PayrollCommitDialog` and the payroll history query.

The header link "N held entries outside this payroll" (`PayPeriodDetail`, summing `payable_line_status.held.entry_count` from `TimeTracking::AllocationStatusSummary#held_summary`) counts every time-tracking exclusion, whatever the reason. In run 127 both entries were `denied_approval`. One of them had 0.00 hours. "Held" reads as if payroll is stuck.

## Principles

- **Detected, never hardcoded.** Review items come from the same conditions the FICA engine detects. No client, company, employee or pay-run IDs appear in code, migrations or seeds. It works the same for every client, for new clients, and for every time source: AIRE now, Revel and email imports, and the platform time module (Milestone 6).
- **Money stays put.** Nothing here changes a calculated amount. Resolving a review changes only notes and eligibility for future calculations. It never touches a committed paycheck.
- **Stable approvals.** A calculated or approved run must rebuild the snapshot it already has, so commit and client-review checksums still match. Resolution affects only calculations made after it.
- **Accountable.** Every resolution records who, when, the reason code and a free-text reference. It goes in the audit trail (`AuditLog.record!` with the Milestone 3 actor) and is reversible: reopening is also audited.
- **Self-invalidating.** A resolution binds to a digest of its subject. If the subject changes later, for example a voided run is edited or a paycheck is reversed again, the item reopens.
- **Role-based.** A new `StaffRolePolicy` capability, `review_payroll_history`, is granted to `super_admin`, `org_admin` and `admin` (Leon's decision: admins do the review). It moves into the Milestone 3-8 capability catalog unchanged.

## Workstreams

### C. Honest held-entry wording (small; ships first)

1. Classify time-tracking exclusions by reason code into:
   - **not paid by decision**: `denied_approval` and similar;
   - **needs action**: pending approval, mapping or review;
   - **next payroll**: outside the cutoff;
   - **payment evidence pending**: reported payment.

   Unknown codes go to "needs action". The mapping is one source-neutral table keyed on reason code, shared by the API summary and the UI.
2. Exclude zero-hour entries from counts and headers. Keep them visible in the detailed list.
3. Change the pay-run header to show only actionable counts, for example "1 time entry needs action". Show decisions as information, for example "2 denied entries, not paid". Never use the word "held" for denied time.
4. Extend the API summary additively, for example `held.by_category`. Existing fields stay as they are.

### A5. One quiet line instead of the yellow wall (small; ships with C)

1. On the pay-run screen and in the commit dialog, replace the per-employee paragraph wall with one line: "N payroll history item(s) awaiting accountant review. This payroll isn't affected." Link it to the review checklist (A2).
2. Keep the per-employee detail behind a disclosure on the pay run until A2 ships, then link to A2.
3. Don't change the saved snapshot note text. This is presentation only.

### B1. Legacy recovery tool: correct by construction

Fix the defects the PR #535 reviews found in `PayrollFicaLegacyRecovery`:

1. **Proofs must not invalidate later fingerprints.** v3 fingerprints include `reviewed_legacy_basis_evidence`, so applying a proof to an earlier row changes the recomputed fingerprint of every later row calculated before that proof existed. v2 omits proof evidence. Make verification time-scoped: when recomputing a stored fingerprint, include only proofs that existed when that row was calculated, comparing the proof's `created_at` with the row's calculation time from its saved snapshot or row timestamps. Apply the rule consistently to v2 and v3, and keep existing stored fingerprints verifiable.
2. **Verify before writing.** Inside `apply!`'s locked transaction, after creating proofs, re-run ordinary verification for every committed row of each affected employee-year. Then calculate a zero-wage probe. If anything holds, roll back and report which row failed.
3. **Truthful inventory status.** An employee-year is `ready` only if a real ordinary probe (`EmployeeYearFicaContext#recorded_increment` with zero deltas, or equivalent) succeeds after its proofs would be applied. `held` keeps the actual reason. Remove the inference from row labels. This covers the case of a complete row with partial SS bases.
4. **Tests:**
   - legacy rows plus later committed rows with v2 and v3 fingerprints: dry-run, apply, then the next ordinary calculation succeeds;
   - a proof created after a later row was calculated doesn't break it;
   - the partial-SS-bases case stays `held`;
   - digest mismatch refuses to apply.

### A1–A4. Payroll history review items

1. **Model.** `payroll_history_review_items`:
   - `company_id`, `tax_year`, `subject_type` (`voided_pay_period` | `reversed_payroll_item` | `legacy_basis_gap` | `legacy_disposition` | `imported_history`), and polymorphic or typed subject reference(s);
   - `employee_id` for employee-scoped subjects (`legacy_basis_gap` is per employee-year; a voided run is one item covering everyone in it);
   - `status` (`open` | `resolved`), `subject_digest`, `resolution_code`, `resolution_reference` (text, 10–1000 chars), `resolved_by_id`, `resolved_at`, timestamps.

   Use the repo's `restrict` foreign-key conventions. Add a unique index on `(company_id, tax_year, subject_type, subject identity)`.
2. **Detection.** One service builds the open set for a company-year from the same predicates the FICA engine uses (`BelowThresholdFicaContext#unresolved_history?` / `review_note` conditions, `unverified_legacy_ids`, imported paychecks). It's idempotent, safe to run at calculation time, and also available as a rake task. Items are created lazily, and a resolved item whose `subject_digest` no longer matches returns to `open`. Resolution and reopening are audited.
3. **Resolution codes.** Start with:
   - `void_replaced`: voided and replaced, never paid;
   - `void_reissued`: voided after payment, with a reissue recorded;
   - `reversal_reviewed`;
   - `legacy_basis_proven`: set automatically when B2 proofs are applied;
   - `legacy_basis_accepted`: accountant accepts the conservative bound for the year, with a reference;
   - `imports_reconciled`;
   - `other` (reference required).

   The UI shows the subject's facts: the voided run with its pay date and status, the replacement run(s), item counts and gross, checks or deposits issued, and the void reason.
4. **Engine integration.** When an item is resolved, its subject no longer counts as unresolved history for **new** calculations. Notes then omit it, and an employee with nothing left open gets no note. Already-saved snapshots rebuild byte-identically for approval and commit (gate it on the snapshot's own content or version, never on current review state). A `legacy_basis_gap` stays eligible for the bounded fallback until proven, but once resolved as `legacy_basis_accepted` it's dropped from the note.
5. **A2: Year-End Filing checklist.** Add a "Payroll history review" section to the Year-End page for the selected client and year. It lists open items first, each with a review action (reason code plus reference, confirmed) and a reopen action. It only reads for users without `review_payroll_history`.
6. **Permissions and API.** Staff admin endpoints are company-scoped (`can_access_company?`), with `review_payroll_history` required for resolve and reopen. Index and show follow `view_record_activity`.

### B2. Proofs from the checklist

A `legacy_basis_gap` item gets a "Review proposed bases" action. It shows the B1 dry-run for that employee-year:
- proposed SS and Additional Medicare bases;
- the stored taxes they reconcile with;
- the plan digest.

Applying it calls `PayrollFicaLegacyRecovery#apply!`, scoped to the employee and fully verified as in B1, with the reviewer as actor and the reference text. It then resolves the item as `legacy_basis_proven`. The rake tasks remain for operations.

### Year-end check (before W-2s)

Confirm how W-2 boxes 3 and 5 and the quarterly packet treat legacy rows with nil bases, before and after proofs, for AIRE and Spike on a local production clone. Record the result here. If any report derives wrong wages from nil bases, fix it in the B release.

**Result (Nov 23, sanitized local clone of production):**
- `W2GuTaxableWages` falls back to computed wages when a saved base is nil, and the aggregator applies the SS wage base. For every flagged employee (22 AIRE, 14 Spike), box 3 plus box 7 equals the SS tax withheld divided by 6.2%. No one is near the cap. The W-2 amounts are correct.
- The year-end flow also raises a separate `legacy_tax_bases` judgment warning (`YearEnd::JudgmentWarnings`) for the same employees. PR 3 ties it to the review items. Resolving an employee-year's `legacy_basis_gap` marks that warning reviewed, so admins handle it in one place.
- Not yet checked: the quarterly packet. Check it in PR 3's clone verification.

## Release order

1. **PR 1: C + A5.** Presentation and additive API only. No tax logic changes.
2. **PR 2: B1.**
3. **PR 3: A1–A4 + A2 + B2.** Migration, detection, engine integration and UI. Depends on PR 2 for B2.
4. **Operations:**
   - run detection read-only on production and review the item list privately;
   - Dafne, or an admin, works through AIRE's and Spike's checklists;
   - do the year-end check;
   - target: before January W-2 preparation.

Each PR follows the Shimizu PR workflow:
- focused tests plus the full CI suite;
- a cross-family review;
- a local production-clone check by the lead before merge;
- deploy order after main CI: web, then worker, then Netlify.

PR 3's migration is additive and runs in `db:safe_prepare`. It doesn't need a maintenance window unless measurement on the clone says otherwise.

## Acceptance

- AIRE run 127 and Spike's latest run, recalculated on a production clone after resolving their void items: no per-employee wall, only legacy items left open. After B2 proofs, no notes at all. Every amount is unchanged.
- An already-approved run with an old note commits after this ships.
- MoSa's stays clean. Kasperbauer runs 96–115 are never touched.
- Held-entry header on run 127: "2 denied entries, not paid" as information, nothing actionable, and the 0-hour entry not counted.
- Non-admin staff (manager, accountant) can see the checklist but can't resolve items.
- No client-, company- or run-specific constants anywhere in the diff.

## Milestone fit

- Builds on Milestone 3: the audit actor (M3-3), effective-dated compensation, so paycheck math stays history-correct (M3-4), and the capability catalog (M3-8).
- Source-neutral exclusion categories carry into the Milestone 6 time module unchanged.
- No conflict with the M3-4 pay-rate window.

## Local production clone (lead only)

Verification uses a `pg_dump` of production restored into a local database named `cornerstone_prodclone_<date>`. It's used only by the lead on the MacBook:
- via `rails runner`, specs, and a local web server bound to loopback;
- with no worker or scheduler;
- with outbound mail, AIRE and other integrations disabled.

The dump and database are deleted when verification ends. No clone data goes into the repository, briefs, logs or chat.
