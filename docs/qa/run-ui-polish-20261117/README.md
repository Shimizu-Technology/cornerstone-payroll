# Pay run alignment and loading QA

Agent-executed affected-flow QA, November 17, 2026. Baseline: `30ed5ea6`. Application source tested: `799e88443b3bd6010e6d60a75a77e05b73aaa099`; the follow-up adds browser assertions, captured evidence and this report.

Cornerstone staff import client hours, enter variable owner pay and extra hours, then review, approve and commit payroll. This change preserves calculations, request bodies, server gates and audit writes. Sources: the supplied `BRIEF_COMMON.md` and `BRIEF_RUN_UI_POLISH.md`, current components, repository CI and the `main` ruleset. PR: https://github.com/Shimizu-Technology/cornerstone-payroll/pull/485.

## Environment and acceptance

The real Rails API and Vite app ran against an owned copy of `cp_demo_video_base_20261117`. Company 6 is the synthetic Hale's Grill & Bar client. Run 118 covered November 2–15, paid November 19. Both supplied synthetic source files imported 52 employees; each owner received $8,807.50 in the review. Authentication was bypassed locally and outbound integrations were disabled. No production access or deployment.

Required desktop/mobile layout and interaction coverage passed. Intermediate 768px wrapping also passed. These are browser viewport checks, not physical-device keyboard or touch tests. Import failure/retry and reduced motion additionally used the actual components in Playwright with controlled API responses.

| Case | Actions and expected outcome | Observed result and coverage |
| --- | --- | --- |
| C01: removal and add-back | Edit payroll → Remove → No/Cancel; remove a synthetic employee and add back; retain a usable entry path | Passed. Confirmation/footer buttons measure 44px high with a common desktop center; clean wrap at 390/768. No cancels confirmation and Cancel preserves saved pay. Avery was removed on desktop and added back on mobile; 40 maintenance hours were then entered and calculated successfully. |
| C02: usually paid | Save Nadine's note → Not paid this period → Undo → resolve again → reload | Passed. Missing/resolved rows checked at 1280/390; wrapping checked at 768. The note and resolution survived reload. Desktop note save and mobile undo use the existing endpoints. |
| C03: expected hours | Submit blank hours → correct to 40 → Save and calculate | Passed. Inline validation blocks the blank entry, preserves context and permits correction. Specific spinner/label, disabled controls and polite status appeared on desktop/mobile. Saved state shows `Filled: 40.0 h` after reload. |
| C04: recalculation | Recalculate the realistic run, inspect pending feedback, then verify saved completion | Passed at 390/1280. Mobile button geometry remained exactly 150.992 × 44px at the same position before/during work. Repeated final calculations retained 52 items, gross $71,726.37 and net $52,583.36. |
| C05: approval and commit | Approve → unapprove → approve → confirm commit; recover from a failed connection | Passed. Desktop/mobile busy states captured. Unapprove's menu stays open with its visible spinner until completion. A simulated interrupted approval request shows the connection-recovery message and permits retry. Real local approval/unapproval/commit transitions succeeded; reload shows Committed with matching totals. |
| C06: import | Keep reviewed content visible during Apply, block dismissal/repeated writes, recover after rejection | Passed: 3 public browser scenarios at desktop and 3 at 390px. The actual import components used controlled API responses for parsing/apply rejection and retry, owner pay and overwrite review. The real demo import succeeded during baseline setup. |

Some approval/unapproval/commit responses and the final desktop recalculation were delayed eight seconds in the QA browser to observe pending UI; requests still reached the local API. The connection interruption was injected before sending one approval request. These temporary browser overrides were removed before the final reload. The add-back flow retains the existing behavior documented in the supplied brief; restoring imported amounts belongs to its separate worker task.

## Before and after evidence

Names and financial entries shown are synthetic demo data. Images are unedited browser captures; import captures come from the controlled browser fixture.

| Layout | Desktop before / after | Mobile before / after |
| --- | --- | --- |
| Usually paid: missing and expected fields | [Before](before-missing-1280.png) / [After](after-missing-1280.png) | [Before](before-missing-390.png) / [After](after-missing-390.png) |
| Usually paid: resolved | [Before](before-resolved-1280.png) / [After](after-resolved-1280.png) | [Before](before-resolved-390.png) / [After](after-resolved-390.png) |
| Edit removal confirmation | [Before](before-footer-1280.png) / [After](after-footer-1280.png) | [Before](before-footer-390.png) / [After](after-footer-390.png) |
| Calculation in progress | [Before](before-recalculate-1280.png) / [After](after-recalculate-1280.png) | [Before](before-recalculate-390.png) / [After](after-recalculate-390.png) |

The baseline busy label says “Calculating…” for both initial calculation and recalculation. Its mobile capture is an initial calculation; the final captures show Recalculate itself in progress.

Additional evidence:

- [768px entries](after-missing-768.png), [768px footer](after-footer-768.png), [mobile expected-field controls](after-fields-390.png).
- Save and calculate: [desktop](after-save-calculate-1280.png), [mobile](after-save-calculate-390.png); [mobile add-back](after-add-back-390.png).
- Approve: [desktop](after-approve-1280.png), [mobile](after-approve-390.png).
- Unapprove: [desktop](after-unapprove-1280.png), [mobile](after-unapprove-390.png).
- Commit: [desktop](after-commit-1280.png), [mobile](after-commit-390.png).
- Apply Import: [desktop](after-apply-import-1280.png), [mobile with reduced motion](after-apply-import-390.png).

At 390px, `scrollWidth === innerWidth === 390`. At 768px the expected hours/note controls and their paired actions share vertical centers, and the Usually paid note group wraps together. At 1280px the name, entry action, note and resolution action share a centered row. Every input retains its complete accessible label; short placeholders identify amount/hours and optional notes visually.

## Automated verification

- `npm run lint` and `npx tsc --noEmit`: passed.
- `npx vitest run src --maxWorkers=2`: **200 files, 1,984 tests passed** on final application source. The first high-concurrency run had three unrelated five-second timeouts; the constrained full reruns passed. The added busy labels also required the commit assertion to select its dialog explicitly.
- `DEPLOYMENT_ENV=production VITE_DEPLOYMENT_ENV=production npm run build`: passed. Vite reports its existing large-chunk advisory. The first build attempt lacked the required deployment flags; rerunning with the same flags as CI passed.
- Relevant RSpec: `payroll_expected_entries_spec.rb`, `pay_period_excluded_employees_spec.rb`, `pay_periods_run_payroll_spec.rb`: **56 examples, 0 failures** in the owned test database. An early invocation began before schema loading finished and was rerun after completion. No Ruby files changed, so changed-file RuboCop and controller Brakeman do not apply. Full RSpec remains CI's responsibility.
- Final affected component/controller checks: **174 tests passed** after the footer-height and unapproval-menu fixes.
- `public-import-dialogs.spec.ts`: **6 browser scenarios passed**, 3 desktop and 3 at 390 × 844 with `reducedMotion: 'reduce'`. The busy spinner's computed `animation-name` is `spin` normally and `none` with reduced motion. A temporary config reused the public Playwright project with the mobile viewport/reduced-motion override; it was removed after execution.
- Impeccable 4.6.0 advisory, all changed UI paths: exit 0, `[]`.
- `git diff --check`: passed.

Initial CI passed the browser job. Its frontend job failed only because the existing public import test expected the removed loading paragraph; the test now checks the disabled busy button, `aria-busy` and polite status, and passes locally. A new CI run is required for the final pushed head.

## Review and lead handoff

CodeRabbit has **not completed a review**. At 08:12:43 UTC it reported that OSS review quota was exhausted, with the next included review in 48 minutes. There are no inline findings to fix or rebut. Its green “Review rate limited” check is not approval. No independent reviewer was started: the worker brief forbids subagents. The final diff was inspected locally for request changes, payroll logic changes, preserved labels, busy-state routing, dismissal/retry and layout stability.

This PR stays **unmerged and undeployed**. The lead should check the final head's required `backend`, `frontend` and `browser` results and obtain the outstanding review after capacity resets. `main` was re-fetched and remained `30ed5ea6` before handoff.

Resources cleaned: the task's QA tab, API and Vite processes, and Playwright-owned browser/server processes; both uniquely named development/test databases; the private copied `api/.env`; temporary QA config and generated dependencies/build output. Shared PostgreSQL, Redis, other sessions' servers, tabs and simulators were left alone. Lifecycle session `01a1e87b-856c-7300-9694-25904a603292` reports no active owned resources. The held branch/worktree and QA evidence remain available to the lead.
