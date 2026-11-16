# B1 payroll preview acceptance

Date: November 16-17, 2026. Executor: implementation agent. Scope: affected-flow QA in an isolated synthetic local database. Production access, merge and deploy are excluded.

## Context and intended behavior

Cornerstone staff prepare client payroll, calculate and approve it, then share checks and earnings statements for client review before committing. The preview must leave financial state, check numbers and print history unchanged; only the download audit is written. Paper checks retain their stock layout; direct-deposit and zero-net employees with statement activity receive stubs.

Sources: the worker brief; `docs/runbooks/MANUAL_PREVIEW_CHECKS_AND_STUBS.md` and the former manual script at base `1ad7656a`; `ChecksController`, `PayStubGenerator`, `CheckGenerator`, `PayPeriod.reportable_for_company`, `PayrollReview::RevisionService` and `PayRunWorkspace`. The existing Brain Dump Cornerstone workflow notes also describe the review-before-processing journey and the need to retain change history. Repository and base were verified as `Shimizu-Technology/cornerstone-payroll`, `origin/main` at `1ad7656a`. Render and Netlify production delivery are outside this worker's scope.

The interface extends the existing operational styling and download menu. It keeps feedback still and immediate: preparing, downloaded revision, stale revision or a retryable error. Required dimensions are desktop 1280px and mobile 390px; no physical printer, ACH or real customer records are involved.

## Required scenarios

| ID | Journey and expected result | Desktop | Mobile |
| --- | --- | --- | --- |
| B1-01 | Approved run -> Checks -> combined preview; checks first, all eligible stubs, readable PREVIEW on every PDF page; saved run, items, next check number and print events unchanged, one audit | Passed | Passed |
| B1-02 | Checks-only and stubs-only menu choices produce the selected documents, including direct deposit and zero-net statement | Passed | Passed |
| B1-03 | Header action beside Commit downloads a preview and preserves run context | Passed | Passed |
| B1-04 | A newer review revision shows the previous downloaded revision; a fresh download clears the warning and survives reload | Passed | Passed |
| B1-05 | Failed download shows a recoverable error; keyboard menu/Escape and narrow layout remain usable | Passed | Passed |

Automated acceptance additionally covers draft/calculated/approved/committed/voided status, all staff roles and client/company denial, audit-only SQL writes, no available checks, legacy check reference suppression, multipage watermarks, footer replacement, live approved and committed YTD equivalence, and test-workspace non-duplication. These checks do not substitute for the browser scenarios.

## Execution evidence

- T3 browser, local Rails test environment on port 48170 and Vite on 48171; 1280×800 and 390×844. Synthetic accountant, company `Preview Demo`, approved run 444, three employees. Saved gross $350.00, deductions $72.95 and net $277.05. No real customer data or payment transport.
- Downloaded each menu choice at both widths. Combined PDF: four Letter pages (612×792 points), one paper-check page first, then three stubs. Checks-only: one page. Stubs-only: three pages, including direct deposit and a zero-net earnings statement. Opened downloaded assets with PDF tooling and inspected rendered pages; diagonal watermark, banner and replacement footer were visible, without VOID or NOT FINAL wording. Paper-check positions and dimensions retain the final generator layout. The paper employee's check stub and pay stub both show $600.00 YTD gross, $37.20 Social Security and $8.70 Medicare.
- Independent database fingerprints stayed identical across preview-download windows. The final fixture remained Approved, with zero assigned check numbers, zero check events and next check number 5000. Thirteen successful UI downloads produced thirteen audit entries with the actor, part and revision. Separate request instrumentation asserts that the only SQL write is the audit insert, including no user-activity update.
- Mobile keyboard checks: ArrowDown moved between the three menu choices; Home/Enter downloaded the combined PDF; Escape closed the menu and restored trigger focus. Menu choices stayed inside the viewport, document width stayed at 390px, and preview buttons measured 44px high.
- Revision-state QA used synthetic review-package replacements (3→4→5), rather than a real recalculation. On mobile, both the header and card identified the previous revision; downloading a fresh preview cleared the warning in both. This exposed and fixed a header issue that squeezed Commit. Retest: Commit measured 130×44px, with no horizontal page overflow. Desktop stale-state browser testing was not repeated; card state is covered by Vitest. Desktop current-state and all download choices passed after the layout fix.
- Final successful UI screenshots and PDFs are retained locally under `/tmp/b1-qa/`: `desktop-success.png`, `mobile-stale-fixed.png`, `final-desktop-combined.pdf`, `final-desktop-checks.pdf`, `final-desktop-stubs.pdf`, and `mobile-combined.pdf`. `saved-outcomes.json` and `final-fingerprint.txt` retain the synthetic database observations. These are local evidence, not production artifacts.

## Engineering gate

- Frontend lint and TypeScript: passed.
- Vitest: 163 examples passed across `PayrollPreviewCard`, `PayRunWorkspace`, `PayRunProcessingActions`, `PayRunRecordHeader` and `PayPeriodDetail.refresh`.
- Advisory Impeccable 4.6.0 scan: no findings (`[]`).
- RuboCop on all ten changed/new Ruby files: passed. Brakeman: zero errors and zero security warnings.
- Backend final result: 386 examples passed, zero failures. Subset includes the new preview request/generator specs, existing check/pay-stub generator specs, check requests, staff/client pay-stub requests and pay-period requests. Full RSpec is delegated to CI by the worker brief.

## Decisions and limits

The manual script was removed because the built-in action covers its output and records download evidence. This also removes its generator monkeypatch and temporary server PDF copies. Calculated legacy runs without a review package use revision 0; the preview never creates or changes a review package. Printer-stock output was inspected as PDF, without a physical printer. Browser failure/retry was not exercised; request specs cover failed audit persistence and Vitest covers errors/retry. Production, merge and deploy were not accessed.

## Resource disposition

The owned Rails and Vite processes were stopped and the owned T3 preview tab closed. Lifecycle session `01a1e4a1-d7f9-7e50-8049-b3f63356da94` reported no active owned resources. The isolated `cp_test_b1_preview` database was dropped after the final backend run; its absence was verified. Shared PostgreSQL/Redis and baseline simulators/services were left unchanged.
