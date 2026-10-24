# Legacy FICA release procedure

The annual FICA ledger holds payroll when committed legacy SS or Additional Medicare bases cannot be established. Recalculating the pending run cannot repair historical evidence. Inventory and reviewed recovery must precede the first calculation after this deployment. This is a release operation for payroll administrators, not a financial backfill.

## Release order

1. Deploy migrations through `20261024100000` after the verified-year migration `20261024093000`. Keep payroll calculations/finalization paused during review. Verify the pay date's tax-year configuration through the existing verified-year process; recovery never uses a nearest year, an unverified year, or a different year's cap.
2. Run inventory **read-only in production** through the normal deployment runner. Retain its JSON as the review artifact. The inventory task executes SELECTs only and does not create proofs, alter financial rows, or contact providers:

   ```sh
   RAILS_ENV=production bin/rake payroll:fica_legacy:inventory > fica-inventory-before.json
   ```

   Optional `COMPANY_ID` and `TAX_YEAR` narrow the report. Global inventory emits each company/employee-year's counts, item IDs, status and reason. A missing configuration, inconsistent taxes, cap/threshold ambiguity, signed correction/reversed history, or changed proof remains held. A verified-empty disposition is excluded, as it is in W-2GU/941. Retired instruments remain included.
3. Review one company-year's proposed bases, verified rule sources, recorded taxes and digest. Default recovery is a read-only dry-run; the explicit flag also runs the dry-run rather than Rake's generic task-skip mode:

   ```sh
   RAILS_ENV=production COMPANY_ID=123 TAX_YEAR=2026 \
     bin/rake payroll:fica_legacy:recover --dry-run > fica-reviewed-plan.json
   ```

   Omitting `--dry-run` has the same safe behavior. A recoverable row's bases are derived from actual gross/Medicare wages and tips, a conservative whole-year bound and verified rules. Every known base is preserved; employee and employer SS/Medicare taxes must reconcile exactly after component rounding. Rounded tax is never inverted to guess a partial base. Unknown tip allocation at the cap or Additional Medicare threshold, contradictory taxes and correction ambiguity require separate reviewed reconciliation. Fully recorded rows and already-established proofs remain distinct from rows needing recovery.
4. After payroll review, apply **that exact company-year plan** with an active authorized administrator, an attributable review reference and the JSON's `plan_digest`:

   ```sh
   RAILS_ENV=production COMPANY_ID=123 TAX_YEAR=2026 ACTOR_ID=456 \
     REVIEW_REFERENCE='Payroll review ticket and retained reconciliation artifact' \
     PLAN_DIGEST='<reviewed plan_digest>' \
     bin/rake payroll:fica_legacy:recover --apply > fica-recovery-receipt.json
   ```

   Apply re-reads under Company → PayPeriod financial locks and refuses a changed plan before any proof is written. It appends only `PayrollItemFicaBasisProof` records, including actor, review reference, plan digest, financial-source digest, derivation, year rules and original inventory dependency digest. It does not update wages, taxes, YTD, liabilities, checks, approvals, tax-rule snapshots or any other committed financial amount. Unknown rows remain held. Proofs cannot be updated, deleted or truncated. Re-running a fresh reviewed plan is idempotent for established proofs.
5. **Re-run inventory read-only** and retain it beside the before/plan/apply artifacts:

   ```sh
   RAILS_ENV=production bin/rake payroll:fica_legacy:inventory > fica-inventory-after.json
   ```

   Confirm every employee-year needed for the next run is complete/proven, or arrange a separately reviewed reconciliation for held rows. Do not treat a partial recovery as clearance for the whole company run. Do not clear holds by filling fields with zero, rewriting financial history, changing dispositions on real pay, or marking unverified rules verified without their review.
6. Resume calculations only after that review. Pending pre-release calculations have older annual evidence: use **Roll Back Approval**, then recalculate, review and approve again. The server independently validates both verified-year evidence and the annual ledger at approval/commit. Corrective previews must be refreshed. Cross-year corrections remain held for a separately reviewed prior-year process.

## Proof lifetime and verification

A reviewed proof is an append-only attestation of one committed row's bases. Runtime checks its year/employee, exact financial-source digest and recorded tax/base corroboration. Its creation changes the annual fingerprint, so pending checks must be recalculated. Later signed adjustments or reversals of other checks do not erase an established per-row attestation; their active signed bases independently change the annual ledger. An altered source row invalidates its proof and holds calculation. A reversed/disposed row is removed by the shared financial/reportability scope. Proof rows and their original dependency digest remain available for audit.

Keep the proof table and review artifacts during a rollback or incident. No production inventory, apply or data repair was performed by the implementation agent; the commands above are required release steps for the deployment owner. Synthetic tests and local CLI receipts demonstrate the procedure without external provider calls.
