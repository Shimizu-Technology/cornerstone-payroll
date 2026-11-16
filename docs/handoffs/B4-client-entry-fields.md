# B4: expected payroll entries

Implementation context: main at 1ad7656a, November 16–17, 2026. Staff prepare a client's regular payroll using imported hours plus configured manual entries, then calculate, approve and commit. Acceptance is an explicit resolution for every required configured entry and every missing regular before financial finalization. No production systems or customer data were used.

## Implementation decisions

Extend the existing audited PayrollStandingChange rather than introduce a second client configuration model. Its owner_pay / extra_hours kinds, employee identity, saved rate, active uniqueness, availability checks and delegated configuration permission already match this requirement. Added optional label/help text, required and allow_none flags. Round 2 supersedes the original required default: existing defaults receive required=false and allow_none=true; blank labels use the employee name and entry kind. Staff use Settings → Standing Changes to configure fields, order them, deactivate them and set the missing-regular rule.

PayrollExpectedEntries projects saved payroll facts. A positive salary_override fills owner pay; a positive hours total for the mapped saved job fills hours. Basic legacy hours count only when that employee has one active saved job matching the field. A bonus alone does not fill owner pay. Other saved job buckets survive inline hours entry. The panel uses the existing run_payroll endpoint with salary_overrides or rate-specific hours, now merging panel values into worksheet state and calculating the full roster through handleRunPayroll (round 2). Unsaved worksheet changes disable panel writes so they are not discarded by its reload.

PayrollEntryResolution records field-specific None this period or employee-specific Not paid this period, optional notes, and audited undo. Mutations lock company then period and revalidate payroll_operations access. Configuration and threshold edits lock the same company and require manage_client_configuration, including delegated accountants. Approved/committed runs cannot change resolutions.

Missing regulars defaults to positive gross pay in at least three distinct runs among the last four earlier committed regular runs. The client can change threshold/lookback (1–24 runs, threshold no greater than lookback). Voided/correction/supplemental/parallel history is excluded. Only currently active employees qualify, so employees without enough paid history and terminated/inactive workers do not warn. Configured employees and employees with current pay/hours are excluded. Resolved regulars stay visible with undo.

Approval and commit recompute all outstanding labels under the financial lock; UI approval/commit controls use the same projection. This applies to regular runs, preserving intentional off-cycle/supplemental roster selection. Historical committed records are not mutated.

## Phase 2 integration

The base already has portal standing-default rows linked by standing_change_id. Keep that identifier as the field identity: owner_pay maps to owner_pay change rows, and hours maps to extra_hours with employee_wage_rate_id. Submission revisions remain immutable evidence; PayrollSubmissions::ChangeRows validates employee/rate and PayrollSubmissions::ImportChanges applies reviewed amounts by employee. Future portal work should expose the configured label/help/required/allow_none options, retain the field link in import evidence, and translate a reviewed skipped answer into the same period resolution (with source submission/revision provenance). It must not create a second salary/hour calculator. No portal UI or submission normalization behavior was changed here.

## Validation and QA

Local automated gate: 42 passing focused model/service/request RSpec examples, including existing standing-change, submission-default, variable-salary lifecycle and concurrency coverage; frontend lint, tsc --noEmit and tsc -b; 17 passing affected Vitest tests; RuboCop on every changed Ruby file; Brakeman with zero warnings. Impeccable advisory returned [].

Agent-executed Chromium acceptance at 1280×800:
- Created two variable owner-pay fields and one hourly field through settings on a synthetic client.
- Saved owner amounts of $1,000 and $1,500 through Expected entries.
- Confirmed both approval controls were disabled and named only the missing hourly field.
- Saved 40 hours, observed all three fields filled and enabled approval, approved.
- Database verification: approved, three items, owner overrides 1000/1500 and hourly hours=40, gross=800.

Agent-executed Chromium at 390×844:
- Loaded all three settings fields, edited saved hourly help text and order, and verified persistence.
- Used a new synthetic run; saved owner amounts of $1,100 and $1,600.
- Confirmed the hourly-only approval block.
- Saved None this period with “Unpaid leave”, verified visible state/note, undid it.
- Saved 38 hours, verified all fields filled, approved.
- Database verification: approved, three items, owner overrides 1100/1600 and hours=38, gross=760. Settings help text and position=2 persisted.
- Settings and pay-run document widths matched the 390px viewport: no horizontal overflow.

Limits: mobile coverage is Chromium resizing, not Safari or physical-device keyboard testing. Missing-regular threshold/gate/resolution and multi-job preservation have automated coverage; a separate browser journey for those branches was not run. Browser acceptance preceded final validation-only additions and the fix allowing resolution replacement after an employee mapping changes; financial calculation paths were unchanged by those final edits. CI owns the full suite.

## Integration and cleanup

Lead owns merge and deployment. Do not merge/deploy from this worker. Other workers' ImportModal, preview PDF and FICA warning slices were not edited. Payroll workflow files may need normal integration conflict review.

Worktree: /Users/agent/work/worktrees/cp-b4-entries, branch feat/client-entry-fields. Task servers 5413/5414 and the owned shared-browser tab were closed and lifecycle status showed no owned resources. Shared PostgreSQL remains available. The task-only cp_test_b4_entries database is dropped after final checks. Leave the clean worktree for the lead.


## Round 2 — independent review fixes (November 17, 2026)

Continued from lead commit 6b4f4912 in the same isolated worktree; origin/main was already included. No production access, merge or deployment.

Panel saves now merge the entered value into worksheet state and invoke the existing full-roster handleRunPayroll. Staff can enter draft amounts directly; the standard calculation errors and coverage acknowledgement still apply. Calculation errors retain staged values rather than trigger a reload. This is more direct than requiring staff to calculate first just to enter a required amount. Rate-specific panel writes retain other job rows. Legacy hours without job attribution on multi-job employees disable inline hours saving with worksheet guidance, preventing data loss.

Staff/portal exclusions resolve both configured fields (including allow_none=false) and missing regulars, with their exclusion reason shown. Unavailable fields stay visible with “Needs attention in Settings” warnings in the panel and Settings, but are omitted from outstanding. Any financially reportable current item covers a missing regular, including tips, service-charge wages or bonus alone.

The migration adds required with database default false, preserving existing portal defaults as optional. The new-field Settings draft explicitly sends required=true; existing rows remain editable without conversion. Deploy note: runs already approved before deployment are checked again at commit. If outstanding entries appear, staff must unapprove, resolve the entries, then re-approve before committing. Previously committed runs remain unchanged.

Round-2 local gate: 44 focused RSpec examples; 21 Vitest tests across panel, Settings, processing actions and FICA disclosure; full frontend lint, tsc --noEmit and tsc -b; RuboCop on all five changed Ruby files; Brakeman zero warnings; Impeccable advisory []. Final tips-only spec uses reported_tips. Initial fixture slug collisions were resolved by rerunning RSpec on a clean dedicated database after browser QA.

Agent-executed Chromium affected-flow QA against these changes, synthetic local client:
- 1280×800: fresh draft with two owner fields and an hourly field. Save owner 1=1000; full-roster attempt reports missing owner 2 and leaves draft. Save owner 2=1500; approval disabled specifically for Kitchen hours.
- 390×844: save Kitchen hours=40; all expected fields filled, both approval controls enabled. Database verified owner overrides 1000/1500 and hourly hours=40 across three payroll items. No approval/commit performed in this round.
- Both sizes: exclusions show “Excluded this period” and “Client confirmed no pay”; multi-job legacy hours show worksheet guidance with Save disabled; inactive saved-job warning remains visible in panel and Settings and absent from outstanding. No horizontal overflow in panel or Settings (document widths 1280/390). New Settings draft required checkbox checked.
- Limits: Chromium CSS resizing only; Safari, physical-device input and separate missing-regular browser history setup not run. Missing-regular exclusions/tips and unavailable setup variants have automated specs. Browser fixture retries created duplicate synthetic warning rows; all were isolated in the database that is dropped below.

Cleanup: task API/frontend processes and preview tab closed; lifecycle manual-20261117-002433-45801-c28e reports no active owned resources. Dedicated cp_test_b4_entries is dropped after final verification; shared PostgreSQL stays running. Preserve this worktree and branch for lead review. Lead owns final-head independent review, CI assessment, merge and deployment.
