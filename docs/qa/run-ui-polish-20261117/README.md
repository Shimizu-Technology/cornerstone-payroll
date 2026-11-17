# Pay run alignment and loading QA

Agent-executed affected-flow QA, November 17, 2026. Baseline: `30ed5ea6`. Final implementation commit and completed results will be recorded below after the remaining checks.

The app serves Guam payroll staff importing client hours, entering variable owner pay and extra hours, and reviewing payroll before approval and commitment. This change preserves payroll calculations, source review, server gates and audit writes. Sources: the supplied `BRIEF_COMMON.md` and `BRIEF_RUN_UI_POLISH.md`, current components, repository CI and the `main` ruleset.

## Environment and acceptance

The real Rails API and Vite app run against an owned copy of `cp_demo_video_base_20261117`. Company 6 is the synthetic Hale's Grill & Bar client. Run 118 covers November 2–15, paid November 19. The provided synthetic Revel PDF and workbook imported 52 employees. Both owners received $8,807.50 in the import review. Authentication is bypassed locally; outbound integrations are disabled. No production access or deployment.

Required coverage: aligned removal confirmation; missing and resolved Usually paid rows; labelled hours/amount and note inputs; busy spinner, specific label, disabled controls, `aria-busy`, and nearby polite status for all named actions. Required widths: 390 and 1280 CSS pixels, with 768 checked for wrapping. This is browser viewport QA, not physical-device keyboard or touch testing.

| Case | Steps and expected saved outcome | Execution |
| --- | --- | --- |
| C01 | Edit payroll → Remove → No/Cancel; confirm consistent heights and wrapping; remove a synthetic employee, add back, reload | Baseline footer captured; final journey pending |
| C02 | Add Nadine's note → Not paid this period → reload → Undo; text and controls stay aligned | Desktop/mobile layouts captured, note save and undo exercised; final reload check pending |
| C03 | Blank expected hours → validation error → enter 40 → Save and calculate; saved result includes hours | Validation passed; calculation in progress |
| C04 | Recalculate a realistic run, inspect spinner/status/disabled controls and stable dimensions, then verify saved completion | Baseline desktop/mobile busy shots captured; final pending |
| C05 | Approve → unapprove/cancel confirmation → approve → commit dialog; verify specific busy feedback and saved transitions locally | Pending |
| C06 | Review and apply both source files; keep reviewed content and busy action visible until success | Baseline import completed; final loading treatment pending |

## Before and after evidence

All names and financial entries shown are synthetic demo data. Images are unedited browser captures.

| Layout | Desktop before / after | Mobile before / after |
| --- | --- | --- |
| Usually paid: missing and expected fields | [Before](before-missing-1280.png) / [After](after-missing-1280.png) | [Before](before-missing-390.png) / [After](after-missing-390.png) |
| Usually paid: resolved | [Before](before-resolved-1280.png) / [After](after-resolved-1280.png) | [Before](before-resolved-390.png) / [After](after-resolved-390.png) |
| Edit removal confirmation | [Before](before-footer-1280.png) / final pending | [Before](before-footer-390.png) / final pending |
| Calculation in progress | [Before](before-recalculate-1280.png) / final pending | [Before](before-recalculate-390.png) / final pending |

[768px wrapping](after-missing-768.png), [mobile expected-field controls](after-fields-390.png), [Save and calculate in progress](after-save-calculate-1280.png).

The post-change 390px page has no horizontal overflow (`scrollWidth === innerWidth === 390`). At 768px the expected amount/note controls and their paired actions share vertical centers and the Usually paid note group wraps together. At 1280px the name, entry action, note and resolution action share a centered row.

## Automated checks and remaining work

The initial focused run passed 90/91 tests; the commit-dialog loading assertion needed a specific status query after adding its new live region. New focused tests cover deferred operations, repeated-click prevention and retry without losing entered values. Full lint/typecheck and the full frontend suite/build are running. The first full run passed 1,979 tests and failed three unrelated 5-second timeouts plus a commit assertion that now needs to target its dialog because the header also shows the busy label. The rerun uses two workers.

Relevant backend specs run only in `cp_test_run_ui_polish_01a1e87b`. No Ruby files changed, so changed-file RuboCop and controller Brakeman do not apply. Full RSpec is left to CI. Impeccable 4.6.0 returned `[]` and exit 0 for the changed UI files.

Runtime resources remain owned until QA completes. Final cleanup and reviewer status will be added before handoff. The PR is held for the lead; do not merge or deploy.
