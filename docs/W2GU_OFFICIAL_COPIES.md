# Official W-2GU copies

Status: Implemented (branch `feature/w2gu-official-copies`). Not yet operationally verified on paper with a real printer.

Cornerstone gives every employee of a client a W-2GU by January 31 (February 1, 2027 for tax year 2026, because January 31 is a Sunday) and keeps or sends Copy 1 for the Guam Department of Revenue and Taxation (DRT). The app fills the IRS 2026 Form W-2GU (`api/lib/assets/irs_form_w2gu_2026.pdf`, downloaded from irs.gov). The IRS says its black copies "may be downloaded, completed, printed, and used". Copy A (red, for SSA) is never produced, because W-2s are e-filed.

## What staff download

Both files come from step 8, **Print and file**, of the year-end checklist (`GET /api/v1/admin/reports/w2_gu_official_copies?year=2026&copy=employee|drt`).

| File | Layout | SSN |
| --- | --- | --- |
| Employee copies (B and C) | One sheet per employee, sorted by last name. Front: Copy B on top, Copy C below. Back: the IRS *Notice to Employee* behind Copy B and the *Instructions for Employee* continuation behind Copy C. A gray line above the form names the employee and their position ("employee 3 of 25"). | `XXX-XX-1234` |
| Copy 1 for Guam DRT | Two employees a page, by last name. An unused bottom form on the last page is blank. | Full |

### Why one sheet per employee

Each IRS page holds two copies of the same form, intended for cutting. Filling Copy B pages two employees at a time would make staff cut, sort and pair Copy B with Copy C for every person, and a mistake hands one employee another's SSN digits and wages. With one sheet per employee, staff print the file double-sided (flip on the long edge) and hand each sheet to the person named at the top. The employee cuts or folds it; the backs match the IRS layout, so the notice sits behind Copy B and the instructions behind Copy C.

![Employee sheet, front](w2gu-official-copies/employee-sheet-front.png)
![Employee sheet, back](w2gu-official-copies/employee-sheet-back.png)
![Copy 1, last page of a draft](w2gu-official-copies/copy1-drt-draft-last-page.png)

## Box data

Values come from `W2GuAggregator` rows unchanged: Box 1 (FIT wages from `W2GuTaxableWages`), Box 2 (Guam income tax withheld), Boxes 3–6, Box 7 only when there are Social Security tips, Box 12 entries in the aggregator's order (D, AA, TP, TT; at most four), the Box 13 retirement-plan check, and up to two Box 14b tipped-occupation codes. Boxes 8, 10, 11, 14a and the control number stay blank because the app does not model them. Employer name, address and EIN (never truncated) print in boxes b and c; the employee's first name and middle initial, last name and address print in boxes e and f.

## Gating and controls

- **Who files.** Copies exist only when the year's W-2 decision says Cornerstone files. Otherwise the endpoint refuses and the step shows "Not needed".
- **Draft or final.** Until the W-2s are marked ready, and again whenever the ready mark no longer matches the current inputs (`W2FilingInputsFingerprint`), every page carries a large DRAFT watermark per form and the line "DRAFT — the 2026 W-2s are not marked ready. Do not give to employees or file." The filename ends in `_DRAFT`. `W2GuOfficialCopies.final?` is the single rule for both the endpoint and the checklist.
- **Audit.** Every download writes an `AuditLog` entry (`reports#w2_gu_official_copies`, category `document_access`) before the file is sent: actor, client, tax year, document kind, whether it holds full SSNs, draft or final, the inputs fingerprint, the ready fingerprint and the employee count. If the entry can't be written, the file is not sent. No SSN appears in params, logs, audit metadata or error messages.
- **Caching.** Responses are `Cache-Control: private, no-store`.
- **Access.** The same as the W-2GU report endpoints: staff with access to the client.

## Limits

- The template is the 2026 revision only; other years are refused with a message.
- The PDF hides the unused half of each composed page with a clip. Text extraction tools can still read the hidden IRS captions, though nothing prints there.
- Box 12 holds four entries. The aggregator produces at most four (D, AA, TP, TT).
