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

- [Incomplete employee entry](EMPLOYEE_INCOMPLETE_INTAKE.md) — scoped temporary intake, persistent profile gaps, payroll review and document permissions.

- [Retirement limits and evidence](RETIREMENT_LIMITS_AND_EVIDENCE.md) — supported 401(k) rules, annual evidence, staff workflow, administrator-review boundaries and rollout verification.

- [Product strategy and platform boundaries](PRODUCT_STRATEGY_AND_PLATFORM_BOUNDARIES_2026-08-23.md) — product position, module ownership, packaging, and accounting decision boundary.
- [Gate 0 trust and release plan](GATE_0_TRUST_AND_RELEASE_PLAN_2026-08-23.md) — verified release blockers, PR sequence, acceptance criteria, and operational evidence.
- [Deterministic payroll release lane](DETERMINISTIC_RELEASE_LANE.md) — disposable full-stack browser fixture, deidentified PDF corpus, commands, and evidence rules.
- [Time Summary v1 contract](TIME_TRACKING_V1_CONTRACT.md) — normative Workforce/Tax-to-Payroll payload, authority boundary, reconciliation rules, and versioning policy.
- [AIRE finalized payroll batch import](AIRE_FINALIZED_BATCH_IMPORT.md) — immutable batch boundary, validation, provenance, idempotency, correction handling, and operator workflow.
- [Cornerstone–AIRE payroll calendar sync](AIRE_PAYROLL_CALENDAR_SYNC.md) — schedule ownership, Guam T-7 cutoff policy, autonomous AIRE finalization, durable event verification, and operator-visible states.
- [Staff role and permission matrix](ROLE_PERMISSION_MATRIX_2026-05-14.md) — approved staff capabilities, high-impact endpoint ownership, and enforcement rules.
- [Payroll, QuickBooks, and compliance master plan](PAYROLL_QUICKBOOKS_COMPLIANCE_MASTER_PLAN_2026-07-11.md) — payroll parity and compliance roadmap after Gate 0.
- [Production readiness checklist](PRODUCTION_READINESS_CHECKLIST.md) — environment-specific evidence and release signoff.
- [Production readiness evidence: August 24, 2026](PRODUCTION_READINESS_EVIDENCE_2026-08-24.md) — current deployed remediation result: 24/26 automated controls pass; Clerk production identity, MFA, and manual operations evidence remain no-go blockers.
- [Production readiness evidence: August 23, 2026](PRODUCTION_READINESS_EVIDENCE_2026-08-23.md) — preserved initial failed audit and remediation baseline.
- [Payroll operator and recovery acceptance](OPERATOR_AND_RECOVERY_ACCEPTANCE.md) — named operator, identity, restore, object recovery, queue restart, monitoring, and live-cycle evidence record.
- [Cornerstone and AIRE production identity cutover](PRODUCTION_IDENTITY_CUTOVER_RUNBOOK.md) — no-lockout production Clerk, MFA, domain, user-migration, coordinated release, verification, and rollback procedure.
- [MoSa biweekly payroll cycle](runbooks/MOSA_PAYROLL_CYCLE.md) — step-by-step staff guide: two-file import, expected entries, Download preview, client review, commit and printing.
- [MoSa payroll cycle runbook](rollout/02-MOSA-CYCLE-RUNBOOK.md) — rollout controls: parallel-run, cutover evidence and hard stops.
- [Cutover gate criteria](rollout/03-CUTOVER-GATE-CRITERIA.md) — per-client parallel-run and cutover evidence.

## Supporting implementation records

Implementation plans explain why a change was designed a certain way and what a particular PR delivered. They do not replace the current authority documents above. Notable current records include:

- [W-2GU and 1099 year-end filing plan](W2GU_1099_YEAR_END_FILING_RESEARCH_2026-11-17.md) — SSA and Guam DRT filing rules, EFW2 Guam fields, ezW2 findings, gaps, build order and questions for Cornerstone (Planned).
- [Employee portal and repeatable client platform](EMPLOYEE_PORTAL_AND_PLATFORM_PLAN_2026-11-17.md) — employee self-service architecture, separate employee identity, generic intake and connected-time paths, AIRE guardrails and decisions (Planned).
- [Platform offerings implementation spec](PLATFORM_OFFERINGS_IMPLEMENTATION_SPEC_2026-11-17.md) — three offerings as client settings, operating profile, generic intake, AIRE-safe employee API, one approval queue for sensitive changes, employee identity and portal Phase 1, PR sequence (Planned).
- [HR module: ADP study and build plan](HR_MODULE_ADP_STUDY_AND_PLAN_2026-11-18.md) — read-only study of ADP Workforce Now's employee side, gaps in Payroll and AIRE, Guam market and labor rules, HR pilot scope for MoSa's, time-tracking lessons, timing, pricing, decisions and questions (Planned).
- [HR, time and payroll: the full build](WORKFORCE_PLATFORM_FULL_BUILD_PLAN_2026-11-18.md) — what doing it properly means, every module, one multi-tenant platform including time, quality bar, releases R0–R7, timing, Dafne's Nov 17–18 feedback, and the master list of open questions (Planned).
- [One product, three apps: the architecture decision](PRODUCT_ARCHITECTURE_DECISION_2026-11-19.md) — reconciles the earlier plans: time as a module of the platform ported from AIRE, HR in the platform, AIRE's path, Cornerstone profitability in the platform (Tax sends hours; pay stays in Payroll), the safety gate for employee logins, the eight milestones and how each goes live, and questions (Decided Nov 19; §0 lists Leon's decisions; §6 is the approved milestone plan).
- [Guam payroll and HR legal compliance research](GUAM_PAYROLL_HR_LEGAL_COMPLIANCE_RESEARCH_2026-11-19.md) — sourced research brief for a later law-firm review (not legal advice): pay stubs, cash-or-check, no tip credit, meal and split-shift rules, pay deadlines, Guam leave, retention, e-signatures, W-2GU filing, data security, texting, H-2B, contracts; build requirements and questions for the law firm, DOL and DRT.
- [Mark accountant feedback and recurring bonus investigation](MARK_ACCOUNTANT_FEEDBACK_AND_RECURRING_BONUS_INVESTIGATION_2026-09-02.md) — confirmed recurring-adjustment synchronization defect, redacted production evidence, deployment blocker, and prioritized implementation plan.
- [Mark accountant-feedback clarification questions](MARK_ACCOUNTANT_FEEDBACK_CLARIFICATION_QUESTIONS_2026-09-03.md) — decisions Cornerstone must confirm before loan, retirement, garnishment, approval-control, or other domain-sensitive behavior is implemented.
- [Pay schedules, salary timekeeping, and client cloning](PAY_SCHEDULE_SALARY_TIMEKEEPING_AND_CLIENT_CLONE_DESIGN_2026-08-03.md)
- [Pay schedule, timekeeping, and MoSa history implementation](PAY_SCHEDULE_TIMEKEEPING_AND_MOSA_HISTORY_IMPLEMENTATION_PLAN_2026-08-03.md)
- [Employee lifecycle and salary timekeeping](EMPLOYEE_LIFECYCLE_AND_SALARY_TIMEKEEPING_IMPLEMENTATION_2026-08-04.md)
- [Test workspaces and saved check packages](TEST_WORKSPACES_AND_SAVED_PRINT_PACKAGES_2026-09-22.md) — flexible client sandboxes, access and lifecycle boundaries, optional migration promotion, saved print artifacts, and release evidence.
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
