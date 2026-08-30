# Cornerstone Payroll documentation

This directory contains current product decisions, release gates, implementation records, and historical research. A feature is not production-ready merely because its code is merged.

## Status vocabulary

Use these terms consistently:

| Status | Meaning |
| --- | --- |
| Planned | Scope is documented but implementation has not started. |
| Implemented | Code exists on a branch and has focused test evidence. |
| Merged | Code is on `main`. |
| Deployed | The merged revision is running in the named environment. |
| Operationally verified | A dated operator test proves the workflow in that environment. |
| Filing-ready | The output passed the applicable official validation and review gate. |
| Accepted | The receiving bank, agency, or portal accepted the submission and evidence was retained. |

Tests, a merged PR, a deploy preview, or a Greptile 5/5 do not establish operational verification or agency acceptance by themselves.

## Current authority

- [Product strategy and platform boundaries](PRODUCT_STRATEGY_AND_PLATFORM_BOUNDARIES_2026-08-23.md) — product position, module ownership, packaging, and accounting decision boundary.
- [Gate 0 trust and release plan](GATE_0_TRUST_AND_RELEASE_PLAN_2026-08-23.md) — verified release blockers, PR sequence, acceptance criteria, and operational evidence.
- [Deterministic payroll release lane](DETERMINISTIC_RELEASE_LANE.md) — disposable full-stack browser fixture, deidentified PDF corpus, commands, and evidence rules.
- [Time Summary v1 contract](TIME_TRACKING_V1_CONTRACT.md) — normative Workforce/Tax-to-Payroll payload, authority boundary, reconciliation rules, and versioning policy.
- [AIRE finalized payroll batch import](AIRE_FINALIZED_BATCH_IMPORT.md) — immutable batch boundary, validation, provenance, idempotency, correction handling, and operator workflow.
- [Staff role and permission matrix](ROLE_PERMISSION_MATRIX_2026-05-14.md) — approved staff capabilities, high-impact endpoint ownership, and enforcement rules.
- [Payroll, QuickBooks, and compliance master plan](PAYROLL_QUICKBOOKS_COMPLIANCE_MASTER_PLAN_2026-07-11.md) — payroll parity and compliance roadmap after Gate 0.
- [Production readiness checklist](PRODUCTION_READINESS_CHECKLIST.md) — environment-specific evidence and release signoff.
- [Production readiness evidence: August 24, 2026](PRODUCTION_READINESS_EVIDENCE_2026-08-24.md) — current deployed remediation result: 24/26 automated controls pass; Clerk production identity, MFA, and manual operations evidence remain no-go blockers.
- [Production readiness evidence: August 23, 2026](PRODUCTION_READINESS_EVIDENCE_2026-08-23.md) — preserved initial failed audit and remediation baseline.
- [Cutover gate criteria](rollout/03-CUTOVER-GATE-CRITERIA.md) — per-client parallel-run and cutover evidence.

## Supporting implementation records

Implementation plans explain why a change was designed a certain way and what a particular PR delivered. They do not replace the current authority documents above. Notable current records include:

- [Pay schedules, salary timekeeping, and client cloning](PAY_SCHEDULE_SALARY_TIMEKEEPING_AND_CLIENT_CLONE_DESIGN_2026-08-03.md)
- [Pay schedule, timekeeping, and MoSa history implementation](PAY_SCHEDULE_TIMEKEEPING_AND_MOSA_HISTORY_IMPLEMENTATION_PLAN_2026-08-03.md)
- [Employee lifecycle and salary timekeeping](EMPLOYEE_LIFECYCLE_AND_SALARY_TIMEKEEPING_IMPLEMENTATION_2026-08-04.md)
- [QuickBooks historical import plan](QB_HISTORICAL_IMPORT_PLAN.md)

## Historical documents

The root `PRD.md`, `BUILD_PLAN.md`, `TEST_REPORT.md`, `FUTURE_IMPROVEMENTS.md`, dated feature roadmaps, and older discovery plans preserve useful history. Their completion labels and old feature descriptions are not current release evidence. When they conflict with the documents in **Current authority**, the current authority wins.

## Documentation rule

Every material implementation PR must update the relevant authority document with:

- the PR and final merge commit;
- what became code-complete;
- what still requires deployment or operator evidence;
- new risks or changed assumptions; and
- the next release gate.
