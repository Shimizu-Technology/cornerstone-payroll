# PR 2: Standing changes

## Scope and baseline

Agent-executed implementation and affected-flow QA for Cornerstone staff and client payroll submissions. Verified clean isolated worktree `t3/standing-change-defaults` at `de4b62ca0abf23199371bbf1b0cb3e0719f605d3`, equal to `origin/main`, on November 14, 2026. No production writes, email, deployment or merge are authorized.

Sources: `portal-mosa-plan-20261114.md` (PR 2, decisions 3 and 8), `mosa-walkthrough-feedback-20261114.md`, `docs/qa/pr1-mosa-files.md`, and the submission/import/settings code at that baseline. Private source documents and production-copy evidence stay outside Git.

MoSa's client sends Revel hours, a tips/loans workbook, and period changes. Staff must review these before payroll. The two owners use variable salary; their amounts are per person. Addison is hourly, absent from Revel, and his workbook loan must still be collected. The current importer preserves workbook-only worksheet hours and requires separate owner period pay. This work makes those inputs visible for review from immutable submitted changes.

Experience follows the surrounding operational UI: default rows first, explicit skips, blank numeric inputs, previous locked payroll as a hint, no new motion. Staff settings use selected-client capability and workspace write checks. Import confirmation stays beside editable figures. Legacy total/each rows remain readable and are never split by inference.

## Required scenarios

| ID | Starting state and actions | Expected saved outcome | Status |
| --- | --- | --- | --- |
| S1 | Staff with configuration rights sets two owner defaults and one saved-job hours default; client/operator without rights tries settings | Company-scoped defaults audited; unauthorized writes refused | passed: both browser widths; API permission tests |
| S2 | Client at 1440 and 390 sees defaults and previous-period hints; fills rows, skips one, adds a row, sends | Blank amounts initially; immutable revision retains filled and skipped rows; list changes/No changes enforced | passed at both widths; later receipt-count test awaits final run |
| S3 | Staff opens portal review, edits one proposed value, confirms, applies | Owner salary override and exact job/rate hours persisted; workbook tips/loans retained | passed at both widths on synthetic sources; real workbook reconciliation blocked |
| S4 | Staff opens pay-run Import MoSa with a pending revision and links it | Same proposals and persisted values; pending-source gate clears only after success | desktop passed; phone prefill passed, apply blocked by load |
| S5 | Old total/each revision; employee inactive/terminated; job deleted/changed; review superseded | Legacy display preserved; clear refusals; no guessing or stale writes | API/service checks passed; desktop legacy display passed; phone legacy not_run |
| R1 | Fresh verified Neon branch, practice copy through Oct 5–18; Oct 19–Nov 1 paid Nov 5, real files; owners 8421.13 each, Addison 68 hours, two direct-deposit notes | Apply without retyping numbers; calculate matches period 117 except known Billy +0.01; Addison loan 219.70 | blocked by machine load; branch preparation only, no financial rehearsal result claimed |
| R2 | Fingerprint company 6 before/after rehearsal; stop runtimes and delete verified task branch | Zero company-6 changes; branch absent; no owned running resources | not_run |

Every browser scenario requires 1440 and 390 widths and visible plus persisted outcome verification. Native device/Safari coverage is excluded. Required scenarios remain gates until passed. Full suites are left to CI. Before each heavy step, check `uptime`; when 1-minute load exceeds approximately 25, continue lighter work and defer the step.

## Design

`PayrollStandingChange` stores company, employee, kind, optional employee wage rate, order and active flag. No recurring amount is stored. Saves emit audit history; deactivation preserves references. A revision stores the default identity, explicit skip or number, and saved job/rate snapshot. Existing revisions are not rewritten when configuration changes.

`PayrollSubmissions::ImportChanges` projects submitted owner amounts and extra hours for both import entry points. Apply requires explicit confirmation and the complete reviewed change list. It validates live employee eligibility and the saved rate against the submitted snapshot. Owner pay reaches existing `salary_override` and per-person period-pay evidence. Extra hours add to Revel hours (or existing workbook-only worksheet hours) and reach `wage_rate_hours`; workbook tips/loans keep their existing path. Existing source-package/current-revision guards and payroll-item `expected_import_id` guard remain in place.

## Evidence and limits

Implementation and verification in progress. Initial machine load: 63.39, then 88.32. No heavy checks or servers have been started.

## Resource ownership

Lifecycle session `01a1d9da-7b35-73d0-b267-93b56bf5cb87`; baseline audited. All baseline Postgres/Redis, browser/device surfaces and other listeners are borrowed. No runtime handoff authorized.

## Verification checkpoint (November 14, 22:23 Guam)

Code is implemented in this working tree. Targeted runs passed: standing-change model 5 examples; standing-change normalization/hints 4; import-change projection 5; settings requests 4 (in the combined batch); portal import requests 68; submission requests 37; remaining submission/import/wage-choice/tenancy/settings batch 52; import service 29. These overlap and are not a unique-example total. TypeScript and frontend lint passed. Affected Vitest passed 45 tests across 6 files with one worker; the later client-only employee-count regression still needs its retest. Brakeman reported zero errors and warnings. Full RuboCop initially found two blank lines in request specs; those were corrected and its final rerun remains pending.

The initial frontend dependency copy lacked dev packages; its TypeScript/module errors and Vitest startup failures were resolved with a fresh `npm ci --ignore-scripts`. A genuine type incompatibility for optional saved-job IDs was fixed by filtering unsaved rates. The final TypeScript and affected tests above ran against the complete local install.

Synthetic browser evidence uses isolated database `cornerstone_pr2_ui_01a1d9da`, sanitized test-mode Rails with an outbound TCP guard, E2E identities and local retained storage. Settings, client defaults/hints, explicit skip plus additional owner row, staff edit/confirmation and portal apply passed at 1440×900 and 390×900. Persisted values in both runs: first owner 1100.01 (staff edit from submitted 1100), second owner 1200.00 from the added row, worker 68 hours allocated to the saved $35 maintenance job. Original revision evidence retains the skip and submitted amounts. Phone settings/form/review have no horizontal document overflow at 390 CSS pixels. The desktop pay-run linked-revision route also passed with owners 1300/1400 and worker32, without retyping any review number. Mobile linked-route and mobile legacy display remain pending. Legacy total/each display passed at desktop width.

The first synthetic apply correctly failed with no partial rows because prior committed fixture paychecks lacked verified FICA bases. Those synthetic historical checks were recalculated to establish valid evidence; apply then succeeded with unchanged payroll guards. An initial partial-label locator and a `button` selector for a summary control caused automation timeouts; fresh snapshots and exact visible selectors resumed the same journeys. The client-only employee count was corrected from 3 to 4 after the browser exposed it.

Private evidence is under `output/pr2-standing-changes-20261114/` (logs, saved-input TSVs and forthcoming screenshot copies). No real client files are committed. Current lifecycle-owned resources: Rails PID76254/3658, Vite PID76735/5658, proxy PID77860/5660, preview tab `tab_2i_e60e53fc-08fc-48e4-b927-3d2799347d0a`. All were claimed immediately. Cleanup is pending while QA continues; no runtime handoff is intended.

Fresh Neon rehearsal branch created: `pr2-standing-changes-20261114` / `br-dawn-shadow-a1j8o2gc`, parent `br-bitter-unit-a1dagbos`, endpoint `ep-steep-paper-a1ry673f`. Every database client launch uses the live endpoint/branch verification wrapper. Company6 fingerprint captured before schema migration. The migration passed on this fresh copy (parent schema version20261114090000). A dedicated rehearsal actor is created in company1. No browser/client payroll actions or practice-copy creation have run there yet. The branch must be deleted after the final fingerprint comparison.

Load varied from 63–153 during initial work, briefly fell below25 for checks and startup, and rose to53 after the phone portal case. Heavy steps pause again while lighter work continues.

### Correction and compatibility follow-up

The final import path records the baseline and resulting hours/allocations of a client-only contribution. A corrected-source reimport replaces that earlier contribution; changed worksheet hours or allocations require reconciliation. The five original standing-review cases plus the new reimport/manual-edit case passed as six request examples. Legacy total/each and jobless extra-hours instructions are shown as explicit manual-review warnings and remain on the existing guarded worksheet/period-pay path. No split or job is inferred. The projection service's six examples passed, including legacy compatibility. ImportModal's employee-count follow-up passed 16 examples before the later saved-worksheet confirmation test was added.

The portal import service was restarted after the first reimport correction: PID76254 was cleaned and replaced by claimed PID6557. A redundant startup attempt exited on the already-owned port; no other process was stopped. The lifecycle ledger contains the current ownership.

The phone linked-route client send and file preview are complete; selecting the pending revision displayed 1300/1400 and32 hours. Apply is paused because load rose above25. The phone legacy case is also pending. Recent small additions still require final frontend checks: failed-settings-load recovery, separate skipped-row counts in receipts, manual-review warnings and saved worksheet/overwrite confirmation for an employee absent from both files.

## Draft PR handoff and remaining gates

**Not ready for merge.** Machine load ultimately exceeded240. Heavy checks and remaining browser/rehearsal steps were stopped under Leon's explicit load limit. Required phone linked apply, phone legacy display, final source frontend/static reruns, and the production-copy financial rehearsal remain gates. Full backend/frontend suites belong to CI. No merge or deployment was attempted.

The final staged API/web source diff before this ledger update has SHA-256 `a4b3e0ea6e85d8fed54a063b31c968ddd13e554eeac06615508db67f024efd76`. Earlier passing tests and browser cases are recorded above with their follow-up changes; they are not a claim that every final-source case passed. Final focused model run passed all5 examples, including destruction audit. Final standing-review request run passed all6 cases, including corrected reimport and legacy manual pay. The touched Ruby scan covered30 files and corrected its remaining blank-line offense. The newest frontend tests are committed for CI and the lead's local rerun; no final complete local frontend run is claimed.

The isolated Neon copy was migrated successfully and a dedicated company1 rehearsal actor was created. No practice workspace or real-file submission/import/calculation was executed. Company6 fingerprint comparison covers9,548 records: **zero added, zero removed, zero changed**. This proves copy integrity during preparation only; it does not establish payroll reconciliation. Private `fingerprint-diff.json` retains the comparison. The task branch is deleted and its absence verified in private `neon-cleanup.json` (see final cleanup note).

Lifecycle cleanup closed/released the owned preview tab and stopped Vite76735, proxy77860 and replacement API6557. Earlier API76254 was also cleaned. Status reports **no active owned resources**. No runtime handoff; borrowed/protected services and all other sessions were left alone. The isolated source worktree, synthetic databases and private evidence are retained for continuation.

Continue after verifying load below approximately25: rerun final targeted backend and frontend gates; finish the two phone cases; create a **fresh** verified Neon branch from the specified parent and execute R1 fully with the real files and protected outbound environment; compare the required financial fields and loan; fingerprint and delete that branch. The private `remaining-checks.md`, scripts and synthetic fixture JSON retain exact inputs and method. Recheck all endpoint and worktree facts rather than trusting saved identifiers from this run.

## Acceptance continuation — November 14, 2026

Resumed in the existing held worktree at `e4ed47d834a9693a93dffd16f0c50a0310cf5a02`. Tracked files were clean; the pre-existing untracked `.codex/` handoff was preserved. The PR targets `main` and remains draft, held, unmerged and undeployed. The original product brief and required scenarios above still apply. Current lifecycle session: `01a1da30-cbe8-7630-bdfd-ce4280f0701c`.

CodeRabbit's three material findings were verified and fixed: a workbook-only row restores its previous hours baseline when a corrected change is removed, refusing removal after a worksheet edit; selecting or deselecting a pending revision resets overwrite confirmation; migration rollback refuses before changing tables, constraints or immutable skipped-revision evidence. Added regressions also exercise a real foreign-company default and successful settings edit/deactivation.

**Supported rollback:** roll back application code only and retain the expanded constraint and standing-change tables. Do not run this migration down or rewrite existing submitted rows, fingerprints or defaults to satisfy the former constraint. Any future schema contraction requires a separately reviewed evidence-preserving migration. A populated skipped revision test verifies that the explicit irreversible-migration refusal leaves the revision and its fingerprints, active default and constraint intact.

Final-source local checks for these changes: `npm ci` passed (297 packages, zero reported vulnerabilities); targeted backend batch passed **290 examples, zero failures**; full RuboCop passed **1,844 files, no offenses**; Brakeman reported **zero errors and warnings**; frontend lint and `tsc -b` passed; all six affected Vitest files passed **54 tests** with `--maxWorkers=2`; Impeccable 4.6.0 advisory scan returned `[]`. The affected files include StandingChangesSettings, PayrollPeriodPage, SubmissionForm and all three ImportModal test files. An initial regression expected a job allocation for a single-rate baseline that originally had none; its assertion was corrected to verify the original empty allocation and restored two hours. The combined batch was rerun afterward and passed. No product assertion was weakened.

Phone linked-import apply now passed at 390×900 without typing review numbers. Independently saved rows show owner amounts 1300/1400, 32 hours on the saved $35 job, and an applied `pay_run` submission link. Legacy each-owner display was rechecked at 390 and 1440; the saved original row remains unchanged and neither width has horizontal document overflow. These are responsive browser checks, not native-device or Safari coverage.

Private continuation logs use `acceptance-*` under the existing private evidence root. A fresh production-copy branch and the full ASUS run are in progress; neither is passed by this checkpoint. The new rehearsal evidence is under `acceptance-20261114T1322/`. Old deleted endpoint verification and substitution of old saved URLs into the fresh verifier both refused before any database connection.
