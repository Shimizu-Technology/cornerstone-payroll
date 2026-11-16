# MoSa import: separate files, re-import safeguards, reactivate from review — November 17, 2026

Scope: agent-executed affected-flow QA for the stacked PRs
`feat/mosa-import-separate-sources` (B3) and `feat/mosa-import-reactivate-and-warnings` (B7a),
based on `origin/main` `1ad7656a`. Browser QA ran on the B7a head, which contains B3.
No production access, merge or deployment.

Sources: the Nov 16 run #132 findings in the task brief, `ImportModal.tsx`,
`payroll_imports_controller.rb`, `PayrollIntake::PreviewService` and the MoSa adapter.

## Environment

Synthetic fixture only, in the disposable database `cp_qa_b3_import` (Rails test env on
127.0.0.1:3197, Vite on 127.0.0.1:5197, local auth bypass, local file storage). One company
with `mosa_revel` and default settings (both files required); workers Avery, Casey, Mo Owner
(variable salary), and Blake and Dana (inactive). Two draft pay periods. Revel PDFs came from
`build_revel_pdf` and workbooks from `MosaSupplementalTemplate`. Desktop 1280×800 and mobile
390×844 in the T3 preview browser (Chromium; viewport resize, not a phone).

## Cases

| # | Viewport | Steps and expected saved result | Result |
| --- | --- | --- | --- |
| 1 | Desktop | Upload the Revel PDF alone. Checklist shows the workbook missing, with "No tips or loans this period". Needs your action (3); Apply off with the reason. | passed |
| 2 | Desktop | Save Mo's pay in the review. No "Replace existing hours…" prompt appears. | passed |
| 3 | Desktop | Reactivate Blake from the review. Dialog date defaults to 11/02/2026 (period start); row re-matches as version 2 and shows "Blake Returning is active again and is now matched in this import." | passed |
| 4 | Desktop | Add the workbook from the checklist. Version 3, 2 of 2 files, outcomes kept, Mo's pay kept, one notice under For your information. Apply. | passed; DB: 4 items, Blake 12 h, Mo $4,500, revisions 1–3 with automatic reasons, audit rows for preview, reactivate, rematch, apply |
| 5 | Desktop | Change Avery's saved hours to 36 (model save, since the calculated worksheet is locked), then upload a corrected PDF. A reason is required; the workbook is kept; the review lists "Avery Example: 36 → 41 regular" and Apply stays off until confirmed. | passed; DB: Avery 41 h, `replaced_hand_edited_hours` recorded, workbook carried with its fingerprint |
| 6 | Mobile | Upload the workbook alone, then add the PDF from the checklist. No horizontal overflow; the PDF has no waiver. | passed |
| 7 | Mobile | As an accountant, reopen the review. Dana's row says "A manager or admin can reactivate Dana Comeback." with Open profile and no button. | passed |
| 8 | Mobile | As an admin, reactivate Dana (date 10/19/2026), save Mo's pay, apply. | passed; DB: Dana active and 20 h, Mo $3,800 |

Required browser cases: 8 passed, 0 failed, 0 blocked, 0 not run. Found and fixed during QA:
an applied package's upload heading still said "currently in review".

Not covered here: a real phone and keyboard, and the client-portal source path in the browser
(covered by request and component tests). Items imported before this change carry no
imported-hours snapshot, so their hand edits are flagged only after one more import.

## Automated checks

- RSpec, targeted: 474 examples, 0 failures (imports, portal imports, intake imports,
  employees, intake and import services, submissions, status transitions, workspace copies).
- Vitest: 58 files, 458 tests passed across import, employees, payroll submissions, pay runs and lib.
- ESLint, `tsc --noEmit`, `tsc -b`: passed. RuboCop on changed files: no offenses. Brakeman: no warnings.
- Impeccable 4.6.0 on the changed UI files: `[]`.

## Resources

The preview tab was closed and the Rails and Vite processes were stopped through
`dev-lifecycle`. Both disposable databases are dropped before handback.
