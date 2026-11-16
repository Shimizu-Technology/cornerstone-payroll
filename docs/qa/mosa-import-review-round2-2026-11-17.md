# MoSa import: review round 2 — November 17, 2026

Scope: agent-executed affected-flow QA for the round-2 review fixes on the stacked PRs
`feat/mosa-import-separate-sources` (#472) and `feat/mosa-import-reactivate-and-warnings` (#473).
Browser QA ran on the #473 head, which contains #472. No production access, merge or deployment.

## Environment

Synthetic fixture only, in the disposable database `cp_test_b3_round2` (Rails test env on
127.0.0.1:3297, Vite on 127.0.0.1:5297, local auth bypass, local file storage under the session
scratchpad). One company with `mosa_revel` and default settings (both files required); workers
Avery and Casey, plus Blake and Dana (inactive). Four draft pay periods. Two client portal revisions
with a workbook link and no workbook file. Revel PDFs came from `build_revel_pdf`, workbooks from
`MosaSupplementalTemplate`, and the older-format workbook from the same layout as the gate0 fixture.
Desktop 1280×800 and mobile 390×844 in the T3 preview browser (Chromium; viewport resize, not a phone).

## Cases

| # | Viewport | Steps and expected saved result | Result |
| --- | --- | --- | --- |
| 1 | Desktop | Portal revision with a link: attach the downloaded workbook, open review, reactivate Blake. Version 2 keeps the workbook with the original "attached by … at …" evidence; Blake matched; apply. | passed; DB: Avery 40 h, Blake 12 h, version 2 applied with both files, the new selection's staff workbook is version 2's copy with the original attach time |
| 2 | Desktop | Pay run: upload the Revel PDF alone, then add the older MoSa workbook from the checklist. No tip choice is pre-selected, the older-workbook notice sits under "Needs your action" with "Choose how the workbook's tips were paid", and Apply is off with the reason. | **failed first**: the added workbook arrived with "not paid out" already recorded (see below). Passed after the fix. |
| 3 | Desktop | Remove the workbook from that review with a reason. The confirm button stays off until a reason is typed; version 3 holds the PDF only (the same files as superseded version 1) and "No tips or loans" is offered again. | passed; DB: reason "Removed: Tips & loans workbook. Wrong copy of the workbook" |
| 4 | Mobile | Add the older workbook again (version 4), jump from "Needs your action" to the tip question (focus lands on it), choose "Yes, already paid daily", apply. | passed; DB: tips $120/$80 reported and paid out, `tip_treatment_confirmed.source = review` |
| 5 | Mobile | Upload PDF and workbook, preview, Back. Both pickers say "already in import version 1", the button reads "Preview Import" (enabled, no reason asked) and reopens version 1. | passed |
| 6 | Mobile | Remove the workbook with a reason (version 2), tick "No tips or loans", apply. 44 px controls, no horizontal overflow. | passed; DB: Avery 38 h, Casey 20 h, staff waiver recorded |
| 7 | Mobile | Second portal revision: attach workbook, reactivate Dana (date defaults to the period start), apply. Workbook kept in version 2; no staff waiver offered. | passed; DB: Dana 20 h, selection carries the original attach time |

Required browser cases: 7 passed after one fix, 0 blocked, 0 not run.

Found and fixed during QA: `payPeriodsApi.previewImport` had a default of `false` for the tip
fallback, so passing `undefined` (a workbook added from the review) still sent "not paid out" and
the server recorded it as a choice. The default is removed and `api.test.ts` covers both cases.

Not covered here: a real phone and keyboard. The staff "No tips or loans" refusal for a
link revision, the `useOptionalAuth` capability hook, and the hand-entered-hours fallbacks are
covered by request, service and component tests rather than the browser.

## Automated checks

- RSpec, targeted (imports, intake imports, portal imports, import bridge, intake and import
  services, submissions, `pay_period_detail_read_spec`): #472 435 examples, #473 439 examples, 0 failures.
- Vitest, full `npm test`: 190 files, 1869 tests passed on #473 (previously 128 failures from
  `useAuth` outside the provider). ESLint `--max-warnings 0`, `tsc -b` and the production build passed.
- Playwright gate0 release lane, full: 45 passed on #472 and on #473, including
  "accounts for every MoSa source row" (Back → Preview Import → apply, then the blocked import).
- After merging `origin/main` at `0209afe9` (#468 and #470): #472 435 RSpec examples and #473 439,
  0 failures; full Vitest 192 files / 1879 tests on #472 and 193 files / 1887 tests on #473; gate0
  lane on the final #473 head 45 passed. One earlier run on that head failed the unrelated
  "calculates, reviews, rolls back approval…" step (Approve not shown after Calculate); it did not
  reproduce on the rerun and passes on main's CI.
- RuboCop: no offenses. Brakeman: no warnings. Impeccable 4.6.0 on the changed UI files: `[]`.

## Resources

The preview tab was closed and the Rails and Vite processes were stopped through `dev-lifecycle`.
Playwright started and stopped its own servers on 4417/4418. The disposable database is dropped
before handback.
