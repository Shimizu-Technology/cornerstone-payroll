# Full Payroll Service Parity Plan

**Goal:** Make Cornerstone Payroll capable of fully replacing QuickBooks for end-to-end
payroll processing — from receiving client source documents through generating all
deliverables that go back to the client.

**Scope:** General-purpose (not MoSa-specific). Every feature below should work for any
payroll client.

**Current state:** The app handles the **input** side well (Revel PDF parsing, tip/loan
Excel parsing, import workflow). The **output** side — the reports, checks, and documents
Cornerstone delivers back to clients — has significant gaps.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current Capabilities](#2-current-capabilities)
3. [Gap Analysis](#3-gap-analysis)
4. [Phase 1 — Data Model Enhancements](#4-phase-1--data-model-enhancements)
5. [Phase 2 — Payroll Calculation Integration](#5-phase-2--payroll-calculation-integration)
6. [Phase 3 — Report Generators](#6-phase-3--report-generators)
7. [Phase 4 — Non-Employee Checks & Transmittal](#7-phase-4--non-employee-checks--transmittal)
8. [Phase 5 — Loan Balance Tracking](#8-phase-5--loan-balance-tracking)
9. [Phase 6 — UI Integration](#9-phase-6--ui-integration)
10. [Priority & Sequencing](#10-priority--sequencing)
11. [Data Model Diagrams](#11-data-model-diagrams)

---

## 1. Executive Summary

When Cornerstone processes payroll for a client like MoSa's, the workflow is:

```
CLIENT SENDS                    CORNERSTONE PROCESSES              CORNERSTONE RETURNS
─────────────                   ──────────────────────             ───────────────────
1. Revel POS PDF (hours)   ──>  Import, match employees,     ──>  1. Payroll Checks (check-stock)
2. Tips/Loans Excel        ──>  calculate taxes & deductions  ──>  2. Other Checks (contractor, taxes, etc.)
                                                               ──>  3. Payroll Summary by Employee
                                                               ──>  4. Deductions & Contributions Report
                                                               ──>  5. Paycheck History
                                                               ──>  6. Retirement Plans Report
                                                               ──>  7. Employee Installment Loan Report
                                                               ──>  8. Transmittal Log (cover document)
```

The input side (left) is **fully built**. The output side (right) is where the gaps are.

### What's Built vs. What's Missing

| Deliverable | Status | Blocking Issue |
|-------------|--------|----------------|
| Payroll Checks (check-stock) | **Built** | — |
| Other Checks (contractor, tax deposit, child support) | **Not built** | No non-employee check model |
| Payroll Summary by Employee | **Not built** | Needs itemized deduction line items per payroll item |
| Deductions & Contributions Report | **Not built** | Same as above |
| Paycheck History | **Partial** | JSON endpoint exists; needs PDF generator |
| Retirement Plans Report | **Not built** | Needs employer match tracking at item level |
| Employee Installment Loan Report | **Not built** | No loan balance tracking model |
| Transmittal Log | **Not built** | Needs non-employee checks + report metadata |

---

## 2. Current Capabilities

### 2.1 Input Pipeline (Complete)

- **RevelPdfParser** — Parses Revel POS PDF for hours, overtime, gross pay per employee
- **LoanTipExcelParser** — Parses tips (BOH/FOH) and loans (regular + installment) from Excel
- **NameMatcher** — Fuzzy-matches PDF/Excel names to Employee records
- **ImportService** — Preview + apply workflow with name matching and tax calculation
- **ImportModal** (frontend) — Upload, preview, exclude/include employees, apply

### 2.2 Calculation Engine (Complete)

- **PayrollCalculator** / **HourlyPayrollCalculator** / **SalaryPayrollCalculator**
- **GuamTaxCalculatorV2** — Federal/Guam income tax (IRS Pub 15-T annualized method)
- Social Security (6.2%, wage base aware), Medicare (1.45% + 0.9% Additional Medicare)
- Retirement (pre-tax 401k, Roth), loan deductions, insurance

### 2.3 Check Printing (Complete)

- **CheckGenerator** — 3-part layout for pre-printed check stock (top/bottom)
- Stubs with earnings + deductions breakdown
- Check face with amount-in-words, bank info, signature line
- Alignment test, per-company offsets, batch PDF
- Void/reprint with check events audit trail

### 2.4 Reports (Partial)

| Report | PDF | CSV | JSON |
|--------|-----|-----|------|
| Payroll Register | Yes | Yes | Yes |
| Tax Summary | Yes | Yes | Yes |
| YTD Summary | — | — | Yes |
| Form 941-GU | — | — | Yes |
| W-2 GU | Yes | Yes | Yes |
| Employee Pay History | — | — | Yes |
| Pay Stub | Yes | — | — |

### 2.5 Existing Data Model (Key Tables)

The app already has **deduction_types** and **employee_deductions** tables that define
per-employee deduction rules. These aren't currently connected to the payroll item
calculation output — that's the core gap.

```
deduction_types:   id, company_id, name, category (pre_tax/post_tax), default_amount, is_percentage
employee_deductions: id, employee_id, deduction_type_id, amount, is_percentage, active
```

The `payroll_items` table has aggregate fields (`loan_deduction`, `retirement_payment`,
`insurance_payment`, etc.) but no **itemized breakdown** of which deduction types
contributed to those totals.

---

## 3. Gap Analysis

### 3.1 Missing: Itemized Deduction Line Items per Payroll Item

**The core problem:** When calculating payroll, the app computes aggregate totals
(e.g., `loan_deduction = $375`) but doesn't record *which* deductions made up that total.
Without this, we can't generate the Payroll Summary by Employee or Deductions &
Contributions Report, which show every individual deduction by name.

**Example from QuickBooks output for one employee (Douglas Phillip):**
```
After-tax deductions:
  Health Insurance ............... -$112.50
  Allotment (Douglas Phillip) ... -$482.08
  Loan .......................... -$215.90
  Total ......................... -$810.48
```

The app currently stores this as a single `loan_deduction: 697.98` — the detail is lost.

**Solution:** A `payroll_item_deductions` join table that records each applied deduction
line item per payroll item.

### 3.2 Missing: Earnings Categories / Wage Types

QuickBooks shows earnings broken down by location/role:
```
Hours:  Joint: 76.16h
Gross:  Joint: $913.92, Paycheck Tips: $462.94
```

The app currently only tracks total `hours_worked` and `gross_pay` — no breakdown by
wage type or location.

**Solution:** A `payroll_item_earnings` table or JSONB field to store categorized earnings.

### 3.3 Missing: Employer Contribution Detail

QuickBooks shows employer contributions at the item level:
```
Employer taxes:        SS: $85.36, Medicare: $19.96
Employer contributions: 401(k) Pre-Tax: $0.00
```

The app tracks `employer_social_security_tax` and `employer_medicare_tax` on PayrollItem,
but not employer 401k match.

**Solution:** Add `employer_retirement_match` (and optionally `employer_roth_match`) to
PayrollItem, or include in the `payroll_item_deductions` table with an `employer` flag.

### 3.4 Missing: Non-Employee Checks

Every pay period, Cornerstone writes checks that aren't for employees:

| Check | Payable To | Purpose |
|-------|-----------|---------|
| Contractor check | Brandon Mariano | Independent contractor pay |
| Child support | Treasurer of Guam | Court-ordered garnishment remittance |
| FIT deposit | Treasurer of Guam | Quarterly tax withholding deposit |
| CPA fee | Dafne M. Shimizu CPA | Payroll processing fee reimbursement |

These need a separate model since they don't correspond to a PayrollItem.

### 3.5 Missing: Loan Balance Tracking

The Installment Loan Report tracks loan lifecycles:
```
Date        Beginning   Additions   Payments   Ending
10/9/2025   $0.00       $400.00     ($50.00)   $350.00
10/23/2025  $350.00                 ($50.00)   $300.00
11/6/2025   $300.00                 ($50.00)   $250.00
```

The app has no model for tracking loan balances over time — it only records the per-period
deduction amount. We need an `employee_loans` table with balance tracking.

---

## 4. Phase 1 — Data Model Enhancements

### 4.1 New Table: `payroll_item_deductions`

Records each individual deduction applied to a payroll item.

```ruby
create_table :payroll_item_deductions do |t|
  t.references :payroll_item, null: false, foreign_key: true
  t.references :deduction_type, null: false, foreign_key: true
  t.decimal :amount, precision: 10, scale: 2, null: false
  t.string :category, null: false  # "pre_tax", "post_tax", "employer_contribution"
  t.string :label, null: false     # Display name (e.g., "Loan (Nena Joe)")
  t.timestamps
end

add_index :payroll_item_deductions, [:payroll_item_id, :deduction_type_id], unique: true
```

### 4.2 New Table: `payroll_item_earnings`

Records categorized earnings (wage types, locations, bonuses, tips, reimbursements).

```ruby
create_table :payroll_item_earnings do |t|
  t.references :payroll_item, null: false, foreign_key: true
  t.string :category, null: false       # "regular", "overtime", "bonus", "tips",
                                         # "vacation", "retro", "reimbursement", "other"
  t.string :label, null: false           # Display name (e.g., "Joint Kitchen", "Paycheck Tips")
  t.decimal :hours, precision: 8, scale: 2, default: 0.0
  t.decimal :rate, precision: 12, scale: 6
  t.decimal :amount, precision: 10, scale: 2, null: false
  t.timestamps
end

add_index :payroll_item_earnings, [:payroll_item_id, :category, :label], unique: true
```

### 4.3 New Table: `non_employee_checks`

Checks written to third parties (contractors, government agencies, vendors).

```ruby
create_table :non_employee_checks do |t|
  t.references :pay_period, null: false, foreign_key: true
  t.references :company, null: false, foreign_key: true
  t.string :check_number
  t.string :payable_to, null: false
  t.decimal :amount, precision: 10, scale: 2, null: false
  t.string :check_type, null: false    # "contractor", "tax_deposit", "child_support",
                                        # "garnishment", "vendor", "other"
  t.string :memo
  t.string :description               # Detailed description (e.g., "For 58 Hours 10/20-11/02")
  t.string :reference_number           # Case number, remittance ID, etc.
  t.boolean :printed, default: false
  t.datetime :printed_at
  t.boolean :voided, default: false
  t.string :void_reason
  t.datetime :voided_at
  t.timestamps
end

add_index :non_employee_checks, [:company_id, :check_number], unique: true,
          where: "check_number IS NOT NULL"
```

### 4.4 New Table: `employee_loans`

Tracks individual loan accounts with running balances.

```ruby
create_table :employee_loans do |t|
  t.references :employee, null: false, foreign_key: true
  t.references :company, null: false, foreign_key: true
  t.references :deduction_type, foreign_key: true   # Links to the deduction type
  t.string :name, null: false                        # "Auto Loan - Monique Amani"
  t.decimal :original_amount, precision: 10, scale: 2, null: false
  t.decimal :current_balance, precision: 10, scale: 2, null: false, default: 0.0
  t.decimal :payment_amount, precision: 10, scale: 2  # Standard payment per period
  t.date :start_date
  t.date :paid_off_date
  t.string :status, null: false, default: "active"    # "active", "paid_off", "suspended"
  t.text :notes
  t.timestamps
end
```

### 4.5 New Table: `loan_transactions`

Records each payment or addition against a loan.

```ruby
create_table :loan_transactions do |t|
  t.references :employee_loan, null: false, foreign_key: true
  t.references :pay_period, foreign_key: true
  t.references :payroll_item, foreign_key: true
  t.string :transaction_type, null: false   # "payment", "addition", "adjustment"
  t.decimal :amount, precision: 10, scale: 2, null: false
  t.decimal :balance_before, precision: 10, scale: 2, null: false
  t.decimal :balance_after, precision: 10, scale: 2, null: false
  t.date :transaction_date, null: false
  t.text :notes
  t.timestamps
end

add_index :loan_transactions, [:employee_loan_id, :pay_period_id]
```

### 4.6 Enhancements to Existing Tables

```ruby
# Add employer retirement match to payroll_items
add_column :payroll_items, :employer_retirement_match, :decimal,
           precision: 10, scale: 2, default: 0.0
add_column :payroll_items, :employer_roth_retirement_match, :decimal,
           precision: 10, scale: 2, default: 0.0

# Add employer match rate to employees
add_column :employees, :employer_retirement_match_rate, :decimal,
           precision: 5, scale: 4, default: 0.0
add_column :employees, :employer_roth_match_rate, :decimal,
           precision: 5, scale: 4, default: 0.0

# Expand deduction_types for richer categorization
add_column :deduction_types, :sub_category, :string
# sub_category values: "retirement", "insurance", "garnishment", "loan",
#                      "rent", "phone", "allotment", "reimbursement", "other"
add_column :deduction_types, :payee_name, :string    # Who gets paid (e.g., "Treasurer of Guam")
add_column :deduction_types, :reference_number, :string  # Case number, remittance ID
add_column :deduction_types, :generates_check, :boolean, default: false
# If true, committing a pay period auto-creates a non_employee_check for this deduction
```

### 4.7 Enhancements to Existing: Earnings Types

```ruby
# Add wage-type / location tracking to employees
create_table :employee_wage_rates do |t|
  t.references :employee, null: false, foreign_key: true
  t.string :label, null: false        # "Joint", "Kitchen", "Maintenance"
  t.decimal :rate, precision: 12, scale: 6
  t.boolean :is_primary, default: false
  t.boolean :active, default: true
  t.timestamps
end

add_index :employee_wage_rates, [:employee_id, :label], unique: true
```

---

## 5. Phase 2 — Payroll Calculation Integration

### 5.1 Wire Up `employee_deductions` → `payroll_item_deductions`

When `PayrollCalculator` runs, it should:

1. Load the employee's active `employee_deductions` (with their `deduction_type`)
2. Calculate each deduction amount (fixed or percentage of gross)
3. Create a `PayrollItemDeduction` record for each
4. Sum them into the existing aggregate fields (`loan_deduction`, `retirement_payment`,
   `insurance_payment`, etc.) for backward compatibility

This is the **most important integration** — it unlocks all the detailed reports.

### 5.2 Wire Up Earnings Breakdown

When the import service or manual entry creates payroll items, record categorized
earnings in `payroll_item_earnings`. For Revel imports, the main earnings would be:

- `"regular"` — Regular hours × rate
- `"overtime"` — OT hours × rate × 1.5
- `"tips"` — From Excel tips data (BOH and/or FOH)

For salaried employees, the earnings could include their salary category label.

### 5.3 Wire Up Loan Transactions

When a loan deduction is applied during payroll calculation:

1. Find the employee's active `EmployeeLoan` matching the `DeductionType`
2. Create a `LoanTransaction` (type: "payment") with before/after balances
3. Update `employee_loan.current_balance`
4. If balance reaches zero, mark loan as `paid_off`

### 5.4 Wire Up Non-Employee Checks

When a pay period is committed, auto-generate `NonEmployeeCheck` records for
deductions that have `generates_check: true` on their `DeductionType`. For example:

- Child support deductions → check to Treasurer of Guam
- Garnishments with remittance → check to the garnishment recipient

The tax deposit check (FIT to Treasurer of Guam) and contractor checks are entered
manually or via a separate UI since they aren't derived from employee deductions.

### 5.5 Employer Contributions

During payroll calculation:

- Calculate `employer_retirement_match` = gross × `employer_retirement_match_rate`
- Calculate `employer_roth_retirement_match` = gross × `employer_roth_match_rate`
- Record these as `PayrollItemDeduction` records with `category: "employer_contribution"`

---

## 6. Phase 3 — Report Generators

### 6.1 Payroll Summary by Employee (PDF)

**Priority: HIGH** — This is the most important output document.

The QuickBooks version is a multi-page PDF with one column per employee (typically 5
employees per page-pair), showing:

- Hours by wage type
- Gross earnings by category (regular, OT, bonus, tips, reimbursements, etc.)
- Pre-tax deductions (401k)
- Adjusted gross
- Employee taxes (FIT, SS, Medicare)
- After-tax deductions (every named deduction)
- Net pay
- Employer taxes (SS, Medicare)
- Employer contributions (401k match)
- Total payroll cost

**Data source:** `PayrollItem` + `PayrollItemDeductions` + `PayrollItemEarnings`

**Generator:** `PayrollSummaryByEmployeePdfGenerator` using Prawn (landscape, multi-page)

### 6.2 Deductions & Contributions Report (PDF)

Shows all deductions and employer contributions aggregated across all employees for a
pay period. Typically organized by deduction category.

**Data source:** `PayrollItemDeductions` grouped by `deduction_type`

**Generator:** `DeductionsContributionsReportPdfGenerator`

### 6.3 Paycheck History (PDF)

Shows each paycheck issued in the pay period with check number, employee, gross,
deductions, net, and status.

**Data source:** `PayrollItems` for the pay period

**Generator:** `PaycheckHistoryPdfGenerator`

### 6.4 Retirement Plans Report (PDF)

Shows 401(k) / retirement contributions per employee:

- Employee pre-tax contribution
- Employee Roth (after-tax) contribution
- Employer match (pre-tax)
- Employer match (Roth)
- Catch-up contributions (if applicable)
- Total per employee
- Grand total (this is the "Ascensus upload" amount from the transmittal log)

**Data source:** `PayrollItemDeductions` where `sub_category: "retirement"`

**Generator:** `RetirementPlansReportPdfGenerator`

### 6.5 Employee Installment Loan Report (PDF)

Shows each active loan with its transaction history:

- Employee name and loan name
- Table of: Date, Beginning Balance, Additions, Payments, Ending Balance
- Projected payoff timeline

**Data source:** `EmployeeLoans` + `LoanTransactions`

**Generator:** `InstallmentLoanReportPdfGenerator`

### 6.6 Transmittal Log (PDF or Excel)

Cover document listing everything being delivered to the client:

- Header: CPA name, company name, date, pay day
- Section 1: Payroll checks (count, check range)
- Section 2+: Each non-employee check (payable to, amount, memo, reference)
- Reports section: List of included reports
- Notes section: EFTPS payment amount, 401k upload amount, special instructions

**Data source:** `PayPeriod`, `PayrollItems` (check numbers), `NonEmployeeChecks`,
calculated totals

**Generator:** `TransmittalLogGenerator` (PDF with Prawn, or `.xlsx` with caxlsx)

---

## 7. Phase 4 — Non-Employee Checks & Transmittal

### 7.1 Non-Employee Check Generator

Extend `CheckGenerator` (or create a parallel `NonEmployeeCheckGenerator`) to print
non-employee checks on check-stock paper. Same 3-part format:

- **Stubs:** Payable to, amount, purpose/memo, reference number, pay period
- **Check face:** Same as employee checks but with the third-party payee

### 7.2 Non-Employee Check Management UI

Add a section to the Pay Period Detail page for managing non-employee checks:

- List of non-employee checks for the period
- Add/edit/delete non-employee checks
- Print individual or batch PDF
- Common templates (e.g., "Tax Deposit — Treasurer of Guam" auto-fills payee/memo)

### 7.3 Auto-Generated Non-Employee Checks

When a pay period is committed, automatically generate non-employee checks for:

- **Child support / garnishments:** Sum garnishment deductions across employees,
  group by payee + case number
- **Tax deposit (FIT):** Total `withholding_tax` across all employees → check to
  Treasurer of Guam
- **EFTPS (SS + Medicare):** Total employee + employer SS + Medicare → EFTPS payment
  (this may not be a check but an electronic payment — include on transmittal log only)

Contractor checks and other ad-hoc checks are added manually.

---

## 8. Phase 5 — Loan Balance Tracking

### 8.1 Loan Management UI

Add a Loans section (accessible from Employee detail or as a standalone page):

- List all loans for an employee with current balance and status
- Create new loan (name, original amount, payment amount, start date)
- Add additions to existing loans
- View transaction history
- Manually adjust balance if needed

### 8.2 Loan Integration with Payroll

During payroll calculation, for each employee:

1. Look up active loans linked to deduction types
2. Calculate payment amount (from `employee_loan.payment_amount` or `employee_deduction.amount`)
3. Create loan transaction with balance tracking
4. Include in `payroll_item_deductions`

### 8.3 Loan Report Generation

After commit, generate the Installment Loan Report PDF showing all active loans
with their full history.

---

## 9. Phase 6 — UI Integration

### 9.1 Pay Period Detail Page Enhancements

- **Non-employee checks section** — Manage third-party checks
- **Reports download panel** — One-click generation of all deliverable documents
- **Print all button** — Generate complete print package:
  - Employee payroll checks (batch PDF for check stock)
  - Non-employee checks (batch PDF for check stock)
  - All reports (regular paper, combined PDF or individual)

### 9.2 Reports Page Enhancements

Add new report types to the Reports page:

- Payroll Summary by Employee
- Deductions & Contributions
- Paycheck History
- Retirement Plans
- Installment Loan Report

### 9.3 Employee Detail Enhancements

- **Deductions tab** — Manage employee's deduction types and amounts (UI for
  `employee_deductions` — may already exist)
- **Loans tab** — View and manage employee loans with balance tracking
- **Wage rates tab** — Manage employee's wage types/locations (if using multi-rate)

### 9.4 Company Settings Enhancements

- **Deduction types management** — Create/edit company-wide deduction types
- **Non-employee payee templates** — Save common payees (Treasurer of Guam, CPA, etc.)
- **Transmittal log settings** — CPA name, default notes, report list

---

## 10. Priority & Sequencing

### Tier 1 — Critical (Required for parity)

| # | Work Item | Estimated Effort | Depends On |
|---|-----------|-----------------|------------|
| 1a | `payroll_item_deductions` table + model | Small | — |
| 1b | Wire `employee_deductions` → `payroll_item_deductions` in calculator | Medium | 1a |
| 1c | Payroll Summary by Employee PDF generator | Large | 1b |
| 1d | Deductions & Contributions Report PDF generator | Medium | 1b |
| 1e | Paycheck History PDF generator | Small | — |
| 1f | Non-employee checks table + model + API | Medium | — |
| 1g | Non-employee check generator (check-stock PDF) | Small | 1f |
| 1h | Transmittal Log generator | Medium | 1f |

### Tier 2 — Important (Required for full workflow)

| # | Work Item | Estimated Effort | Depends On |
|---|-----------|-----------------|------------|
| 2a | `employee_loans` + `loan_transactions` tables | Small | — |
| 2b | Loan balance tracking in calculator | Medium | 2a, 1b |
| 2c | Installment Loan Report PDF generator | Medium | 2a |
| 2d | Retirement Plans Report PDF generator | Small | 1b |
| 2e | Employer retirement match calculation | Small | 1b |
| 2f | Non-employee checks UI (Pay Period Detail) | Medium | 1f |
| 2g | Reports download panel UI | Medium | 1c, 1d, 1e |

### Tier 3 — Nice to Have (Polish & automation)

| # | Work Item | Estimated Effort | Depends On |
|---|-----------|-----------------|------------|
| 3a | `payroll_item_earnings` table (categorized earnings) | Small | — |
| 3b | Earnings breakdown in Payroll Summary report | Medium | 3a, 1c |
| 3c | `employee_wage_rates` (multi-rate employees) | Small | — |
| 3d | Auto-generate non-employee checks on commit | Medium | 1f, 1b |
| 3e | Loan management UI (Employee detail) | Medium | 2a |
| 3f | "Print Package" button (all docs, one click) | Medium | All Tier 1 |
| 3g | Transmittal log as Excel (in addition to PDF) | Small | 1h |

### Recommended Build Order

```
Sprint 1:  1a → 1b → 1e → 1f
Sprint 2:  1c → 1d → 1g → 1h
Sprint 3:  2a → 2b → 2c → 2d → 2e
Sprint 4:  2f → 2g → 3a → 3b
Sprint 5:  3c → 3d → 3e → 3f → 3g
```

---

## 11. Data Model Diagrams

### New Tables (Conceptual)

```
┌──────────────────────┐      ┌──────────────────────────┐
│   deduction_types    │      │    employee_deductions    │
│──────────────────────│      │──────────────────────────│
│ id                   │◄─────│ deduction_type_id        │
│ company_id           │      │ employee_id              │
│ name                 │      │ amount                   │
│ category             │      │ is_percentage            │
│ sub_category (NEW)   │      │ active                   │
│ payee_name (NEW)     │      └──────────────────────────┘
│ reference_number(NEW)│
│ generates_check (NEW)│
└──────────┬───────────┘
           │
           │  (applied during payroll calc)
           ▼
┌──────────────────────────────┐
│   payroll_item_deductions    │  ◄── NEW TABLE
│──────────────────────────────│
│ payroll_item_id              │
│ deduction_type_id            │
│ amount                       │
│ category                     │
│ label                        │
└──────────────────────────────┘

┌──────────────────────────────┐
│   payroll_item_earnings      │  ◄── NEW TABLE
│──────────────────────────────│
│ payroll_item_id              │
│ category                     │
│ label                        │
│ hours                        │
│ rate                         │
│ amount                       │
└──────────────────────────────┘

┌──────────────────────────────┐
│   non_employee_checks        │  ◄── NEW TABLE
│──────────────────────────────│
│ pay_period_id                │
│ company_id                   │
│ check_number                 │
│ payable_to                   │
│ amount                       │
│ check_type                   │
│ memo                         │
│ description                  │
│ reference_number             │
│ printed / voided             │
└──────────────────────────────┘

┌──────────────────────────────┐     ┌──────────────────────────┐
│   employee_loans             │  ◄──│   loan_transactions      │
│──────────────────────────────│     │──────────────────────────│
│ employee_id                  │     │ employee_loan_id         │
│ company_id                   │     │ pay_period_id            │
│ name                         │     │ payroll_item_id          │
│ original_amount              │     │ transaction_type         │
│ current_balance              │     │ amount                   │
│ payment_amount               │     │ balance_before           │
│ start_date                   │     │ balance_after            │
│ paid_off_date                │     │ transaction_date         │
│ status                       │     └──────────────────────────┘
└──────────────────────────────┘

┌──────────────────────────────┐
│   employee_wage_rates        │  ◄── NEW TABLE
│──────────────────────────────│
│ employee_id                  │
│ label                        │
│ rate                         │
│ is_primary                   │
│ active                       │
└──────────────────────────────┘
```

### Relationship to Existing Tables

```
PayPeriod ──has_many──► PayrollItems ──has_many──► PayrollItemDeductions
    │                       │                           │
    │                       ├──has_many──► PayrollItemEarnings
    │                       │
    │                       ├──belongs_to──► Employee ──has_many──► EmployeeDeductions
    │                       │                    │
    │                       │                    ├──has_many──► EmployeeLoans
    │                       │                    │                  │
    │                       │                    │                  └──has_many──► LoanTransactions
    │                       │                    │
    │                       │                    └──has_many──► EmployeeWageRates
    │                       │
    │                       └──belongs_to──► Company ──has_many──► DeductionTypes
    │
    └──has_many──► NonEmployeeChecks
```

---

## Appendix A: QuickBooks Output Document Catalog

For reference, here is the complete list of documents Cornerstone currently produces
via QuickBooks for each pay period:

### Documents Printed on Check Stock

1. **Payroll Checks** — One per employee (check + two stubs)
2. **Other Payroll Checks** — Contractor pay, child support, tax deposit, CPA fee

### Documents Printed on Regular Paper

3. **Payroll Summary by Employee** — Detailed multi-page breakdown (the "big report")
4. **Deductions & Contributions Report** — All deductions/contributions by category
5. **Paycheck History** — Every check issued with numbers and amounts
6. **Retirement Plans Report** — 401(k) contributions per employee
7. **Employee Installment Loan Report** — Loan balances with transaction history

### Cover Document

8. **Transmittal Log** — Lists everything being delivered, check numbers, amounts,
   special instructions (EFTPS, 401k upload, etc.)

### Electronic (Not Printed)

- **EFTPS Payment** — SS + Medicare total for electronic deposit
- **Ascensus 401(k) Upload** — Retirement contribution total for 401k provider

---

## Appendix B: Deduction Categories Observed in QuickBooks

These are all the distinct deduction/contribution types observed in the MoSa Payroll
Summary by Employee report. Each would be a `DeductionType` record:

### Pre-Tax Deductions
- 401(k) Pre-Tax
- 401(k) After Tax (treated as pre-tax in QB setup)

### After-Tax Deductions
- Auto Loan
- Health Insurance
- Child Support (with case number)
- Rent
- Phone
- Allotment (named)
- Generic Loan
- Named Loans (Nena Joe, Charles Phillip, Douglas Phillip, Dennis Doctor, Mayleen, Eithen Hadley)
- 401(k) Catch-up
- Auto Insurance
- Garnishment remittance (with remittance ID)

### Employer Contributions
- Social Security (6.2%)
- Medicare (1.45%)
- 401(k) Pre-Tax match
- 401(k) After Tax match

---

*Document version: 1.0 — Created 2026-02-24*
