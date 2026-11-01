# Imported paycheck FICA reconciliation — November 1, 2026

Implementation base: `staging-v2` at `d7170343`. Merge owner: Claude; this PR must remain unmerged by the implementation agent.

## Context and acceptance

Cornerstone accountants run manual client payroll; Mark processes active MoSa's hourly restaurant payroll biweekly. Locked QuickBooks history retains earnings, tips, deductions, recorded taxes and employee mapping. Native annual FICA accounting uses committed payroll items and applied opening balances, not raw archive rows. When disputed native history prevents the annual path, the below-threshold path requires independent source completeness and corroborated historical amounts. Its unconditional imported-paycheck guard caused the nine observed holds. Native `recover` operates on payroll items and cannot attest raw historical paychecks; a zero outside-wage review proves neither their bases nor their stored taxes.

Sources: existing `docs/FICA_LEGACY_RECOVERY.md`, PR #397, the private release-day `REHEARSAL.md`, `INVENTORY.json`, residual diagnostics/logs and `r2-fica-holds/REPORT.md` under `output/payroll-aire-prod-audit-2026-10-30`; client context in Brain-Dump `work/shimizu-tech/Cornerstone/payroll-priorities-and-aire-reconciliation-2026-09-19.md`. No current production state is inferred from those notes.

Required acceptance: a reviewed company-year/employee selection produces a deterministic read-only plan; only full-gross/tip tax corroboration (each present component within $0.01 per check, signed residuals recorded; round 2) plus complete conservative annual bounds can create append-only proofs; authorized apply rejects drift and preserves financial rows; ordinary held calculations then approve/commit through the bounded path with review open. Contradictory or ambiguous sources must remain held. The release runner must bind imported plans and fail loudly on drift or remaining scoped holds.

## Read-only staging diagnosis

The staging-only SSH transport asserted service `srv-dbemoodg1s2s7383eea0`, DB endpoint `ep-summer-bird-a13f6coa` and deployed `d7170343`. Every diagnostic entered `REPEATABLE READ`, set `TRANSACTION READ ONLY`, asserted it, and rolled back. No staging application data was written; no production access occurred. Results contain aggregate counts and component labels only.

- Nine held active hourly employee-years; 109 mapped locked imported checks. The company has 855 imported checks and no unmapped checks in the inherited rehearsal evidence.
- All 109 earnings-detail sums equal gross. SS matches full-gross component rounding on 86 checks, Medicare on 83; both match on 65. All differences are one cent: 44 checks across eight employees differ on one or both taxes. Employer SS/Medicare mirror the same mismatches.
- Alternative diagnostic candidates did not resolve them: adjusted gross matched both taxes on 53 checks; separately rounded wage/tip components on 48; explicitly derived FICA-eligible gross on 65. These are diagnostic comparisons, not accepted alternate allocation rules.
- Executing the proposed strict derivation/bound rule in memory, with source reviews already present, found one employee-year with capacity and five proposable proofs; eight remain held. No calculation, approval or proof application was performed on staging. Real next-check amounts still require the lead's post-merge rehearsal.

Private aggregate logs: `release-day/import-fica-shape.log`, `import-fica-corroboration.log`, `import-fica-new-rule-preview.log`. Diagnostics and local gate evidence are retained in `output/payroll-imported-fica-20261101`.

Round 1 outcome: the exact rule could not clear all nine from the available source rows.

### Round 2: approved one-cent per-check tolerance

The lead approved a tolerance of at most $0.01 per tax component per check. QuickBooks rounds each check on its own, so a one-cent per-check difference is rounding, not a wage discrepancy. Bases still come only from the imported wage/tip amounts; taxes only corroborate. Anything beyond one cent on any component stays held with the component and signed difference named. Signed residual cents are recorded per check in plan rows and proof evidence (`version` 2), with per-employee-year and company totals inside the plan digest.

Read-only re-run (`output/payroll-imported-fica-20261101/r2-tolerance/tolerance_preview.rb`, embedding the round-2 branch sources; same staging transport assertions on service `srv-dbemoodg1s2s7383eea0`, endpoint `ep-summer-bird-a13f6coa`, deployed `d7170343`; `REPEATABLE READ`, `READ ONLY` asserted, rolled back). It ran the actual `ImportedPaycheckFicaReconciliation#inventory` for the nine source-reviewed employees. The only changes were shims that treat every import as unproven, because staging has no proof table yet. Aggregate result:

- 9 source-reviewed employees, covering all 9 native-held employee-years. 109 imported checks: **109 recoverable, 0 held**.
- 65 exact checks; 44 with residuals. The maximum absolute residual is 1 cent. Per component, the residual histogram is SS −1:11 / 0:86 / +1:12 and Medicare −1:11 / 0:83 / +1:15, with employer mirroring employee.
- Company residual totals: employee SS +1¢, employee Medicare +4¢, employer SS +1¢, employer Medicare +4¢.
- **Employee-years: 9 ready, 0 held**; 109 proposable proofs at zero added wages.

No proof, review, calculation or approval was written on staging. Real next-check amounts and the release runner still need the lead's post-merge staging rehearsal.

## Affected-flow QA

Agent-executed backend/CLI QA uses synthetic fixtures only, localhost PostgreSQL and the actual task, calculator and lifecycle services. Browser/mobile/provider/payment QA is not run: no frontend or interaction code changes, no checks issued, and no provider contacted.

| Scenario | Expected saved outcome | Result |
| --- | --- | --- |
| Exact imported checks, with/without PayTip | Proposed wage/tip bases, attributed proof, unchanged imported amounts; calculate → approve → commit with review open | Passed |
| ±$0.01 on each of employee SS, employee Medicare, employer SS, employer Medicare (round 2) | Recoverable; signed residual in plan row, employee-year/company totals and proof evidence; bases from gross/tips; amounts unchanged; calculates | Passed |
| $0.02 on each component; non-whole-cent employer detail (round 2) | Held; reason names component and signed difference; no proof; calculation held | Passed |
| Mixed exact/±1¢ checks plus one 2¢ check (round 2) | Totals match and are digest-covered; changed residual changes digest; 2¢ check holds the employee-year with zero proofs | Passed |
| Missing employer detail; present employer detail | Absence retained; any present component must corroborate within $0.01 | Passed |
| Multiple earnings rates, traditional retirement, Roth and loan | Full FICA gross corroborated; deduction/imported amounts preserved | Passed |
| Expired/missing outside review; threshold/current-check exposure | No proof or calculation clearance beyond verified bound | Passed |
| Source, native-history or review identity changes | Reviewed digest rejected; changed imported source stales approval | Passed |
| Unauthorized/stale actor; foreign-company employee selection | No proof insertion | Passed |
| Repeated fresh-plan apply | No duplicate proof | Passed |
| Callback-bypassing UPDATE/DELETE/TRUNCATE | Database rejects mutation | Passed |
| Ambiguous tips, inconsistent earnings, FICA-exempt detail, Additional Medicare exposure | Held; no guessed partial allocation | Passed |
| Nine employee fixture, three imports each and later native runs | 27 imported proofs, approved later payrolls, zero holds | Passed |
| Active-MoSa-shaped fixture: nine employees, four imports each, one-cent residuals on 24 checks across eight employees (round 2) | 36 proofs, residual totals reported, later payrolls approve in `calculable_below_thresholds` with review open, zero holds, idempotent re-apply | Passed |
| Existing authoritative annual path with optional unavailable imported evidence | Existing annual behavior retained | Passed |
| Actual release runner preview/stale apply/first apply/second pass/idempotence | Stale digest rejected; new source dependencies require fresh preview; exact row proven; mismatch exits 3 | Passed (actual script, 14 preview/apply invocations across mismatch and all-exact fixtures) |

The complete backend gate passed against runtime/tests commit `0ee948e4` (later changes are documentation only): **5,728 RSpec examples, zero failures**, in 20m49s; Rubocop inspected 1,588 files with no offenses; Brakeman reported zero errors/warnings; updated bundler-audit found no vulnerabilities; PostgreSQL integrity verified. The new reconciliation suite separately passed 21 examples. The actual release-runner checks passed on a separate synthetic database: mixed data retained exit 3, while all-exact data reached exit 0 and stayed there without duplicate proofs/reviews. Migration down/up passed in 0.0038/0.0120 seconds, followed by integrity verification.

At the single hosted inspection on `a44f6c20`, backend, frontend, browser and staging-configuration jobs were in progress. CodeRabbit was rate-limited, with a 48-minute reset notice and no substantive review; one re-review request was posted. No approval or independent review is claimed. Claude owns final-head CI/review monitoring and merge. This implementation child did not watch or poll hosted PR state.

Both uniquely named localhost synthetic databases were dropped; exact-name absence was verified. Owned finite processes finished and lifecycle cleanup/status reported no active owned resources. Task-generated caches/storage and test logs were removed; QA evidence remains in the private output folder. Borrowed services, existing tabs/devices and the main checkout were left alone. The branch/worktree and private `.codex/handoffs/20261101-imported-fica-408.md` remain for Claude; no runtime resource was handed off. Frontend gate is not required locally because `web/` is unchanged. Real MoSa release acceptance remains blocked as described above.
