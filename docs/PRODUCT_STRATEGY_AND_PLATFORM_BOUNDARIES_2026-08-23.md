# Product strategy and platform boundaries

**Reviewed:** 2026-08-23

**Owners:** Shimizu Technology and Cornerstone Tax Services

**Status:** Current product direction; implementation and commercialization remain subject to Gate 0 and client validation

## Decision

Cornerstone Payroll should become the Guam payroll operating system for accounting firms. It should not try to reproduce every QuickBooks accounting feature before the payroll product is secure, reconcilable, and operationally proven.

The broader commercial product should use one platform experience with separately sellable modules:

| Module | Authoritative for |
| --- | --- |
| Workforce | Punches, schedules, breaks, time approval, leave, and time corrections |
| Payroll | Legal workweek, overtime classification, gross-to-net calculation, deductions, checks, liabilities, and employer compliance |
| Tax Practice | Returns, documents, signatures, tax-office workflow, and client requests |
| Firm Console | Cross-client deadlines, review queues, batch reporting, staff permissions, and firm billing |
| Accounting Bridge | Payroll journal export, check clearing, and reconciliation with an external accounting system |
| Books, only if later justified | Chart of accounts, double-entry ledger, AP/AR, bank reconciliation, close, and financial statements |

The modules should share identity, organization/company concepts, permissions, audit conventions, notifications, and versioned integration contracts. They should not share one unrestricted database or become one large controller/UI surface.

## Why Cornerstone built the product

Cornerstone's working process combined spreadsheets, source exports, manual review, QuickBooks, and staff knowledge. QuickBooks created Guam address and payroll-workflow friction, while the payroll record, check history, compliance preparation, client communication, and evidence lived in different places.

Cornerstone Payroll was built to make that work repeatable:

```text
company and employee setup
  -> hours, tips, and adjustment intake
  -> calculation
  -> review and comparison
  -> approval
  -> commit
  -> checks and pay stubs
  -> quarterly and annual preparation
  -> retained evidence and client access
```

This remains the immediate product. The application is already a substantial payroll and firm-operations system. It is not yet a complete accounting system or an automated filing service.

## Current application boundaries

### Cornerstone Payroll

Payroll currently owns multi-company payroll setup, hourly/salary/contractor calculations, effective-dated employee and work-profile data, pay schedules, run purposes, intake/imports, review/approval/commit, corrections, YTD totals, checks, pay stubs, liability obligations, compliance-preparation reports, client collaboration, transmittals, and limited outgoing receivables.

Invoice Center and General Transmittals are firm-operations features. They do not establish a chart of accounts, posting engine, accounts payable, bank ledger, trial balance, or financial statements.

### AIRE Services

AIRE contains an employer-specific public aviation site and a single-employer workforce system. The workforce portion supports kiosk/mobile clocking, schedules, breaks, categories, approval, corrections, location policy, leave requests, locks, and payroll-oriented reports. It does not calculate taxes or net pay.

The reusable product is the workforce domain, not AIRE's marketing site. It needs tenant ownership, scoped roles, and a versioned payroll contract before it can serve multiple businesses in one deployment.

### Cornerstone Tax

Cornerstone Tax is a tax-practice and office-operations system: intake, returns, fees, signatures, documents, client portal, recurring work, scheduling, and practice time. It is not a payroll engine or accounting ledger.

Tax and AIRE currently contain related but diverging timekeeping implementations. The long-term direction is one Workforce module. Cornerstone Tax should consume Workforce as a tenant rather than maintain a separate legal-time implementation.

## Existing integration

AIRE and Cornerstone Tax expose authenticated time summaries. Payroll pulls those summaries, maps employees, previews issues, stores source evidence, and applies approved hours. Committed payroll can optionally send totals to Cornerstone Tax.

This runtime separation is sound. Gate 0 found that the original contract was not safe enough to call Payroll authoritative for imported overtime:

- the importer uses a hard-coded Sunday workweek instead of the pay period's configured workweek;
- source-provided category regular/overtime splits can override Payroll's calculated split;
- category totals can disagree with day totals and inflate imported hours;
- the configurable workweek start time is not implemented by the date-only allocation model; and
- the connection URL could expose the integration secret through unsafe outbound requests.

The destination boundary was code-closed in PR #127. The workweek, overtime, reconciliation, and versioned-contract changes remain in progress until their PR is merged and `main` is green. The separate Spike email/OCR payroll-intake adapter uses a different, less detailed evidence model and remains tracked as G0-21; the Time Summary contract does not certify it.

## Market categories

The relevant products solve different problems:

| Category | Examples | Core responsibility |
| --- | --- | --- |
| Accounting | QuickBooks Online, Xero, Zoho Books, Sage | Ledger, AR/AP, bank reconciliation, close, and financial statements |
| Payroll/HCM | ADP, Paycom, Gusto, Rippling | Payroll, time, PTO, HR, benefits, and employee/manager self-service |
| Accountant/payroll bureau | ADP Accountant Connect, Gusto Pro, Patriot, Polaris | Multi-client payroll operations, alerts, reports, GL mapping, billing, and firm controls |
| Tax practice | Dedicated practice-management and tax systems | Return workflow, documents, signatures, review, filing evidence, and client requests |

ADP and Paycom are workforce/payroll platforms, not general accounting replacements. Their useful lesson is a shared employee record and direct flow from approved time into payroll. QuickBooks' broader benchmark includes the accounting ledger and accountant practice tools that Cornerstone does not currently have.

Public vendor material changes and does not prove Guam filing coverage. Current product decisions use these sources as market evidence, not certification:

- [QuickBooks Online](https://quickbooks.intuit.com/online/) and [QuickBooks Accountant tools](https://quickbooks.intuit.com/learn-support/en-us/help-article/small-business-processes/use-accountant-tools-features-quickbooks-online/L5rizTAvS_US_en_US)
- [ADP Workforce Now](https://www.adp.com/what-we-offer/products/adp-workforce-now.aspx) and [ADP Accountant Connect](https://www.adp.com/who-we-serve/by-partner/accountants/accountant-connect.aspx)
- [Paycom](https://www.paycom.com/software/) and [Beti](https://www.paycom.com/software/beti/)
- [Gusto](https://gusto.com/product/payroll) and [Gusto Pro](https://gusto.com/partners/accountants/payroll-for-accountants)
- [Rippling](https://www.rippling.com/products)
- [Polaris Payroll](https://polarispayroll.com/polaris-payroll-software/) and local [Finance Integrated Solutions payroll](https://financeintegratedsolutions.com/payroll/)

The previous README statement that no major payroll vendor supports Guam was too absolute. Intuit has publicly said QuickBooks Online Payroll is unavailable in Guam, but ADP publicly lists Guam coverage. Exact calculations, filings, direct deposit, pricing, and accountant-channel service must be confirmed directly with each vendor before Cornerstone uses a competitive claim in sales material.

## Differentiation

The defensible product is not another generic time clock or payroll-entry screen. It is dependable Guam payroll and employer-compliance work across many accounting-firm clients.

That includes W-2GU, W-3SS, Guam withholding, W-1, Form 500, SWICA/SW-2, federal Form 941, corrections, retained submission evidence, and Guam wage-and-hour rules. These workflows must be validated against official instructions and real accepted outputs; source links alone are not certification.

## Product priorities

1. Close Gate 0: access revocation, financial concurrency, safe integrations, client-data boundaries, deterministic tests, effective production configuration, and retained operational evidence.
2. Complete payroll exit: liability settlement, quarterly and annual completion, historical import/reconciliation, GL export, check clearing, and employee delivery.
3. Build the firm console: cross-client deadlines, blocked runs, liabilities, filings, roles, templates, batch reporting, migration, and billing.
4. Productize Workforce: tenant-aware time, schedules, approvals, PTO, employee/manager self-service, and immutable payroll inputs.
5. Add the accounting bridge. Decide on a full accounting kernel only after multiple paying customers prove they need it.

## Packaging direction

- Payroll — company base fee plus active paid workers
- Workforce — separately priced employee add-on
- Payroll + Workforce — bundled price and first-party integration
- Firm — multi-client console, templates, batch work, billing, and co-branding
- Tax Practice — separate practice-operations product

Pricing must account for implementation, migration, Guam compliance support, correction responsibility, and service level. Mainland per-employee prices are reference points, not an automatic ceiling.

## Commercialization prerequisites

Before selling beyond controlled design partners, Cornerstone and Shimizu must decide and document:

- IP ownership and the commercial entity that licenses the software;
- who acts as payroll processor, reporting agent, or filing submitter;
- responsibility for calculation errors, filings, corrections, penalties, and notices;
- data ownership, retention, security, incident response, and subprocessors;
- support hours, service levels, implementation, and migration fees;
- pricing, billing, and revenue share; and
- whether customer isolation uses separate deployments temporarily or a tested multi-tenant platform.

## Full-accounting decision gate

Do not begin a general ledger because the product has invoices or because QuickBooks has one. First inventory every non-payroll QuickBooks task used by Cornerstone and target clients.

Build the accounting kernel only if several paying customers need native books and will fund the scope. If payroll journal export, check clearing, and reconciliation cover the real need, integrate with established accounting products and keep Cornerstone focused on its Guam payroll advantage.
