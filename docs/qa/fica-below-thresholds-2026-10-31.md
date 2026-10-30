# Annual FICA below-threshold acceptance

Base: `staging-v2` `7c396e5b`, 2026-10-31. Agent executed, synthetic local PostgreSQL only. No staging/production access or deployment.

Cornerstone accountants calculate, review, approve and commit manual client payroll. AIRE additionally supplies connected time. The October 30 audit found 40 excluded rows causing 252 held later ledger rows: 12 of 14 Spike employees and 19 AIRE employees. Source: local `output/payroll-aire-prod-audit-2026-10-30/r2-fica-holds/REPORT.md`; app decisions: Brain-Dump `work/shimizu-tech/Cornerstone/payroll-priorities-and-aire-reconciliation-2026-09-19.md`; implementation: `EmployeeYearFicaContext`, `PayrollFicaLegacyRecovery`, financial inclusion and lifecycle gates at the base above. The production counts are audit findings, not locally reverified production state.

Required acceptance is current-check FICA independence under a complete conservative bound, persistent historical/filing review, and stale approval on changed evidence. Existing correction, financial inclusion, tax-year and contractor behavior must remain correct. This task does not accept historical cash, wages, accounting classification, connected reconciliation or filings.

Automated coverage:

1. Void+replacement and unlinked void; full current SS/Medicare, no historical proofs, open review after commit.
2. Instrument retirement retains earned wages; disposed originals remain in the conservative candidate digest.
3. Exact configured SS and Additional Medicare bounds allowed; one-cent crossings held. Opening/QB bridge overlaps and external/predecessor wages included. Unsupported/missing sources, signed corrections, tip reclassification and contradictory/nonfinite old evidence held.
4. Committed/voided/disposed/current amounts, exclusions, rules, bridges and completeness reviews changed after calculation stale approval and commit; client review also invalidates.
5. Existing October 24 near-cap signed-correction regressions and inventory/task behavior.
6. Manual-client HTTP journey calculates a synthetic Spike-like void+replacement chain, then approves and commits. Saved $500 current gross with $50 tips yields SS $31.00 each, Medicare $7.25 each, Additional Medicare $0.00 and net $461.75; both review flags stay open.

Browser journey specification (local fixture; accountant/admin): open the manual run, calculate, inspect saved paycheck and the prior-period review warning, approve, commit, reload, inspect saved SS/Medicare/net and retained warning. On a second calculated run, alter a historical source, attempt approval, confirm the recalculation message and preserved calculated state. Check the warning at desktop and mobile widths. Browser execution/evidence and full gate results will be recorded before PR handoff. Native mobile behavior is outside this backend change.

Browser execution found that the existing compliance-warning panel was hidden inside the collapsed Hours step after calculation and labelled every warning as a workweek issue. The FICA note now has its own plain-language callout above the workflow steps, with no unrelated settings link; the commit dialog continues to show the same warning.

## Round two: source-review operations and integrity

2026-10-31, branch updated onto `staging-v2` `cfe914c7` (includes #395/#396). Context and financial acceptance above remain unchanged. No production/staging access or deployment is authorized. Agent executes affected-flow checks with synthetic local fixtures.

Required scenarios: (1) callback-bypassing update/delete/truncate of source reviews is rejected; schema installer and forward migration produce the same guards, and migration down/up works; (2) actor revocation before the Company lock is observed after lock acquisition; (3) an applied employee batch records one review per employee atomically, while an invalid/out-of-company ID or unauthorized actor writes nothing; (4) default and explicit dry-run print selected employees and inventory without writing; (5) a reversed paycheck no longer generates the paycheck-specific note; (6) real `PayRunSteps` retains the FICA notice outside collapsed workflow steps at approval. The CLI/task is the operator interface for scenarios 3–4; no new browser UI is introduced. Round-one desktop payroll acceptance remains recorded above; round-two does not claim new mobile or production acceptance. Final commands/results are recorded in the round-two handoff evidence.
