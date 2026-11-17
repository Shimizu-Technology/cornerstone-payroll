# Preview statement selection QA

Scope: affected-flow QA executed by the implementation agent, November 17, 2026. Base `30ed5ea6`; isolated branch `fix/preview-stubs-not-paper-check`.

Sources: the task's `BRIEF_COMMON.md` and `BRIEF_PREVIEW_STUBS.md`, `PayrollPreviewPdf`, `PayStubsController`, `ChecksPanel`, `ClientPayrollReview`, and `ReportsController#full_print_package_pdf`. Cornerstone staff prepare payroll and share previews before commitment. Paper checks with positive net should appear once in combined previews; separate stubs default to direct deposits and statement-only activity. The run's effective payment method controls membership. All statements remain explicitly available. Printing, numbering, issuance and payment logic are outside this change.

Full Print Package contains a transmittal, payroll summary, deductions/contributions, paycheck history, retirement and installment-loan reports. It contains no individual earnings statements or checks, so its contents do not change.

Fixture: copy of synthetic `cp_demo_video_base_20261117`, company 6 Hale's Grill & Bar. Run 118 is cloned from synthetic run 117 into Nov 2–15, paid Nov 19, with a controlled mix of 9 paper checks, 42 positive-net direct deposits and 1 zero-net statement-only item. No source demo, shared or production database is changed. Cloned loan inputs are cleared for approval. This QA does not revalidate importing or calculation totals.

Required scenarios (agent executes through the real local UI):

| ID | Journey and expected result | Desktop 1280×800 | Mobile 390×844 |
| --- | --- | --- | --- |
| P1 | Download all four preview options. Combined 9 checks + 43 stubs; checks 9; stubs 43 with no positive paper-check employee; all stubs 52. Alphabetical within each part, audit part correct, no check-number allocation. | In progress | Not run |
| P2 | Committed run: default non-check download excludes positive paper checks and retains zero-net statements; all download includes all activity. Selected paper-check employee remains printable. | Not run | Not run |
| P3 | Preview error remains recoverable and retry succeeds, preserving run context. | Not run | Not run |

Automated acceptance: mixed-method service parts and per-run overrides; staff/client request filtering and audit metadata; real calculate → approve → preview → unapprove → change hours/recalculate → approve → preview with changed PDF amounts and increasing filename revision.

Limits: responsive browser dimensions, not physical mobile hardware or native printing. No checks issued, payments sent, production access, merge or deployment.
