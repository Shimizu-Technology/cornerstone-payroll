# Cornerstone Payroll: QuickBooks, Payroll, and Compliance Master Plan

> **Implementation status (2026-07-13):** Phase 0 engineering was merged through PR #111 (`44f60f7`). Phase 1A now has an implementation candidate on `codex/phase-1-payroll-liability-foundation`; see the [Phase 1A Payroll Liability Foundation](PHASE_1A_PAYROLL_LIABILITY_FOUNDATION_2026-07-13.md). It adds effective-dated component-rule evidence, immutable commit/reversal/replacement liability postings, explicit historical backfill, and pay-period reconciliation without changing payroll calculations. Phase 0 operational evidence and Phase 1A production validation still require signoff before deployment/backfill. Later Phase 1 operational capabilities remain planned.

**Status:** Active source of truth for post-July 2026 planning
**Created:** 2026-07-11
**Owner:** Shimizu Technology / Cornerstone Tax Services
**Primary objective:** Replace QuickBooks and spreadsheet-driven payroll operations for Cornerstone with a dependable Guam-native payroll and employer-compliance platform.
**Deferred objective:** Individual and business income-tax return preparation is intentionally lower priority and is not part of the near-term execution plan.

---

## 1. Executive decision

Cornerstone Payroll should be completed in this order:

1. **Correctness, security, and truthful product language.**
2. **QuickBooks payroll operational parity.**
3. **Production-grade quarterly payroll compliance.**
4. **Production-grade annual payroll compliance.**
5. **QuickBooks historical exit, payroll accounting exports, and check/bank reconciliation.**
6. **Scale, automation, and employee/client self-service.**
7. **Optional full accounting parity, only after a separate scope decision.**
8. **Individual and business income-tax preparation later.**

The immediate product is therefore:

> A Guam-native payroll operating system and employer-compliance workspace for Cornerstone and its clients.

It is not currently, and should not yet be marketed as:

- a complete QuickBooks accounting replacement;
- an automated tax-filing service;
- an IRS-approved income-tax return preparation product; or
- a consumer self-service tax product.

This plan supersedes the priority ordering in older roadmap documents. Older documents remain useful historical references, but completion labels in those files do not override the release gates in this plan.

---

## 2. Why this product exists

Cornerstone's original workflow combined spreadsheets, source-system exports, manual review, and QuickBooks. The main problems were:

- QuickBooks Payroll does not provide a clean Guam-native workflow.
- Employee hours, tips, deductions, loans, and payroll fields arrived from different sources.
- Payroll calculations and filing support depended on spreadsheets and institutional knowledge.
- QuickBooks was used heavily for payroll checks and reports even though it created Guam address and workflow friction.
- The payroll record, check history, compliance evidence, and client communications were not in one controlled system.

The application was built to turn that fragmented process into a repeatable lifecycle:

```text
client setup
  -> employee and payroll configuration
  -> hours/tips/import intake
  -> calculation
  -> review and comparison
  -> approval
  -> commitment
  -> checks/pay stubs
  -> quarterly and annual compliance work
  -> evidence, history, and client access
```

That remains the right product direction.

---

## 3. Revalidated current state

### 3.1 Strong current capabilities

The application already provides a substantial payroll foundation:

- organization and company tenancy;
- role-based company access;
- employee, department, wage-rate, payroll-field, deduction, retirement, and loan setup;
- hourly, salary, and contractor calculations;
- multiple wage rates;
- regular, overtime, holiday, PTO, tips, bonuses, reimbursements, and custom earnings;
- pre-tax, post-tax, taxable, and non-taxable adjustments;
- Social Security wage-base capping and Additional Medicare calculations;
- W-4 Step 2, Step 3, Step 4(a), and Step 4(b) inputs;
- draft -> calculated -> approved -> committed payroll lifecycle;
- pay-period comparison review;
- void, correction, replacement-check, and supplemental corrective-paycheck workflows;
- check numbering, check printing, printer profiles, test alignment, reprints, and check events;
- Revel, MoSa, Spike, OCR, time-tracking, CSV, and Excel intake paths;
- payroll register, employee history, tax summary, YTD, deductions, retirement, loans, and check reports;
- Form 500 preparation and payment-tracking fields;
- quarterly compliance packet preparation for W-1, SWICA/SW-2, federal Form 941, and Schedule B;
- W-2GU and 1099-NEC preparation summaries;
- client documents, client messages, change requests, and read-only client payroll/report access;
- audit logging and tax-configuration history.

The backend also has broad automated coverage. Phase 0 added Playwright infrastructure and public/authenticated payroll smoke tests. The authenticated smoke remains environment-gated and does not replace broader browser coverage for calculate, review, approve, commit, correct, and filing workflows.

### 3.2 Current capability assessment

| Area | Current status | What prevents production-complete status |
|---|---|---|
| Core payroll calculation | Strong but requires certification | Tax-year/config defects, status mismatch, official test-vector coverage, pay-component taxability |
| Payroll operations | Strong | General off-cycle/bonus runs, direct deposit, PTO balances, garnishments, locations/jobs, employee delivery |
| Check operations | Strong | Bank reconciliation and payment-clearing workflow |
| Quarterly compliance | Partial | Deposit ledger, complete Form 941 lines, corrections, evidence attachments, due-date engine, accepted-file validation |
| Annual compliance | Partial | 2026 W-2GU changes, EFW2, W-3SS, corrections, official/e-file 1099 flow, conditional annual obligations |
| QuickBooks payroll exit | Partial | Historical snapshot import and formal reconciliation/cutover are still missing |
| Payroll accounting bridge | Missing | GL mappings, journal export, liability/payment posting, bank reconciliation |
| Full QuickBooks accounting | Missing | No double-entry ledger, AP/AR, bank feeds, trial balance, or financial statements |
| Individual/business tax returns | Missing and deferred | Separate return engine, diagnostics, signatures, MeF approval, and filing operations |

### 3.3 Verification snapshot after merged Phase 0 on 2026-07-12

The merged Phase 0 release candidate completed:

- backend: `1395 examples, 0 failures`; fixture-dependent examples remain pending where real MoSa records or source PDFs are not present;
- frontend: TypeScript, ESLint, and production build passed;
- focused Phase 0 correction/tax regression suite: `41 examples, 0 failures`;
- Brakeman: 0 application-code warnings;
- Bundler Audit and npm audit: passed at the merged release commit;
- migration rollback/reapply: passed;
- official backend and frontend GitHub quality checks: passed;
- Greptile final review: `5/5`, safe to merge, with no unresolved threads;
- Playwright smoke infrastructure: present, including public compliance and authenticated payroll smoke paths;
- repository Node version: pinned; local operators must actually select that version rather than an older globally installed Node runtime.

The remaining Phase 0 gaps are operational evidence, broader browser coverage, production-shaped authenticated validation, real-fixture coverage, and completion of the generalized effective-dated pay-component taxability matrix.

---

## 4. Important findings confirmed by the second review

These are not optional polish. They are correctness, filing, security, or product-trust issues.

### 4.1 Use the requested tax year, not the globally active year

`AnnualTaxConfig.current(year)` currently prefers any active configuration before the requested year's configuration. A backdated payroll or correction can therefore use a different year's rules.

Required behavior:

- calculation rules are selected by pay date and effective date;
- historical payroll never silently uses the currently active year;
- an unsupported year blocks calculation with a clear error;
- tax-rule versions used by a committed payroll are preserved in its calculation snapshot.

### 4.2 Filing-status inputs and rule configurations must agree

Employees can use `married_separate`, but filing-status configurations currently support only `single`, `married`, and `head_of_household`.

Required behavior:

- normalize current W-4 `single_or_married_filing_separately` explicitly;
- store the W-4 version/effective date;
- distinguish pre-2020 allowance-based W-4 logic from 2020+ logic when legacy employees require it;
- reject unsupported combinations before payroll is approved.

### 4.3 The 2026 1099-NEC threshold is not $600

The application hard-codes a $600 threshold. For payments made in 2026, current IRS guidance raises the applicable reporting threshold for Form 1099-NEC and certain Form 1099-MISC payments to $2,000, with inflation adjustment after 2026.

Required behavior:

- store threshold rules by form, payment year, payment category, and effective date;
- retain the $600 rule for applicable prior years;
- avoid embedding filing thresholds in report classes;
- separately track backup withholding and exceptions.

Official source: [IRS Publication 1099](https://www.irs.gov/publications/p1099)

### 4.4 "941-GU" is not the current federal form

Form 941-SS was discontinued after 2023. Guam employers now file the standard federal Form 941, applying the territory-specific instructions. Guam employers generally skip lines 2 and 3 unless they have employees subject to U.S. income-tax withholding.

The backend increasingly uses the correct concept, but the public site, login copy, route/service names, and older planning documents still use "941-GU." The active README and runbook have now been corrected; the remaining application and historical references need deliberate migration rather than silent reinterpretation.

Required behavior:

- user-facing name: **Federal Form 941** or **Federal Form 941 for Guam employers**;
- filing destination: IRS, not Guam DRT;
- retain legacy API route names temporarily only for compatibility;
- add deprecation aliases before eventually renaming route/service identifiers;
- correct all operator documentation before the next quarterly filing cycle.

Official source: [2026 Instructions for Form 941](https://www.irs.gov/instructions/i941)

### 4.5 Form 941 is still incomplete

The current service and official-form overlay do not complete all required paths:

- line 8 sick-pay adjustment;
- line 9 tips/group-term-life adjustment;
- line 11 credits;
- line 13 deposits;
- line 14 balance due or overpayment;
- third-party-designee data;
- signer/preparer workflow;
- complete monthly/semiweekly/next-day deposit determination;
- amendments through Form 941-X.

The official PDF overlay currently writes only a subset of lines. Missing data must block "ready to file" status unless the operator explicitly enters and reviews it.

### 4.6 Deposit schedule determination cannot rely only on available payroll history

Federal monthly versus semiweekly deposit status depends on the statutory lookback period, and the $100,000 next-day deposit rule can change the required schedule. A client without complete history in Cornerstone cannot be classified safely from Cornerstone data alone.

Required behavior:

- store the employer's authoritative deposit schedule and effective date;
- store lookback liabilities and their source;
- support manual professional override with reason and approval;
- implement the next-day rule and due-date calculation;
- distinguish tax liability date from payment date;
- reconcile every payment to liabilities and Form 941 line 13.

### 4.7 Quarterly due dates need a rules engine

The current packet uses a simple end-of-following-month calculation. It does not fully model:

- weekends and legal holidays;
- Guam and federal filing calendars;
- deposit dates that differ from return dates;
- emergency/disaster extensions;
- client-specific internal target dates;
- amended-return dates.

Required behavior:

- effective-dated deadline rules;
- jurisdiction and obligation type;
- holiday calendar and next-business-day logic;
- authoritative extension/override records;
- reminders and escalation based on both legal and internal dates.

Official source: [GuamTax tax calendar](https://www.guamtax.com/info/calendar.html)

### 4.8 Quarterly evidence is represented by booleans, not actual evidence

Quarterly tasks can record statuses, confirmation numbers, and `proof_attached`, but there is no complete filing-evidence object linking the actual receipt, acknowledgment, return copy, payment proof, signer, and timestamp.

Required behavior:

- attach the actual evidence document;
- record source, hash, uploader, timestamp, filing period, and obligation;
- preserve superseded and amended evidence;
- never allow a boolean alone to represent proof.

### 4.9 2026 W-2GU requirements need new payroll data

The 2026 W-2/W-2GU instructions add:

- Box 12 code `TP` for total cash tips reported to the employer;
- Box 12 code `TT` for qualified overtime compensation;
- Box 14b for Treasury Tipped Occupation Code(s).

The current application does not distinguish all required concepts:

- voluntary cash/charged tips versus mandatory service charges;
- qualified tipped occupation codes;
- qualified overtime premium versus total overtime pay;
- current-year W-2GU schema/version.

Required behavior:

- first-class tip classification and source fields;
- employee tipped-occupation history with effective dates;
- qualified overtime computation and stored audit detail;
- year-versioned W-2GU box mapping;
- reconciliation from payroll earnings to W-2GU output.

Official source: [2026 General Instructions for Forms W-2 and W-3](https://www.irs.gov/instructions/iw2w3)

### 4.10 W-2GU preparation is not W-2GU filing

The current W-2GU output is a preparation summary. Production annual compliance still needs:

- full employee SSNs in a tightly controlled filing process;
- W-3SS totals;
- EFW2 ASCII generation for the correct year;
- employer/payroll-processor and location records;
- GuamTax upload validation;
- confirmation-page evidence;
- paper path for zero-employee filings where required;
- corrected W-2GU/W-3SS workflow, because GuamTax's online flow currently accepts originals but not corrections.

Official source: [GuamTax W-3/W-2GU e-filing help](https://www.guamtax.com/help/help_w2w3.html)

### 4.11 Conditional annual employer filings are missing from the obligation catalog

Not every client owes every filing, but the product must determine and track applicable obligations. Examples include:

- Form 8027 for qualifying large food or beverage establishments;
- Forms 1094-C/1095-C for applicable large employers and relevant self-insured employers;
- Form 944 if the IRS authorizes annual rather than quarterly employment-tax filing;
- Form 943 for applicable agricultural employers;
- Form 945 for applicable nonpayroll withholding;
- Forms 1042/1042-S for applicable foreign-person payments;
- retirement and benefit filings handled outside normal payroll returns;
- Guam-specific industry, H-2B, labor, or licensing obligations.

FUTA generally does **not** apply to employers in Guam, so the obligation engine must not blindly copy mainland QuickBooks defaults or require Form 940. It must encode the territory rule and allow only a professionally reviewed exception path if facts outside the ordinary Guam-employer case require different treatment.

Form 8027 is especially relevant to restaurant clients with tips. It requires establishment-level receipts, charged tips, service charges, reported tips, and allocated-tip calculations that payroll alone may not contain.

Official sources:

- [IRS Form 8027 instructions](https://www.irs.gov/instructions/i8027)
- [IRS Forms 1094-C/1095-C instructions](https://www.irs.gov/instructions/i109495c)
- [IRS Publication 15 (2026), territory FUTA rule](https://www.irs.gov/publications/p15)

### 4.12 Pay-component taxability needs an explicit effective-dated model

Current reports infer some treatment from earning categories. That is insufficient for a compliance product.

Every earning, deduction, and employer contribution needs explicit rules for:

- Guam income-tax withholding;
- Social Security wages;
- Social Security tips;
- Medicare wages;
- Additional Medicare;
- W-2GU boxes/codes;
- Form 941 lines;
- SWICA wages;
- retirement-plan treatment;
- reimbursement/accountable-plan treatment;
- payroll register presentation;
- GL account mapping.

The rule must be versioned and snapshotted when payroll is committed.

### 4.13 QuickBooks parity documents overstate filing completeness

The existing checklist labels Form 941 and W-2GU capabilities "Done" even though the application currently produces preparation workpapers and partial official overlays, not a complete filing/acknowledgment workflow.

This plan uses the following status definitions:

- **Calculated:** The application can compute the values.
- **Prepared:** A reviewer can inspect a workpaper or draft form.
- **Filing-ready:** All required data, diagnostics, approvals, and reconciliations pass.
- **Filed:** The return/file was submitted to the proper authority.
- **Accepted:** An authoritative acknowledgment or confirmation is stored.
- **Corrected:** A correction/amendment lifecycle is supported.

No feature is "complete" for compliance purposes merely because a PDF or spreadsheet can be generated.

### 4.14 Production and dependency security need immediate work

The second-pass review confirms that production expansion should not proceed without:

- resolving backend and frontend dependency advisories;
- enforcing MFA for privileged users;
- enforcing TLS/HSTS in production;
- using durable encrypted object storage instead of local production storage;
- using durable job processing for filing/report jobs;
- rate limiting and abuse protection;
- monitored backups and restore testing;
- security-event monitoring and incident response;
- a Written Information Security Plan;
- tamper-evident audit retention and export.

The current application-level audit log is useful, but it is not yet a complete immutable compliance ledger.

### 4.15 Frontend workflow testing is missing

There are no frontend application tests. The calculate, review, approve, commit, correct, print, prepare, and filing-readiness workflows require browser-level automated coverage.

Large frontend and controller files also need incremental decomposition so that filing rules, report presentation, and HTTP concerns do not remain coupled.

### 4.16 Payroll compliance extends beyond tax forms

The current roadmap is strongest on payroll calculations and tax reports, but a trustworthy payroll replacement must also enforce or surface the wage-and-hour rules that determine whether the paycheck itself is lawful.

For ordinary Guam-covered employees, the current Guam Department of Labor guidance includes:

- a $9.25 minimum wage;
- overtime of at least 1.5 times the regular rate after 40 hours in a workweek for covered nonexempt employees;
- earned wages generally due within seven days after the pay period ends;
- discharge pay due immediately or by the next business day;
- at least a 30-minute meal period after more than five hours, subject to the stated six-hour mutual-waiver rule;
- overlapping Guam and federal child-labor requirements.

Required product behavior:

- versioned jurisdictional wage-and-hour rules rather than constants embedded in calculation code;
- exemption/classification, worksite, workweek, and regular-rate data sufficient to test overtime correctly;
- minimum-wage, overtime, meal-period, late-pay, and final-pay diagnostics;
- explicit warnings when imports aggregate hours in a way that prevents workweek-level validation;
- workers' compensation classification and reporting support where required;
- new-hire, I-9, child-labor, and required-document task tracking without pretending the software makes legal classification decisions;
- professional override with reason, approval, and audit evidence for exceptional cases.

Official source: [Guam Department of Labor wage-and-hour FAQ](https://dol.guam.gov/compliance/whd/frequently-asked-questions/)

### 4.17 Filing reports must not reconstruct tax bases from gross pay

The Federal Form 941 aggregator currently rebuilds Social Security and Medicare wage bases from `gross_pay`, reported tips, and report-local constants. This works for simple current payrolls, but it is not a durable source of truth once pay components have different FIT, Social Security, or Medicare treatment. It can also drift from the calculation engine or the exact rules used by a historical committed payroll.

Required behavior:

- persist employee/pay-period FIT, Social Security wage, Social Security tip, Medicare wage, and Additional Medicare bases;
- persist employee and employer tax results separately;
- link every base/result to the committed pay-component and regulatory-rule snapshot;
- have quarterly and annual reports sum committed bases/results rather than infer them from gross pay;
- reconcile calculated tax from stored bases to stored withheld/employer tax and surface rounding or adjustment differences;
- prohibit a report from silently substituting a current-year constant for a historical committed rule.

This is a prerequisite for trustworthy Form 941, Schedule B, W-2GU, W-3SS, and historical-import reporting.

---

## 5. Defining QuickBooks parity correctly

"QuickBooks parity" has two different meanings. They must not be mixed.

### 5.1 Level A: Cornerstone payroll QuickBooks replacement

This is the immediate goal. It means Cornerstone no longer needs QuickBooks to:

- maintain payroll employees and payroll items;
- enter/import hours and pay data;
- calculate and review payroll;
- print checks and pay stubs;
- manage check numbers, voids, reprints, and replacements;
- run the payroll reports Cornerstone relies on;
- prepare quarterly and annual employer compliance;
- preserve payroll history and audit support;
- export payroll accounting entries to whichever accounting system a client uses.

This plan treats Level A as committed scope.

### 5.2 Level B: complete QuickBooks accounting replacement

This would additionally require:

- chart of accounts;
- balanced journal-entry and posting engine;
- accounts receivable and accounts payable;
- customer/vendor subledgers;
- bank feeds and bank-statement reconciliation;
- trial balance;
- profit and loss, balance sheet, and cash-flow statements;
- close periods and accountant adjustments;
- fixed assets/depreciation;
- inventory and purchase orders where applicable;
- classes, locations, projects, and job costing;
- sales and business-tax accounting.

The current application does not contain this accounting kernel.

Level B is a later decision, not assumed near-term scope. Before authorizing it, Cornerstone must inventory how each company actually uses QuickBooks and decide whether the business needs:

1. payroll replacement only;
2. payroll plus accounting exports and bank/check reconciliation; or
3. a complete accounting product.

### 5.3 Payroll parity gap matrix

| QuickBooks Payroll expectation | Current state | Target priority |
|---|---|---|
| Regular payroll | Implemented | Maintain/certify |
| General off-cycle, bonus, commission, fringe-benefit payroll | Missing/partial corrective-only path | P1 |
| Multiple rates | Implemented | Maintain/certify |
| Payroll items | Implemented | Add explicit taxability and GL rules |
| Payroll comparison/review | Implemented | Add anomaly rules and E2E coverage |
| Check printing and lifecycle | Strong | Add clearing/reconciliation |
| Direct deposit | Missing | P1/P2 based on client demand |
| Employee paystub/W-2 access | Missing | P2 |
| Paystub delivery | Missing | P1/P2 |
| PTO/sick accrual balances | Missing | P2 |
| Garnishment case/remittance tracking | Partial deduction/check support | P2 |
| Benefits and workers' compensation classification/reporting | Missing | P2 |
| Locations/worksites/jobs/classes | Partial departments only | P2 |
| New-hire and terminated-employee reports | Partial | P2 |
| Payroll tax liability and payment history | Partial | P0/P1 |
| Quarterly filing workflow | Partial | P0/P1 |
| Annual filing workflow | Partial | P1 |
| W-2GU electronic filing | Missing | P1 |
| 1099 electronic filing/corrections | Missing | P1/P2 |
| Payroll accounting/GL export | Missing | P2 |
| Bank/check reconciliation | Missing | P2 |
| Historical QuickBooks migration | Planned, not implemented | P1 |
| Automated frontend workflow tests | Missing | P0 |

Official QuickBooks payroll-report reference: [Run payroll reports](https://quickbooks.intuit.com/learn-support/en-us/help-article/payroll-reports/run-payroll-reports/L13oTu2Ps_US_en_US)

---

## 6. Target product architecture

### 6.1 Preserve the payroll calculation domain

Payroll calculation should remain separate from filing presentation. A committed payroll must preserve:

- source inputs;
- normalized pay components;
- taxability rules used;
- employee tax-election version used;
- regulatory rule-set version used;
- calculation results;
- rounding decisions;
- reviewer/approver identity;
- correction lineage.

Reports and filing forms must read the committed facts rather than recomputing payroll under today's rules.

### 6.2 Add a compliance obligation domain

Recommended core records:

```text
compliance_obligation_definitions
  jurisdiction
  authority
  form/type
  frequency
  applicability rule
  legal due-date rule
  filing method

company_compliance_profiles
  company
  effective dates
  required obligations
  deposit schedules
  filer/payroll-processor identifiers
  PSP/reporting-agent/section 3504 role
  authorization scope and effective dates

compliance_periods
  company
  obligation
  period
  legal due date
  internal target date
  status

compliance_submissions
  prepared artifact
  submitted artifact
  submitted by/at
  confirmation/acknowledgment
  accepted/rejected status
  correction lineage

compliance_evidence
  return copy
  receipt/payment proof
  acknowledgment/rejection
  source hash and immutable metadata

tax_deposits
  authority
  liability period
  due date
  payment date
  amount
  confirmation
  reconciliation status
```

### 6.3 Add a regulatory rules domain

Recommended core records:

```text
regulatory_rule_sets
  jurisdiction
  rule type
  effective dates
  source URL/publication
  checksum/version
  prepared/reviewed/approved by
  activation status

pay_component_tax_rules
  component
  FIT/Guam withholding treatment
  SS treatment
  Medicare treatment
  filing box/line mappings
  effective dates

filing_schema_versions
  form/file type
  tax year
  official template/schema version
  validation rules
```

Tax rules should be immutable after use. Corrections create new versions; they do not rewrite the historical rules used by committed payroll.

### 6.4 Add a payroll liability ledger

The application needs a subledger tying together:

```text
committed payroll liability
  -> required deposit/payment
  -> check/ACH/payment event
  -> authority confirmation
  -> quarterly return line
  -> annual reconciliation
```

This is required before Form 941 lines 13/14 or true liability reporting can be trusted.

### 6.5 Keep income-tax return preparation separate

Future individual/business return preparation may share clients, documents, security, and tasks, but it should not be embedded into payroll controllers or payroll calculation models. It will require its own return/version/forms/diagnostics/e-file domain when prioritized later.

---

## 7. Implementation program

### Phase 0: correctness, naming, and security gate

**Goal:** Remove known correctness and trust blockers before expanding features.

**Delivery status (2026-07-12):** Engineering merged in PR #111. The calculation/data/security changes are delivered. Operational release evidence remains open, and the generalized effective-dated pay-component taxability matrix continues into Phase 1.

Deliverables:

1. Select tax configurations strictly by pay date/effective year.
2. Normalize filing statuses and add W-4 version/effective-date handling.
3. Replace the hard-coded 1099 threshold with versioned rules.
4. Persist committed taxable wage/tip bases and regulatory rule-set identifiers; stop filing reports from reconstructing bases from gross pay.
5. Add 2026 qualified-tip, qualified-overtime, and occupation-code data foundations.
6. Rename all user-facing "941-GU" references to Federal Form 941.
7. Correct filing destination and terminology in active documentation.
8. Remediate dependency advisories and make dependency audits CI gates.
9. Pin a repository-supported Node version that satisfies the installed Vite version and enforce it in local/CI builds.
10. Add initial frontend E2E harness and critical payroll smoke tests.
11. Verify production TLS, object storage, jobs, mail, backups, monitoring, and MFA.
12. Establish this master plan as the source of truth.

Exit gate:

- no known P0 calculation/status/year defects;
- backend and frontend dependency audits pass at the approved threshold;
- public/operator language does not instruct staff to file the wrong form or authority;
- critical payroll happy path has automated browser coverage;
- production-control checklist is signed off.

Current gate assessment:

| Gate | Status | Evidence / remaining work |
|---|---|---|
| Known P0 calculation/status/year defects | Passed for merged scope | Focused and full regression suites passed; Greptile final review was 5/5 |
| Backend/frontend dependency audits | Passed at merged commit | Enforced by GitHub quality workflow |
| Federal Form 941 and filing-authority language | Passed for active changed surfaces | Backward-compatible route names remain where required |
| Browser smoke infrastructure | Implemented | Public and authenticated smoke paths exist |
| Authenticated production-shaped payroll smoke | Open | No permanent staging environment exists; use a temporary isolated Neon branch or equivalent production-shaped validation environment |
| Production configuration/readiness command | Implemented | Must be run with actual production configuration and evidence retained |
| Backup/restore, MFA, R2, mail, monitoring, and operational checklist | Open | Requires manual release-owner signoff in the production-readiness checklist |
| General pay-component taxability matrix | Partial | Stored committed bases/rule snapshots are delivered; the reusable effective-dated component matrix remains Phase 1 work |

### Phase 1: payroll operational parity

**Goal:** Replace QuickBooks for day-to-day payroll operations, not only calculations.

Deliverables:

1. General pay-run types: regular, off-cycle, bonus, commission, correction, final, and adjustment.
2. Pay-component taxability and GL-mapping model.
3. Payroll liability ledger.
4. Payment methods: printed check first, then NACHA/direct deposit if approved.
5. PTO/sick policies, accruals, usage, balances, and reports.
6. Garnishment case, priority, limit, deduction, remittance, and evidence workflow.
7. Employer contribution and benefit configuration.
8. Locations/worksites and optional job/class costing.
9. Employee onboarding completeness and new-hire/termination reporting views.
10. Paystub delivery and controlled employee self-service.
11. Expanded payroll anomaly detection and previous-period comparisons.
12. QuickBooks-equivalent report catalog and customizable filters/exports.
13. Guam wage-and-hour diagnostics for minimum wage, regular-rate overtime, workweek completeness, pay timing, final pay, and meal-period exceptions.

Exit gate:

- representative hourly, salary, tipped, multi-rate, contractor, and correction clients complete at least three parallel payroll cycles;
- gross, taxes, deductions, employer taxes, net, checks, and reports reconcile to the authoritative comparison source;
- every committed payroll has a complete calculation and approval snapshot;
- no regular payroll operation requires QuickBooks.

### Phase 2: quarterly compliance completion

**Goal:** Move from quarterly preparation workpapers to a controlled filing-ready and evidence-backed workflow.

Deliverables:

1. Company compliance profile and obligation applicability.
2. Form 500 liability/payment ledger and reconciliation.
3. Guam W-1 filing workspace with complete payment tie-out.
4. SWICA/SW-2 validation and accepted upload format for known client types.
5. Federal Form 941 completion, including deposits, adjustments, credits, balance, signer, and preparer data.
6. Authoritative deposit schedule, lookback support, next-day rule, and Schedule B logic.
7. Legal due-date and emergency-extension engine.
8. Filing task attachments and immutable evidence.
9. W-1, SWICA, Form 941-X, and related correction/amendment workflows.
10. Submission and acknowledgment statuses, even where filing remains a manual portal upload.
11. Quarter-close reconciliation report across payroll, deposits, returns, and evidence.
12. A documented third-party-payer model: determine whether Cornerstone acts as a payroll service provider, Form 8655 reporting agent, section 3504 agent, or preparer for each client and obligation; store authorization scope/effective dates; preserve the employer-liability disclosure and quarterly statement where applicable; and ensure the employer can independently monitor EFTPS deposits.

Exit gate:

- one known client quarter is prepared entirely in Cornerstone;
- W-1 and SWICA outputs are validated against GuamTax requirements;
- Form 941 and Schedule B are reviewed against official instructions;
- payment totals tie to return totals;
- submission confirmations and actual proof documents are stored;
- correction procedures are documented and tested.

### Phase 3: annual compliance completion

**Goal:** Complete year-end payroll reconciliation, employee/contractor forms, electronic files, delivery, and corrections.

Deliverables:

1. Formal year-end close, freeze, reopen, and correction workflow.
2. Four-quarter Form 941 reconciliation to W-2GU/W-3SS totals.
3. W-1/Guam withholding reconciliation to W-2GU Box 2.
4. 2026 W-2GU codes `TP` and `TT`, Box 14b, and year-versioned mappings.
5. W-3SS totals and EFW2 ASCII generation.
6. GuamTax payroll-processor, multiple-company, and multiple-location records.
7. W-2GU employee delivery and proof.
8. W-2c/W-3c and Guam corrected-filing workflow.
9. Year-versioned 1099-NEC and applicable 1099-MISC preparation.
10. 1096/GuamTax upload, confirmation, and correction workflow.
11. Conditional obligation assessment for Form 8027, ACA forms, Form 944, and other employer filings.
12. Annual filing dashboard with blocked/ready/filed/accepted/corrected status.

Exit gate:

- a complete known-client year passes payroll-to-quarter-to-annual reconciliation;
- EFW2 passes local validation and a controlled GuamTax test/upload process;
- all forms use the correct year's schema and thresholds;
- employee/contractor delivery and filing evidence are retained;
- correction workflows are proven before the original filing is considered complete.

### Phase 4: QuickBooks exit and payroll accounting bridge

**Goal:** Remove QuickBooks as the payroll archive and create the accounting connection clients still require.

Deliverables:

1. QuickBooks usage inventory for every Cornerstone payroll client.
2. Representative export bundles from each QuickBooks product/version in use.
3. Dedicated historical snapshot-import batches.
4. Source-file checksums, mappings, provenance, validation, and idempotency.
5. Locked imported payroll facts that are never recalculated under current rules.
6. Employee/paycheck/period/quarter/year reconciliation reports.
7. Historical check, correction, and void lineage.
8. Payroll GL account mapping by company/pay component.
9. Balanced payroll journal export.
10. Check/payment clearing and bank-reconciliation support.
11. Cutover checklist and retained QuickBooks read-only/archive plan.

Exit gate:

- every in-scope historical client period reconciles to the QuickBooks source bundle;
- imported history is visible in employee, check, quarterly, and annual reports;
- current payroll journals can be exported to the client's accounting system;
- Cornerstone can answer payroll audit questions without reopening QuickBooks;
- QuickBooks access is retired only after documented signoff.

Existing detailed reference: [QuickBooks Historical Import Plan](QB_HISTORICAL_IMPORT_PLAN.md)

### Phase 5: scale and operational maturity

**Goal:** Safely support more clients, more operators, and filing deadlines.

Deliverables:

- enforced MFA and least-privilege roles;
- permission matrix and separation of preparer/reviewer/approver/committer roles;
- durable object storage and background jobs;
- job retries, idempotency, and dead-letter handling;
- monitoring, alerting, error tracking, and audit exports;
- backup/restore and disaster-recovery drills;
- retention and secure-deletion policies;
- Written Information Security Plan and incident-response plan;
- regulatory change intake, review, approval, and release process;
- operational dashboards and overdue/escalation queues;
- support tooling and client-facing status communication.

### Phase 6: optional full accounting parity

This phase requires a separate approved product brief. It should begin only if Cornerstone confirms that payroll exports and reconciliation are insufficient.

Minimum accounting kernel:

- chart of accounts;
- immutable balanced journals;
- posting periods and close locks;
- AR/AP and customer/vendor ledgers;
- bank feeds/import and reconciliation;
- trial balance and core financial statements;
- accountant adjustments and reversals;
- opening-balance and QuickBooks accounting migration.

Inventory, fixed assets, purchasing, projects, and advanced accounting follow only when actual client requirements justify them.

### Deferred phase: individual and business income-tax return preparation

This is explicitly not a near-term priority. When revisited, it needs a separate program covering Guam residency, taxpayer/household/entity data, forms calculations, diagnostics, signatures, preparer requirements, MeF schemas, ATS approval, submissions, acknowledgments, rejections, and amendments.

No payroll or compliance phase should be delayed to begin this work.

---

## 8. Testing and validation strategy

### 8.1 Calculation tests

- Official IRS Publication 15-T vectors.
- Every pay frequency and filing-status mapping.
- W-4 2020+ Step 2/3/4 combinations.
- Legacy W-4 handling where supported.
- Social Security cap boundary crossing.
- Additional Medicare threshold crossing.
- Rounding at employee, pay-period, quarter, and year levels.
- Tips, service charges, qualified tips, and qualified overtime.
- Pre-tax/post-tax/non-taxable component matrices.
- Void/correction/replacement/supplemental invariants.

### 8.2 Reconciliation invariants

Every committed pay period must satisfy:

```text
gross pay
  - employee taxes
  - employee deductions
  = net pay
```

Each quarter must satisfy:

```text
payroll liabilities
  = deposit/payment ledger
  + remaining payable/refund/adjustment
```

Each year must satisfy:

```text
four quarters
  = annual wage/tax forms
  + documented valid reconciliation differences
```

### 8.3 Artifact tests

- PDF field placement against current official templates.
- Required fields and prohibited values.
- EFW2 fixed-width record lengths and totals.
- SWICA fixed-width/header/trailer/location validation.
- CSV/XLSX column contracts.
- Checks and pay stubs at supported printer profiles.
- Form-year/template mismatch detection.

### 8.4 Browser workflow tests

At minimum:

1. create/import payroll;
2. calculate and resolve blockers;
3. compare and approve;
4. commit and print/download;
5. correct/void/replace;
6. prepare quarterly packet;
7. record payments and evidence;
8. mark filing-ready, filed, accepted, or rejected;
9. prepare annual forms;
10. verify client/employee access restrictions.

### 8.5 Parallel validation

QuickBooks or the currently accepted Cornerstone process remains authoritative during a client's parallel period. Differences must be classified as:

- Cornerstone defect;
- QuickBooks/source defect;
- setup difference;
- timing difference;
- rounding difference;
- intentional policy difference;
- unsupported scenario.

No unexplained difference is acceptable at cutover.

---

## 9. User experience requirements

The system must work for both technical and nontechnical operators.

### 9.1 Every compliance workspace should show

- what is due;
- why it is due;
- the authoritative period basis;
- the legal due date;
- Cornerstone's internal target date;
- source payrolls and payments;
- reconciliation status;
- blocking issues;
- who prepared, reviewed, approved, and filed;
- actual proof and acknowledgment;
- correction history.

### 9.2 Status language

Use precise statuses:

```text
not started
in progress
needs information
needs review
blocked
ready to file
filed - awaiting confirmation
accepted
rejected
corrected/amended
```

Avoid a single "complete" checkbox for filing work.

### 9.3 Progressive disclosure

Nontechnical users should see plain-language tasks and blockers. Professional users should be able to expand the same record into line-level calculations, source data, rules, and audit evidence.

### 9.4 Preview and download

Reports and forms should follow one consistent pattern:

- **View** opens the canonical in-app preview.
- **Download** exports from that preview/workspace.
- Format choices appear inside the preview when more than one format exists.
- Filing status and caveats are visible before download.

---

## 10. Regulatory operations process

Compliance cannot depend on developers remembering annual changes.

Required yearly and mid-year process:

1. Identify official IRS, SSA, Guam DRT, and Guam DOL changes.
2. Record the source document, publication date, effective date, and checksum.
3. Have a payroll/tax professional interpret the change.
4. Implement a versioned rule or schema.
5. Add official test cases and boundary tests.
6. Obtain preparer and reviewer approval.
7. Run regression and sample-client comparisons.
8. Activate on the effective date.
9. Preserve the prior rule for historical payroll and corrections.
10. Publish an operator-facing change note.

The software must block unsupported tax years/forms rather than silently falling back.

---

## 11. First implementation backlog

| Ticket | Status on 2026-07-12 | Scope |
|---|---|---|
| **CPR-MP-001** | Delivered in PR #111 | Correct tax-year/effective-rule selection and snapshot rule IDs on committed payroll |
| **CPR-MP-002** | Delivered in PR #111 | Normalize filing statuses and add W-4 version/effective-date handling |
| **CPR-MP-003** | Delivered in PR #111 | Add year-versioned information-return thresholds and 2026 1099-NEC behavior |
| **CPR-MP-004** | Delivered in PR #111 | Rename user-facing 941-GU language and correct filing authority/documentation |
| **CPR-MP-005** | Delivered in PR #111 | Remediate dependency advisories and add CI audit gates |
| **CPR-MP-006** | Delivered foundation; operational smoke open | Pin supported Node, add Playwright infrastructure and authenticated payroll smoke path |
| **CPR-MP-007** | Implementation candidate in Phase 1A | Stored FIT/SS/Medicare bases remain authoritative; effective-dated component classifications and commit-time snapshots added without changing calculation formulas |
| **CPR-MP-008** | Delivered foundation in PR #111 | Cash-tip, service-charge, tipped-occupation, and qualified-overtime facts and 2026 reporting foundations |
| **CPR-MP-009** | Liability posting candidate in Phase 1A; payment settlement remains | Immutable commit/reversal/replacement ledger, reconciliation API/UI, and explicit historical backfill; payment/allocation/evidence follows in the next bounded PR |
| **CPR-MP-010** | Planned | Company compliance profile and authoritative federal deposit schedule |
| **CPR-MP-011** | Planned | Complete Federal Form 941 lines, official overlay, signer/preparer, and readiness blockers |
| **CPR-MP-012** | Planned | Actual compliance evidence attachments and submission statuses |
| **CPR-MP-013** | Planned | Validate and complete SWICA/W-1 known-client workflow |
| **CPR-MP-014** | Partial foundation only | 2026 W-2GU data/mappings foundation delivered; annual reconciliation remains |
| **CPR-MP-015** | Planned | EFW2/W-3SS export and GuamTax validation harness |
| **CPR-MP-016** | Planned | Versioned Guam wage-and-hour diagnostics and final-pay/workweek review blockers |
| **CPR-MP-017** | Planned | Third-party-payer roles, Form 8655 authorization, employer disclosures, and EFTPS verification |

The next payroll/compliance implementation batch should begin with the remaining portion of `CPR-MP-007` and `CPR-MP-009`, then continue through quarterly compliance. Broad income-tax preparation remains deferred. The bounded Invoice/AR workstream may proceed without beginning the full accounting kernel; see the [Invoice Maker plan](INVOICE_MAKER_AUDIT_AND_IMPLEMENTATION_PLAN_2026-07-12.md).

---

## 12. Required Cornerstone discovery sessions

### 12.1 QuickBooks use inventory

For every client or client type, document whether QuickBooks is used for:

- payroll only;
- payroll checks;
- payroll liability checks;
- payroll reports;
- employee history;
- general ledger posting;
- bank reconciliation;
- bills/AP;
- invoices/AR;
- financial statements;
- classes, locations, or job costing;
- document archive.

This determines whether Level A or Level B parity is actually required.

### 12.2 Filing responsibility inventory

For each obligation, identify:

- who prepares it;
- who reviews it;
- who signs/authorizes it;
- who submits it;
- which account/portal is used;
- what evidence is retained;
- how corrections are handled;
- whether Cornerstone is acting as payroll processor, reporting agent, or preparer.
- whether a Form 8655, Form 2848, section 3504 appointment, GuamTax authorization, or other authority is required and current;
- what the employer can independently verify in EFTPS or the relevant Guam portal.

### 12.3 Representative client matrix

Choose pilot clients covering:

- simple hourly payroll;
- salary payroll;
- restaurant/tipped payroll;
- multi-rate payroll;
- contractor payments;
- loans/garnishments/retirement;
- a client near or above 50 FTEs;
- multiple locations;
- a high-liability/semiweekly depositor;
- a client with corrections or historical complexity.

### 12.4 Source artifacts to collect

- QuickBooks payroll reports and export bundles;
- filed W-1, SWICA, Form 941, Schedule B, W-2GU/W-3SS, and 1099 examples;
- Form 500 and federal deposit confirmations;
- GuamTax accepted-upload examples;
- rejected/corrected filing examples;
- pay-component setup sheets;
- check stock and bank reconciliation examples;
- employee W-4/W-9 source documents;
- year-end reconciliation workpapers.

Use redacted copies where possible, but preserve field and format fidelity.

---

## 13. Program-level completion criteria

Cornerstone can claim **QuickBooks payroll replacement** only when:

- all normal payroll run types are supported;
- calculations are versioned, certified, and reproducible;
- checks/direct deposit and paystub delivery are operational;
- payroll reports cover Cornerstone's actual QuickBooks report use;
- quarterly and annual workflows are evidence-backed;
- known-client filing formats have been validated;
- corrections and amendments are supported;
- historical payroll is imported and reconciled;
- payroll accounting entries can reach the client's books;
- parallel-run cutover gates are passed;
- security and operational controls are approved.

Cornerstone can claim **filing support** only for a form and year when:

- applicability is determined;
- the correct official form/schema version is used;
- all required data is present;
- calculations and reconciliations pass;
- professional review is recorded;
- submission method is documented;
- confirmation/acknowledgment is stored;
- correction handling is defined.

Cornerstone should not claim **full QuickBooks accounting replacement** until the Level B accounting kernel and financial-statement reconciliation gates are separately completed.

---

## 14. Authoritative external references

Use current-year official sources during implementation. This list is a starting point, not a substitute for annual review.

- [IRS Publication 15-T, Federal Income Tax Withholding Methods](https://www.irs.gov/publications/p15t)
- [IRS Publication 15, Employer's Tax Guide](https://www.irs.gov/publications/p15)
- [IRS Instructions for Form 941](https://www.irs.gov/instructions/i941)
- [IRS General Instructions for Forms W-2 and W-3](https://www.irs.gov/instructions/iw2w3)
- [IRS Publication 1099](https://www.irs.gov/publications/p1099)
- [IRS Form 8027 instructions](https://www.irs.gov/instructions/i8027)
- [IRS Forms 1094-C/1095-C instructions](https://www.irs.gov/instructions/i109495c)
- [SSA EFW2/EFW2C specifications](https://www.ssa.gov/employer/EFW2%26EFW2C.htm)
- [GuamTax business e-services](https://www.guamtax.com/)
- [GuamTax tax calendar](https://www.guamtax.com/info/calendar.html)
- [GuamTax SWICA help](https://www.guamtax.com/help/help_swica.html)
- [GuamTax W-1 help](https://www.guamtax.com/help/help_w1.html)
- [GuamTax W-3/W-2GU help](https://www.guamtax.com/help/help_w2w3.html)
- [Guam DOL Wage and Hour guidance](https://dol.guam.gov/compliance/whd/frequently-asked-questions/)
- [IRS third-party payroll service provider and reporting-agent guidance](https://www.irs.gov/government-entities/third-party-payer-arrangements-payroll-service-providers-and-reporting-agents)
- [QuickBooks payroll report catalog](https://quickbooks.intuit.com/learn-support/en-us/help-article/payroll-reports/run-payroll-reports/L13oTu2Ps_US_en_US)
- [QuickBooks payroll accounting export workflow](https://quickbooks.intuit.com/learn-support/en-us/help-article/accounting-bookkeeping/export-payroll-data-quickbooks/L2gk8sbzd_US_en_US)
- [QuickBooks Workforce employee pay-stub and W-2 access](https://quickbooks.intuit.com/learn-support/en-us/help-article/form-w-2/invite-employees-quickbooks-workforce-see-pay-w-2s/L2kUDcEJs_US_en_US)

---

## 15. Relationship to existing repository documents

This document governs priority and release readiness. Use the following documents for deeper historical or operational detail:

- [PRD](../PRD.md) — original product problem and architecture decisions; some implementation details are now stale.
- [QuickBooks Parity Checklist](QB_PARITY_CHECKLIST.md) — useful inventory, but older "Done" labels do not mean filing-complete.
- [QuickBooks Historical Import Plan](QB_HISTORICAL_IMPORT_PLAN.md) — detailed historical migration design.
- [Quarterly Return Implementation Status](QUARTERLY_RETURN_IMPLEMENTATION_STATUS_2026-05-18.md) — current quarterly implementation notes.
- [Quarterly Payroll Workflow Review](QUARTERLY_PAYROLL_TAX_WORKFLOW_FIRM_REVIEW_2026-04-29.md) — detailed Guam/federal workflow reasoning.
- [Client Rollout Plan](CLIENT_ROLLOUT_PLAN.md) — parallel-run and cutover process.
- [Rollout Runbooks](rollout/README.md) — operational templates that must be updated as this plan's corrections are implemented.
- [Runbook](RUNBOOK.md) — operational reference; review dates and form naming before each filing cycle.
- [Invoice Maker Audit and Implementation Plan](INVOICE_MAKER_AUDIT_AND_IMPLEMENTATION_PLAN_2026-07-12.md) — current source of truth for invoice integrity, accounts receivable, document templates, delivery, payments, and AI boundaries.
- [Tools Expansion Plan](TOOLS_INVOICE_AND_GENERAL_TRANSMITTAL_PLAN_2026-05-02.md) — historical implementation plan for the original native Invoice Maker and General Transmittal build; the dedicated Invoice Maker plan now governs future invoice work.

---

## 16. Immediate next action

Do not begin with a broad accounting build or income-tax preparation.

Phase 0 engineering is merged. The immediate program is now:

1. close Phase 0 operational evidence with an isolated production-shaped database validation, verified backup/restore path, actual production-readiness command, and checklist signoff;
2. complete the generalized pay-component taxability design left in `CPR-MP-007`;
3. begin `CPR-MP-009`, the payroll liability/deposit ledger that quarterly reconciliation depends on;
4. collect real QuickBooks and filed-compliance artifacts through the discovery sessions;
5. continue Phase 1 daily payroll parity and Phase 2 quarterly filing readiness;
6. implement Invoice Phase IM-0 as a bounded integrity workstream if Invoice Maker is the next selected product task;
7. complete annual compliance, historical QuickBooks exit, and accounting exports before considering the full accounting kernel.

That sequence acknowledges the Phase 0 progress already merged while preserving payroll/compliance as the primary product commitment.
