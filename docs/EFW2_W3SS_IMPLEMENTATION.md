# 2026 W-2GU filing files

Cornerstone staff prepare one client/year at a time. `W2GuAggregator` supplies every monetary value; the exporter formats and checks those values without recalculating wages. The practice submitter belongs to the organization. It stores the BSO identifier, never a password. Client filing contacts belong to the employer.

Authority: SSA Publication 42-007, EFW2 Tax Year 2026, Version 4 (November 12, 2026). The implementation began from Version 1 and was checked against the lead-supplied Version 4. The PDF is not committed. Version 4's employee Social Security tax maximum is $11,439.00; the wage base is $184,500. The optional signature PIN stays blank. Codes J/K/L/P are unmodeled and zero-filled; their revised valid-year rules do not affect modeled amounts.

The IRS template is the 2026 prior-year W-3SS at https://www.irs.gov/pub/irs-prior/fw3ss--2026.pdf (the live `fw3ss.pdf` served 2027 during this work). Only its black Copy 1 page is included, labeled “For your records — do not mail when you e-file.” It is a records copy, not a paper filing substitute.

## Positions relied on

All positions are one-based and inclusive. Every record is 512 ASCII bytes followed by CR/LF. Text is uppercase except email; numeric monetary fields contain cents, zero-filled and right justified. Unused reserved positions stay blank. All records have the two-character identifier at 1–2.

| Record | Fields populated |
|---|---|
| RA | EIN 3–11; BSO user ID 12–19; resubmission indicator 29 = 0; software code 36–37 = 98; company name 38–94; company location/delivery/city/state/ZIP/extension 95–116, 117–138, 139–160, 161–162, 163–167, 168–171; submitter name 217–273; submitter location/delivery/city/state/ZIP/extension 274–295, 296–317, 318–339, 340–341, 342–346, 347–350; contact name 396–422; phone 423–437; email 446–485; preparer 500 = A. Vendor, resubmission WFID, foreign address, fax, extension and remaining reserved fields blank. |
| RE | Tax year 3–6; employer EIN 8–16; terminating-business indicator 26 = 0; establishment 27–30; employer name 40–96; location/delivery/city/state/ZIP/extension 97–118, 119–140, 141–162, 163–164, 165–169, 170–173; kind 174 (N/F/S/T/Y); employment code 219 (R/A/H/M/Q/F; territorial railroad X excluded); jurisdiction 220 = G; third-party sick-pay indicator 221 = 0; employer contact name 222–248, phone 249–263, email 279–318. Agent, other EIN, foreign address, fax, phone extension and signature PIN 319–328 blank. |
| RW | SSN 3–11; first/middle/last/suffix 12–26, 27–41, 42–61, 62–65; location/delivery/city/state/ZIP/extension 66–87, 88–109, 110–131, 132–133, 134–138, 139–142; federal wages/tax 188–198, 199–209 = zero; SS wages/tax 210–220, 221–231; Medicare wages/tax 232–242, 243–253; SS tips 254–264; D 287–297; AA 441–451; statutory 486, retirement 488, sick pay 489; primary/secondary tipped occupation 490–492, 493–495. |
| RO | TA 221–231; TP 232–242; TT 243–253; Guam wages 363–373; Guam income tax 374–384. One RO per employee. |
| RT | RW count 3–9; zero federal wages/tax 10–24, 25–39; SS wages/tax 40–54, 55–69; Medicare wages/tax 70–84, 85–99; SS tips 100–114; D 145–159; AA 370–384. |
| RU | RO count 3–9; TA 295–309; TP 310–324; TT 325–339; Guam wages/tax 460–474, 475–489. |
| RF | File RW count 8–16. |

Other money fields are zero-filled, even when unmodeled. Each start position below has width 11 for RW/RO or 15 for RT/RU:

- RW: 276, 298, 309, 320, 331, 353, 364, 375, 386, 408, 419, 430, 452, 463, 474.
- RO: 12, 23, 34, 45, 56, 67, 78, 89, 111, 122, 133, 144, 155, 166, 177, 188, 199, 210, 275, 286, 297, 308, 319, 330, 341.
- RT: 130, 160, 175, 190, 205, 235, 250, 265, 280, 295, 310, 325, 340, 355, 385, 400.
- RU: 10, 25, 40, 55, 70, 85, 100, 115, 145, 160, 175, 190, 205, 220, 235, 250, 265, 280, 355, 370, 385, 400, 415, 430, 445.

W-3SS Box 12a follows the deferred-compensation mapping in EFW2 Appendix E: modeled codes D and AA are added (RT 145–159 + 370–384). TA/TP/TT do not belong in Box 12a.

## Download contract

`GET /api/v1/admin/reports/w2_gu_efw2?year=2026&mode=draft|final` and `w3ss_pdf` use explicit company context. EFW2 requires per-client `manage_client_administration` because it contains full SSNs; W-3SS retains W-2 report authorization. Both modes require a recorded Cornerstone W-2 decision and no filing-responsibility blockers. Draft skips only the readiness-fingerprint requirement. A final file additionally requires `W2FilingReadiness.current?` on the current fingerprint; settings, contact details, middle names and suffixes are included in that fingerprint. Draft filenames include DRAFT and the UI requires confirmation that the file is for testing. Errors return a problem list without file bytes.

Both formats use `Cache-Control: no-store`. Each successful download records actor, company, year, mode, readiness fingerprint and SHA-256 of the returned bytes. Audit metadata excludes SSNs. Test workspaces cannot export filing files. The self-check verifies record lengths/order/counts, monetary subtotals and aggregator totals before returning either format.

No SSA/GuamTax upload occurs in this change. AccuWage and GuamTax acceptance remain operator checks once their 2026 windows/accounts are available. Foreign-address exports and other tax years are rejected; future layouts need explicit implementation.


## Year-end integration after #502

Print and file holds four document rows: employee copies B/C, Copy 1 for Guam DRT, the W-2 e-file for SSA and GuamTax, and the W-3SS totals for records. The checklist supplies each endpoint and params. Filing evidence remains a separate card. Draft e-file and W-3SS downloads require an explicit test-file confirmation; finals use the current readiness fingerprint. Full-SSN downloads show their client-management restriction. EFW2 uses `W2GuAggregator.box14b_codes`, the same selection as the printed copies.

EFW2 problems carry scope, code and employee ID. Cleaned fields exceeding their record widths are rejected rather than truncated. Email checks use the vendored IANA TLD snapshot in `api/vendor/iana/`; refresh it from the official source URL in its header/provenance before a filing season if needed. The list shows its known subset of issues while EfileCheck v2 is pending and queues missing checks on the existing default queue, deduplicated by company/year/revision. See the round-3 validation report for deploy and recovery details.
