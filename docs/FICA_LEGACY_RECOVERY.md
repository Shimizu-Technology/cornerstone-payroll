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

## Ordinary checks provably within both thresholds

A disputed financial void can leave the old employee-year bases unresolved even when it cannot affect an ordinary current check. `calculable_below_thresholds` distinguishes this capacity from historical recovery. It does **not** reconcile a void, certify stored old taxes, approve W-2GU/941 filings, or create/apply `PayrollItemFicaBasisProof` records. Both `history_review_open` and `filing_review_open` remain true after commit. The existing pay-run warnings and commit dialog show the retained review note.

The new path only relaxes an existing annual-context hold. Already verified annual calculations, reviewed proofs, signed corrections and cap allocations retain their existing behavior. When the independent bound is also provable for an already calculable ordinary check, the same review snapshot can be retained. Failure to establish that optional bound does not invalidate an already verified annual calculation.

### Source completeness is required

An empty import table cannot establish that external or predecessor wages are zero. Before using the new path, an authorized payroll administrator must review **all same-employer wage sources**, including predecessor obligations, source systems not imported here, and any missing/deleted historical source records. Record conservative upper bounds for all wages outside the enumerated local candidates/opening balances, through at least the intended payday. Use explicit zero only when the retained evidence establishes no such wages:

```sh
RAILS_ENV=production COMPANY_ID=123 EMPLOYEE_ID=789 ACTOR_ID=456 TAX_YEAR=2026 \
  THROUGH_PAY_DATE=2026-11-15 EXTERNAL_SS_WAGE_BOUND=0 EXTERNAL_MEDICARE_WAGE_BOUND=0 \
  REVIEW_REFERENCE='Retained source-completeness workpaper covering all employer/predecessor wages' \
  bin/rake payroll:fica_legacy:review_sources
```

This command is an attributable source review, **not** a historical tax/basis attestation. It appends an `EmployeeYearFicaSourceReview` under the Company financial lock. Later reviews supersede earlier ones by ID; expired or absent coverage leaves existing holds in place. Re-review when outside wages change or coverage expires. No production review was recorded by this implementation.

### Eligibility and saved evidence

- Verified configurations for the exact tax year must agree with the current calculator and all captured historical rule amounts. Current wages and the finalized wage/tip split must be finite and nonnegative. Signed corrections and tip reclassifications never use this path.
- Count **every** noncontractor committed same-company employee-year candidate, including financially voided/reversed/disposed originals and replacements. Use each candidate's positive maximum gross, Medicare wages and recorded SS wage-plus-tip bases. Count every applied opening/YTD bridge revision, deliberately double-counting overlaps, and add the reviewed external/predecessor bounds and full current wages. No disputed exclusion reduces this upper bound.
- Missing legacy SS/Additional Medicare bases may remain missing; every present base must agree with ordinary uncapped wages/tips, and saved employee/employer SS and Medicare taxes must exactly corroborate those wages under verified rules. A nullable legacy Additional Medicare tax is accepted as zero only when the complete Medicare wage bound is at or below the configured Additional Medicare threshold and both saved employee/employer Medicare totals exactly match base Medicare under verified rules. This treatment was explicitly approved for this path; any mismatch, nonfinite value or bound above the threshold remains held. No rounded tax is inverted into a partial wage/tip allocation.
- Missing/nonfinite amounts, contradictory bases/taxes, signed historical rows, unknown external wages, or a bound **above** either configured threshold keep the existing hold. Equality is eligible; $0.01 above is not. Same-company classification predecessor chains are included and fingerprinted; unsupported successor-company import mappings remain held. Imported raw checks without finalized FICA wage/tip source support remain held; gross alone cannot establish their FICA bases. Unmapped company import rows also prevent completeness. Applied bridge balances require complete, consistent wage/tip amounts and corroborating stored SS/Medicare taxes.
- Eligible checks use full current SS wage/tip bases, uncapped current Medicare wages and zero Additional Medicare. Rates, SS base and Additional Medicare threshold come from verified year rules. [IRS Publication 15 (2026)](https://www.irs.gov/publications/p15) specifies the 2026 $184,500 SS base, 6.2% SS each, 1.45% Medicare each and employee-only 0.9% Additional Medicare above $200,000.

The versioned snapshot binds the complete enumerated candidate/period/void/disposition and bridge source digests, source-review record, current wage/tip split, conservative bounds and verified rule/source digest. Approval, client-review checksums and commit recompute it. A changed source, exclusion, amount, completeness review or rule requires recalculation. Approval/commit use the existing Company → PayPeriod locks and shared rule locks. Contractors never enter this path.

Inventory remains read-only. Its employee-year `calculable_below_thresholds` status and conservative history bounds describe capacity **before adding the next check**; they do not clear a paycheck of arbitrary size. Rows with unresolved history remain visible, including employee-years with only excluded candidates. `recover --apply` never creates old basis proofs for this status. Accounting and filing review must proceed separately.

Deployment adds one small, reversible table with no financial backfill. Existing calculations and tax data are untouched. Deploy the migration before calculation code; gather source-completeness reviews and recalculate affected unfinished runs. Historical holds without the required evidence remain held.
