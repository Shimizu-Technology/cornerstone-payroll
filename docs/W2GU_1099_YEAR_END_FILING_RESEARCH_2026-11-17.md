# W-2GU and 1099 year-end filing: research, gaps and plan

**Status:** Planned. Nothing in this document is built yet unless it says so.
**Date:** November 17, 2026. Code references are to `main` at `162dd2ec`.
**Goal:** Cornerstone Payroll produces each client's W-2GUs, W-3SS totals, 1099-NECs and 1096 itself. It also produces the electronic files that Social Security and Guam DRT accept, so Cornerstone no longer has to buy separate year-end software.

## Summary

- Every client with W-2 employees files W-2GU wage data **twice**: once with Social Security (SSA) and once with Guam DRT. SSA does not forward W-2GU data to DRT.
- One file covers both. SSA's EFW2 text format is what SSA's Business Services Online (BSO) accepts, and DRT's GuamTax.com "E-File W-3/W-2GU" upload accepts **the same EFW2 format**.
- 1099-NEC and 1096 go to **Guam DRT, not the IRS**. GuamTax.com takes them as an IRS Publication 1220 text file.
- Due date is **Monday, February 1, 2027**, because January 31 is a Sunday. SSA states this. DRT has not posted a 2026 alert yet, so confirm its date.
- Payers with **10 or more returns** must e-file with both SSA and DRT. To be safe, count every return DRT includes (W-2GU, 1099-NEC, 1099-MISC, 1098 variants and W-2G) together. MoSa's is well over that.
- Last year Cornerstone used **ezW2 2025** (Halfpricesoft, 2-user network edition, about $139). It's a Windows desktop program activated by a license key, with no web account. Its website never mentions W-2GU or W-3SS. Before relying on last year's output, look at one of its EFW2 files to see whether it was filed as a W-2GU or as an ordinary US W-2.
- The app already prepares W-2GU numbers and a 1099-NEC summary, but it does not produce official forms or any filing file. A realistic build fits before the deadline, provided the accounts and lead-time items below start now.

Cornerstone's own Client Compliance tracker (October 2026) agrees: "W-2GU / W-3SS — Guam DRT & SSA — Jan 31: file with DRT and SSA and furnish copies to employees" and "1099-NEC / 1096 — Jan 31: file with DRT and furnish copies to payees."

## 1. What has to be filed

| Form | Filed with | How | Due (tax year 2026) |
|---|---|---|---|
| W-2GU, with W-3SS totals | SSA | EFW2 text file uploaded to BSO ("Report Wages to Social Security") | Feb 1, 2027 |
| W-2GU, with W-3SS (Copy 1) | Guam DRT | The same EFW2 file uploaded at GuamTax.com ("E-File W-3/W-2GU"). An e-file counts as the official filing, so no paper is needed. | Jan 31 / Feb 1, 2027 (confirm) |
| W-2GU Copies B, C and 2 | Each employee | Paper. Plain paper is fine for employee copies. PDF-only delivery requires the employee's prior electronic consent (26 CFR 31.6051-1(j)); otherwise paper. | Feb 1, 2027 |
| 1099-NEC, with 1096 | Guam DRT | Pub 1220 text file uploaded at GuamTax.com ("E-File 1096/1099"), or paper only when the payer's combined count of all DRT information returns is under 10 | Feb 1, 2027 |
| 1099-NEC Copy B | Each contractor | Paper. PDF-only delivery requires the payee's affirmative consent (IRS Pub 1179 / 1099 general instructions); otherwise paper. Confirm DRT applies the same rule. | Feb 1, 2027 |

Notes:

- **No paper W-3SS when e-filing.** Instructions for Form W-3SS: "Do not send Form W-3SS if you filed electronically with the SSA." DRT says the GuamTax e-file "constitutes official filing."
- **1099 threshold:** $2,000 for payments made after 2025 (1099-NEC and most 1099-MISC). The app already uses this (`db/seeds/information_return_thresholds.rb`).
- **Corrections:** W-2c goes to SSA as an EFW2C file or through W-2c Online. If the original had to be e-filed, the correction must be too. DRT does not take corrections online, so they go on paper.
- **Guam e-file mandate:** GTITC §6011(e)(2)(A), effective for tax year 2023 filings, per DRT Tax Alert 23-01-ITAPB. The alert says the 10-return rule applies "separately for each type of form" and also says to add all returns together. The safe reading is to e-file everything once the combined count of all DRT information returns (W-2GU, 1099-NEC, 1099-MISC, 1098 variants, W-2G) reaches 10. There is no automatic 30-day extension; Form 8809 can request 30 more days to file with DRT, but not to furnish copies to workers.
- **SSA e-file mandate:** 10 or more returns combined, since 2024. A waiver uses Form 8508.

## 2. The EFW2 file (SSA and GuamTax)

Specification: **SSA Publication 42-007, EFW2 Tax Year 2026, Version 4**, dated November 12, 2026 (<https://www.ssa.gov/employer/efw/26efw2.pdf>). The corrections spec is EFW2C (<https://www.ssa.gov/employer/efw/26efw2c.pdf>).

Structure:

- **Record length.** Fixed-width ASCII. Every record is 512 bytes, followed by CR/LF.
- **Records.** One RA (submitter), then for each employer an RE followed by its RW/RO records and an RT/RU, and a single RF at the end.
  - RA, RE, RW, RT and RF are required.
  - RO and RU are required whenever any field in them applies, which W-2GU always triggers.
  - RS and RV are optional, and SSA and the IRS do not read them.
- **Several employers per file.** One file can hold several employers, each with its own RE. SSA caps a file at 1M RW or 50k RE records. For GuamTax, a multi-company upload needs a payroll-processor account (§3).

W-2GU-specific fields, checked against the 2026 spec:

| Record | Position | Field | Value for a Guam employer |
|---|---|---|---|
| RA | 12–19 | User Identification | The BSO User ID of the person submitting. Required. |
| RA | 36–37 | Software Code | `98` = In-House Program. Companies that write their own software do not request an NACTP code. |
| RE | 174 | Kind of Employer | Required. `N` (none apply) for an ordinary private employer. |
| RE | 219 | Employment Code | `R` = Regular (Form 941). Other codes (A, H, F, Q) only when they apply. |
| RE | 220 | **Tax Jurisdiction** | **`G` = Guam (W-2GU).** |
| RE | 319–328 | Employer Signature PIN | New and optional for 2026. Leave blank unless SSA issues one. |
| RW | 188–209 | Federal wages and federal income tax | "Does not apply to … Guam." Zero-fill. |
| RW | 210–253 | Social Security and Medicare wages and tax | Report as usual. Wage base $184,500. |
| RO | 363–373 | Wages subject to territorial income tax | Guam wages (W-2GU Box 1). |
| RO | 374–384 | Territorial income tax withheld | Guam tax withheld (W-2GU Box 2). |
| RU | 460–474, 475–489 | Totals of those two RO fields | Employer totals. |

The spec warns that amounts placed in the wrong fields for the jurisdiction "will not be processed by SSA and will not be forwarded to IRS." Putting Guam income tax in the RW federal-tax field is the most likely way to get this wrong.

New for 2026, and already tracked by the app:

- a Box 14b field (tipped occupation codes) in the RW record
- new RO amounts for codes TA, TP and TT (qualified tips and overtime)

Testing and upload:

- **No certification.** SSA has no certification step for wage-file software.
- **Test first.** Every file should pass **AccuWage Online**, a free checker inside BSO, before it is uploaded. The spec says BSO "no longer accepts incorrectly formatted W-2 files."
- **File name and packaging.** Any file name works, as long as the content is ASCII text. A file may be zipped, but only one wage file per zip.
- **Upload window.** BSO accepts 2026 files from **December 8, 2026** (per the spec; SSA's Fall 2026 presentation says December 7).
- **BSO is changing.** SSA is rolling out a new authorization process with company-officer roles, third-party-submitter delegation, and Login.gov or ID.me sign-in. Cornerstone should check now whether it has to complete this before filing as a third-party submitter for clients.

## 3. Guam DRT (GuamTax.com)

- **Same upload format as SSA.** GuamTax help: "W-3/W-2GU data must be in ASCII text format in the same file format defined in the Social Security Administration's (SSA's) Specifications for Filing Forms W-2GU Electronically (EFW2)."
- **Business account required.** Clients need a GuamTax business account (ID and PIN) to e-file.
- **Payroll processors.** To e-file W-3/W-2GU data **for other companies at all**, whether in one combined file or one file per client, Cornerstone's GuamTax account must be flagged as a payroll processor account. That takes a registration form (`GuamTax_SWICA_PayrollProcessors20240715.pdf`), faxed or mailed to DRT's PIN Administrator ((671) 635-1809, pinadmin@revtax.guam.gov), which DRT approves and then mails back with an ID and access code. Without it, each client has to upload under its own GuamTax account. Because it goes by mail, **start this now**.
- **1099 upload.** ASCII text following **IRS Publication 1220** (the old IRS FIRE layout). DRT e-files 1099-MISC, 1099-NEC, 1098 variants, W-2GU and W-2G.
- **The FIRE shutdown.** The IRS shuts FIRE down after November 19, 2026, and the latest Pub 1220 is "For Tax Year 2025 (Rev. 5-2026)." There may never be a tax year 2026 edition, so ask DRT which Pub 1220 version it validates against.
- **Quarterly withholding returns.** DRT also e-files the quarterly W-1. There is no separate annual withholding reconciliation form.
- **DRT copies show full IDs.** DRT requires full EINs and SSNs on its copies.
- **Contact:** Income Tax Assistance and Processing Branch, (671) 635-1857, incometax@revtax.guam.gov.

## 4. What ezW2 did

Source: Halfpricesoft's website and the license email Dafne forwarded. The license keys in that email are sensitive. They are not stored here and were not used.

- **Product.** ezW2 2025, a 2-user Windows desktop program activated by a license key. There is no online account to inspect.
- **Forms listed.** W-2 Copies A, B, C, D, 1 and 2, W-3, 1099-NEC and 1096. W-2GU and W-3SS are not mentioned anywhere on the vendor site. 1099-MISC now needs a separate product, ez1099.
- **E-file.** Two options:
  - self-file: produce an EFW2 `.txt` per client and upload it with your own SSA User ID;
  - paid in-app e-file: about $1.99 per form to SSA, and 1099s through the vendor's IRS channel.

  The vendor documents no 1099 file you could upload to GuamTax yourself.
- **Printing.** W-2 copies on plain paper using SSA-approved black-and-white Copy A designs. Red-ink forms for 1099-NEC Copy A and the 1096.
- **2026 price.** $69 single-user paper, $119 single-user e-file, $139 for the 2-user network edition.

The feature that mattered to Cornerstone, "a file you can upload directly to Social Security," is the EFW2 export. Payroll can produce the same file, with the Guam fields set correctly, and the same file also works for GuamTax.

## 5. What Payroll already has

| Area | Today | Evidence |
|---|---|---|
| W-2GU data | `W2GuAggregator` builds per-employee Boxes 1–7 and Box 12 codes D and AA, plus TP and TT from 2026. It also covers the Box 13 retirement checkbox and Box 14b. It combines committed payroll with the locked opening YTD balances and caps Box 3 and then Box 7 at the wage base. | `api/app/services/w2_gu_aggregator.rb` |
| W-2GU exports | JSON, CSV, XLSX, and a PDF marked "FOR INTERNAL USE ONLY" with masked SSNs | `api/config/routes.rb`, `w2_gu_pdf_generator.rb` |
| Readiness | Preflight (employer EIN and address, employee SSN and address), a fingerprint-bound "mark ready", a filing-responsibility gate, and after-the-fact submission evidence | `w2_gu_preflight_validator.rb`, `w2_filing_readiness.rb`, `payroll_filing_responsibility_gate.rb`, `payroll_filing_record.rb` |
| 1099-NEC data | `Form1099NecAggregator` with a threshold that depends on the year, plus TIN, address and W-9 warnings | `form_1099_nec_aggregator.rb` |
| 1099 exports | Summary PDF, CSV and XLSX | `api/config/routes.rb` |
| Official-form filling | `OfficialPdfOverlay` already fills official 941, W-1 and SW-2 templates | `quarterly_compliance_official_forms.rb`, `api/lib/assets/` |

## 6. What is missing

1. **Official W-2GU copies.** There are no employee Copies B, C and 2 and no DRT Copy 1. The aggregator rows lack a control number, Box 8, Box 10, Box 11 and Box 14 (other), and the PDF uses masked SSNs. Official copies need the full SSN through a controlled, audited path.
2. **W-3SS totals.** The aggregator's `totals` hash is a starting point. There is no W-3SS output, and no fields for:
   - kind of employer
   - employer contact name, phone and email
   - establishment number
3. **EFW2 file.** No RA/RE/RW/RO/RT/RU/RF generator exists. Payroll stores no BSO User ID or submitter contact.
4. **1099s.** Missing:
   - official 1099-NEC copies
   - a 1096
   - the Pub 1220 file
   - 1099-MISC support (`InformationReturnThreshold::FORM_TYPES` only has `1099_nec`)
   - a 1099 filing type in `PayrollFilingResponsibility`
5. **Corrections.** There is no W-2c or EFW2C. `PayrollFilingRecord` allows one record per form type per company and year, so a correction has nowhere to go.
6. **Worker delivery.** There is no way to deliver W-2s to workers, and no electronic-consent record (see the employee portal plan).

## 7. Data problems to fix before any form is printed

These are about correct numbers, so they come first.

1. **Box 1 basis.** Live Box 1 is `gross_pay − 401(k)`. It does not use the `fit_taxable_wages` the app already stores per payroll item, and QuickBooks history uses the same rule. If any client has pre-tax health or cafeteria-plan deductions, or non-taxable pay, Box 1 comes out too high. Use stored taxable wages and test it with a pre-tax deduction.
2. **Reconciliation.** Nothing compares W-2 totals with the four 941s (Social Security and Medicare wages and tax) or the W-1s (Guam tax withheld). Add a reconciliation report that blocks "ready" when they differ.
3. **Warnings that should block.** Tip classification, qualified overtime, Box 14b and legacy tax-base problems show only as report warnings. Preflight blocks only missing EIN, SSN or address.
4. **1099 totals miss one-off checks.** `NonEmployeeCheck` records with check type `contractor` are not added in.
5. **MoSa's tips before cutover.** Box 12 TP and TT come only from live payroll. QuickBooks-era history is marked unclassified. If MoSa's staff earned tips before August 24, those need a manual review.
6. **Addresses.** The QuickBooks parser drops Nevada addresses, so some imported workers may have blank addresses.
7. **Box 12 and Box 14 coverage.** Only code D (401(k)) is modeled. Codes DD (employer health cost), W, C, Box 10 (dependent care), Box 8 (allocated tips), Box 14 "other" and third-party sick pay are not modeled. Confirm whether any client needs them this year.
8. **Prior-provider overlap.** Opening YTD balances are included in W-2GU totals. If a prior provider files a W-2 covering part of 2026, those wages must not be reported again. Before building, record for each client and period who files, and block "ready" when imported opening balances cover periods a prior provider is filing. The existing filing-responsibility setting is where this belongs (`payroll_filing_responsibility_gate.rb`).
9. **Labels and fields.** The W-2 CSV calls Box 2 "Federal Income Tax Withheld". On a W-2GU it is Guam income tax withheld. Employees have no name-suffix field, which EFW2 RW records include.

## 8. Build plan

The work happens in this order because each step depends on the numbers from the one before.

| Step | Work | Done when |
|---|---|---|
| 0 (now, Cornerstone) | Confirm BSO access and any new authorization steps. Confirm the GuamTax business accounts, and start the payroll-processor registration if wanted. Answer the questions in §9. | Accounts confirmed, answers recorded |
| 1 | Data fixes from §7: Box 1 basis, 941/W-1 reconciliation, blocking warnings, contractor checks in 1099 totals, prior-provider overlap check | Reconciliation ties out for each client on staging copies |
| 2 | W-2GU employee and DRT copies through `OfficialPdfOverlay`, with an audited full-SSN path | Dafne reviews sample copies for one client |
| 3 | W-3SS totals and the EFW2 generator, with byte-length and total checks; the employer fields it needs; a per-company "kind of employer" setting | The file passes AccuWage; a GuamTax test upload succeeds |
| 4 | 1099-NEC copies, the 1096 and the Pub 1220 file for GuamTax | DRT accepts a test upload, or Cornerstone files on paper for a payer whose combined DRT return count is under 10 |
| 5 | Filing workflow: generate, review, upload outside the app, record acceptance evidence (`PayrollFilingRecord`) | First client filed and accepted |
| Later | W-2c / EFW2C, employee e-delivery with consent, 1099-MISC if needed | Before the 2027 season |

Timing: steps 1–3 by mid-December so files can be tested once BSO opens on December 7–8. Step 4 in late December. Real filings in January.

**Fallback:** renew ezW2 for 2026 (about $139) and type in figures from our W-2 CSV export, until the first file passes AccuWage and Dafne has reviewed sample copies. Keep this option open until then.

Built this way, the year-end work is the same for every client. It is driven by company settings (EIN, kind of employer, filing responsibility, contacts) and has no client-specific code.

## 9. Questions for Cornerstone

1. **Last year's files.** Can we have one client's EFW2 `.txt` from ezW2, plus a printed W-2? We'll check whether it was filed as W-2GU (RE position 220 = `G`, Guam tax in RO records) and use it as a format reference.
2. **SSA access.** Who holds Cornerstone's BSO login? Has SSA asked them to complete the new authorization (company officer and third-party submitter)?
3. **GuamTax.** Does each client have its own GuamTax business account, or does Cornerstone file for them? If Cornerstone files for them, its account needs the payroll-processor registration (§3) whether it uploads one file or one per client.
4. **1099s last year.** Were they filed with DRT on paper or by upload? How many clients have 1099 payees, and roughly how many forms each?
5. **Pre-tax deductions.** Does any client have pre-tax health insurance, cafeteria-plan (Section 125), dependent care or HSA deductions? This decides the Box 1 fix and Box 12/Box 10 coverage.
6. **Other W-2 items.** Does any client report employer health cost (Box 12 DD), allocated tips (Box 8) or third-party sick pay?
7. **Prior payroll provider.** Which clients had a provider before Cornerstone during 2026, and for which periods does that provider file? This has to be settled per client before the build starts, so opening balances aren't reported twice (§7 item 8).
8. **Delivery.** Does each client want paper copies for employees, PDFs, or both? Electronic delivery of a W-2 needs each employee's prior consent.
9. **DRT confirmations** (Cornerstone can ask DRT, or we can draft the email): the 2026 due date; which Pub 1220 version GuamTax accepts for tax year 2026; and whether a Guam business paying an off-island contractor still files the 1099 with DRT.

## Sources

- SSA EFW2 Tax Year 2026 (Pub 42-007 v4, 11/12/2026): <https://www.ssa.gov/employer/efw/26efw2.pdf>
- SSA EFW2C: <https://www.ssa.gov/employer/efw/26efw2c.pdf>
- SSA AccuWage: <https://www.ssa.gov/employer/accuwage/index.html>
- SSA software developers: <https://www.ssa.gov/employer/software.htm>
- SSA Fall 2026 employer presentation: <https://www.ssa.gov/employer/reporter/meetingPresentationFall2026.pdf>
- IRS General Instructions for W-2 and W-3 (incl. W-2GU / W-3SS Copy 1 to DRT): <https://www.irs.gov/pub/irs-pdf/iw2w3.pdf>
- IRS Form W-3SS: <https://www.irs.gov/pub/irs-pdf/fw3ss.pdf>
- IRS 1099-MISC/NEC instructions ($2,000 threshold): <https://www.irs.gov/pub/irs-pdf/i1099mec.pdf>
- IRS Pub 1220: <https://www.irs.gov/pub/irs-pdf/p1220.pdf>
- IRS Pub 1141 (substitute W-2): <https://www.irs.gov/pub/irs-pdf/p1141.pdf>
- IRS FIRE retirement: <https://www.irs.gov/e-file-providers/filing-information-returns-electronically-fire>
- GuamTax W-3/W-2GU help: <https://www.guamtax.com/help/help_w2w3.html>
- GuamTax 1099 help: <https://www.guamtax.com/help/help_1099.html>
- DRT Tax Alert 23-01-ITAPB: <https://www.guamtax.com/notices/TaxAlert23-01-ITAPB-EmployerNotificationW3SSW2GUAND10961099-2023UPDATED12202023.pdf>
- DRT payroll-processor registration: <https://www.guamtax.com/forms/GuamTax_SWICA_PayrollProcessors20240715.pdf>
- Halfpricesoft ezW2 features and pricing: <https://www.halfpricesoft.com/w2-software/ezw2-features-and-pricing/>
- Halfpricesoft self e-file how-to: <https://www.halfpricesoft.com/w2-software/efile-w2-form-how-to/>

Related: [Payroll, QuickBooks and compliance master plan](PAYROLL_QUICKBOOKS_COMPLIANCE_MASTER_PLAN_2026-07-11.md) (Phase 3), [W-2 filing operationalization](W2_FILING_OPERATIONALIZATION_PLAN.md), [Employee portal and platform plan](EMPLOYEE_PORTAL_AND_PLATFORM_PLAN_2026-11-17.md).
