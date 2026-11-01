# Payroll release-day data rehearsal

`release_day.rb` is the generic release runner. The previous revision was rehearsed on staging; this imported-FICA revision has been verified with local synthetic data only. The lead must repeat the staging rehearsal after merge. The script contains no staging company, actor, service, database or commit IDs. The private operational folder retains the staging-only SSH transport and earlier receipts.

## Preconditions

Run from the API directory on the intended deployed release, after migrations. Pause payroll calculation/finalization for the review window through the release owner's established process. This script does not change settings, deploy, pause workers, send messages, commit payroll, issue checks, or contact providers.

An active authorized organization administrator must have access to every selected company. Use the reviewed release-day company IDs, not an unverified copy of staging IDs. Kasperbauer Perez Insurance, Shimizu Technology, migration tests, clean-migration backups, and test workspaces are rejected. Other companies are read for the full annual aggregate inventory but never changed.

The accounting evidence must establish **zero** unimported outside/predecessor wages through the end of the selected tax year. This version deliberately requires explicit zero bounds; do not use it for a company that needs nonzero bounds. Re-review when outside wages change. A date through December 31 does not certify later changes.

## Preview, review, apply

Supply these variables in the service's normal secured runner environment. `EXPECTED_DB_HOST` is the exact database hostname only, never a connection URL. `EXPECTED_COMMIT` is the full deployed release SHA. Verify all four identity values independently. These placeholders are instructions, not production authorization for the rehearsal agent.

```sh
export EXPECTED_DEPLOYMENT_ENV='<intended environment>'
export EXPECTED_SERVICE_ID='<intended web service ID>'
export EXPECTED_DB_HOST='<exact reviewed database host>'
export EXPECTED_COMMIT='<full certified release commit>'
export COMPANY_IDS='<reviewed comma-separated company IDs>'
export ACTOR_ID='<authorized admin ID>'
export TAX_YEAR=2026 THROUGH_PAY_DATE=2026-12-31
export CONFIRM_NO_OUTSIDE_WAGES=1
export EXTERNAL_SS_WAGE_BOUND=0 EXTERNAL_MEDICARE_WAGE_BOUND=0
export REVIEW_REFERENCE='<attributable accounting confirmation and retained workpaper>'

RELEASE_MODE=preview bundle exec rails runner /secure/path/release_day.rb > release-preview.jsonl
```

Preview never inserts proofs or source reviews. It prints the full per-company aggregate before/after inventory, recovery and imported-FICA digests/counts, source-review counts, void candidate IDs, timings, and a `preview_manifest.digest`. Exit **3** means selected held employee-years remain, which is expected before remediation. Preserve and inspect the log even when the command exits 3. Exit **0** means no selected employee-years are held. Other nonzero exits are errors; stop and investigate.

Review the inventory, selected companies, recovery counts/digests, held reasons, zero-wage confirmation, and void candidates. The application validates recoverable bases against recorded taxes and exact verified-year rules; the digest locks each recovery plan. Aggregate logs intentionally omit employee identities and individual wages. Proof records retain the application-generated evidence and reviewer attribution.

Then, using the **same script bytes and variables**:

```sh
RELEASE_MODE=apply RELEASE_APPLY=1 \
  PREVIEW_DIGEST='<reviewed preview_manifest.digest>' \
  bundle exec rails runner /secure/path/release_day.rb > release-apply.jsonl
```

The script rejects a missing/mismatched preview digest before any apply. A changed selected-company annual inventory, script, actor, reference, endpoint, commit, or year requires a new preview. Each company recovery then uses its own freshly read exact `plan_digest`. Do not reuse the staging digest on production.

It executes the actual supported rake tasks in-process, capturing their detailed JSON/CSV in memory and retaining aggregate receipts:

1. Read-only full-year inventory, including excluded companies.
2. All recoverable company-years: `payroll:fica_legacy:recover[dry-run]`, then `[apply]` with actor/reference/`PLAN_DIGEST`.
3. Fresh live held employee IDs per selected company without an existing latest review covering year-end with the same zero bounds: `payroll:fica_legacy:review_sources` with `DRY_RUN=1`, then `APPLY=1` for the entire batch. IDs are never a static staging list.
4. `payroll:fica_legacy:reconcile_imports[dry-run]`, then `[apply]` with actor/reference and the exact reviewed imported plan digest. Imported plans select the before-inventory employee-years that are held or retain historical review; this includes earlier partial successes on a rerun. Selected IDs and imported plan digests are included in the outer preview manifest. The final hold check also includes these scoped imported plans. If native recovery or new source reviews change any imported plan, apply stops before imported proofs; retain prior receipts, run and review a fresh preview, then apply that digest. This intentional second pass prevents an automatically regenerated, unreviewed import plan from being applied.
5. `payroll:legacy_check_voids` and candidate IDs for the selected companies.
6. Read-only full-year after-inventory; exit 3 with exact held reasons if any selected employee-years remain held.

Apply is intentionally **not one global transaction**. Each supported task commits its own locked, validated batch. If a later batch fails, retain prior receipts, fix the cause, and run a fresh preview. Recovered proofs are idempotent; the script source-reviews held employee-years only when the latest review lacks year-end coverage or the confirmed zero bounds. This avoids duplicate attestations and permits an exact imported-plan apply on the second pass. Re-review explicitly through the supported task if the outside-wage facts change.

## Imported paycheck reconciliation

Deploy the `historical_paycheck_fica_basis_proofs` migration before using this script. Preview and apply append no changes to imported wage/tax amounts. Proofs retain the actor, reference, source digest, verified rules, conservative annual dependency digest and derived bases. They require complete source coverage, gross earnings and a recognized reported-tip split, exact saved employee taxes and every present employer SS/Medicare component. Rounded tax is never inverted; one-cent mismatches remain held. Unknown allocations, missing mappings, changed proofs, signed adjustments, or threshold exposure also remain held with a specific reason.

The ordinary calculation uses `calculable_below_thresholds`; historical and filing review remain open. Native, imported and bridge wages are deliberately counted even when overlapping. Current added wages must remain within both verified-year limits. A reviewed imported proof does not add a second financial/YTD posting or certify filings.

The November 1 read-only clone diagnosis found 65/109 active-MoSa imported checks matching both full-gross taxes exactly, with one-cent differences on 44 checks across eight of nine employees. This step must not be described as clearing all nine without separately resolving those source discrepancies. Final inventory continues to exit 3 when any selected employee-years remain held.

## Voids and remaining gates

The script **lists** candidates; it does not classify, reverse, or reissue them automatically. Confirm actual payment, saved YTD, liability and source evidence first. Never reverse paid wages to remove a warning. Record the accounting decision and resolve disputed legacy instruments through an appropriate supported path. The private rehearsal receipts retain the AIRE candidate's unresolved payment evidence; this script does not resolve that separate release gate. See [the QA record](../../docs/qa/imported-fica-reconciliation-2026-11-01.md) for this change's acceptance limits.

Zero held inventory is calculation capacity at **zero added wages**. `calculable_below_thresholds` still has history/filing review open, and an actual new check must stay within both conservative bounds. It is not filing approval or proof of arbitrary future payroll. Recalculate every affected unfinished run before approval; roll back approval first if applicable. Client approval, document, go-live, source, and other lifecycle gates remain enforced.

