# CPR-66: Check Printing on Pre-Printed Stock — Implementation Plan

**Ticket:** CPR-66  
**Type:** Feature  
**Author:** Theo (Shimizu Technology)  
**Status:** Draft / Planning  
**Created:** 2026-03-10  
**Target:** MoSa's Restaurant (first rollout), then Cornerstone client roster  

---

## Table of Contents

1. [Current State & Gaps](#1-current-state--gaps)
2. [External Research Findings](#2-external-research-findings)
3. [QuickBooks Parity Requirements](#3-quickbooks-parity-requirements)
4. [Architecture Options](#4-architecture-options)
5. [Recommended Approach](#5-recommended-approach)
6. [Data Model Updates](#6-data-model-updates)
7. [API Design](#7-api-design)
8. [UI / Workflow Design](#8-ui--workflow-design)
9. [Safety Controls](#9-safety-controls)
10. [Acceptance Test Plan](#10-acceptance-test-plan)
11. [Rollout Plan — MoSa's First](#11-rollout-plan--mosas-first)
12. [Risk Register & Mitigations](#12-risk-register--mitigations)
13. [Implementation Checklist](#13-implementation-checklist)

---

## 1. Current State & Gaps

### What Exists Today

| Layer | What's There | Status |
|-------|-------------|--------|
| **DB schema** | `payroll_items.check_number` (string, indexed) | ✅ Field exists |
| **DB schema** | `payroll_items.check_printed_at` (datetime) | ✅ Field exists |
| **API** | `check_number` is permitted param in `PayrollItemsController` | ✅ Writable |
| **API** | `check_number` / `check_printed_at` serialized in `payroll_item_json` | ✅ Readable |
| **PDF generator** | `PayStubGenerator` (Prawn) renders a pay stub; shows `Check #` field | ✅ Exists |
| **Storage** | R2 via `R2StorageService`; stubs stored as `paystubs/{year}/{emp_id}/paystub_{date}.pdf` | ✅ Working |
| **Routes** | `pay_stubs#generate`, `pay_stubs#download`, `pay_stubs#batch_generate` | ✅ Live |
| **Gems** | `prawn` + `prawn-table` in Gemfile | ✅ Present |
| **Frontend** | `PayrollItem` TypeScript type has `check_number?: string` | ✅ Typed |

### Critical Gaps

| Gap | Impact |
|-----|--------|
| ❌ No `CheckGenerator` service — current `PayStubGenerator` outputs a screen-only earnings statement, not a check layout | Cannot print on check stock |
| ❌ No check number auto-sequencing — currently must be entered manually or left blank | Operator error risk, QB parity miss |
| ❌ No `next_check_number` on `Company` model | Can't auto-sequence across pay runs |
| ❌ No void/reprint controls — no `voided` flag on `PayrollItem` | Regulatory gap, audit gap |
| ❌ No duplicate print detection — `check_printed_at` is set but never enforced | Could print same check twice |
| ❌ No alignment calibration UI — PDF has no offset/fine-tune controls | Stock misalignment in production |
| ❌ No batch check print workflow — only single-stub download today | Efficiency gap vs QB |
| ❌ `check_writer` gem not in Gemfile — PRD planned it but it was never added | Amount-in-words missing |
| ❌ No company bank account info on `Company` model (routing/account) | Can't produce a bank-legal check |

### Summary

The foundation is solid: Prawn is wired up, `check_number` + `check_printed_at` fields exist, the R2 storage pipeline works. What's missing is the **check-specific PDF layout** (payee line, amount in words, date on check face, MICR line area), the **sequencing / safety controls**, and the **UI workflow** to manage a batch print run.

---

## 2. External Research Findings

> Sources cited inline. All external content treated as advisory; validate against actual Bank of Guam requirements.

### 2.1 Pre-Printed vs Blank Check Stock

Pre-printed check stock (like Bank of Guam issues to businesses) has the following **already printed** on the physical paper:
- Company name, address
- Bank name and branch
- Account number (in MICR font)
- Routing number (in MICR font)
- Check number (in MICR font, sometimes)
- Security features (microprinting, watermark, void pantograph)

Because the MICR line is pre-printed, **you do NOT need MICR ink or a MICR printer** when using pre-printed stock. Your PDF only needs to print the variable data:
- Payee name and address
- Date
- Dollar amount (numeric)
- Dollar amount (written words)
- Pay period (in memo line)
- Authorized signature (or signature line)

> Source: Medlin Payroll Software docs — "If you are going to use pre-printed check forms, or are paying via direct deposit you do not need MICR."  
> Source: Patriot Software — "Use MICR ink or preprinted stock so banks can read account numbers and avoid processing fees."  
> URL: https://www.patriotsoftware.com/blog/payroll/how-print-payroll-checks/  
> URL: http://medlin.com/-help/payrollonlinehelp/topics/medlin-payroll-software-micr-check-printing.htm

### 2.2 Check Layout Standards

Standard US business check layouts follow one of these configurations:
- **Top check** (check on top, two stubs below) — common for payroll
- **Bottom check** (check on bottom, two stubs above) — what `check_writer` gem supports
- **Middle check** (stub / check / stub) — less common

The physical check portion (the part that gets detached and deposited) must fit within pre-defined boundaries on the stock. Fields that must align precisely:
- Payee name (approx 1 inch from top of check, left side)
- Date (top right)
- Numeric dollar amount (right side, near `$` box)
- Written amount (below payee line — the "pay to the order of" long line)
- Memo / period line (bottom left of check)
- Signature line (bottom right)

> Source: ADP Reddit thread — "Photocopy one of your check stock and use that for alignment."  
> URL: https://www.reddit.com/r/Payroll/comments/1ncmaun/adp_manual_check_pre_printed_check_stock/

### 2.3 Alignment Calibration

Industry practice for aligning PDF output to pre-printed stock:
1. Print a test page on plain white paper
2. Hold it up to the light on top of one sheet of check stock
3. Measure X/Y offset of any misalignment
4. Adjust PDF template coordinates and reprint
5. Repeat until fields land precisely in the correct boxes

Most payroll software exposes per-printer "fine offset" settings (e.g., ±0.1" horizontal, ±0.1" vertical) so each physical printer can be tuned independently.

> Source: halfpricesoft.com ezCheckPrinting — offset adjustment workflow  
> URL: https://www.halfpricesoft.com/business_check_software/check-print-alignment-issue.asp

### 2.4 Void / Reprint Controls

QuickBooks behavior (researched):
- Voiding a check marks it `VOID` in the check register but **does not delete** the record
- A voided check preserves the check number so it can't be re-used accidentally
- Reprinting prompts: "Some checks need reprinting, starting with check #___"
- A reprinted check uses a **new check number** (the old one is voided first)
- All void/reprint operations log to the audit trail

> Source: Vintti QB guide — "void the original check before reprinting to reuse the same check number without duplicates"  
> Source: Method.me QB guide — "Make sure 'Some checks need reprinting, starting with check:' is selected"  
> URL: https://www.vintti.com/blog/how-to-print-quickbooks-checks-step-by-step-process-for-efficient-printing-in-quickbooks  
> URL: https://www.method.me/blog/print-check-in-quickbooks-online/

### 2.5 Compliance & Record Keeping

- IRS requires payroll records kept **minimum 4 years** after tax return due date
- FLSA requires time/wage records kept **3 years**
- Best practice for payroll: **7 years** (covers both + state audit windows)
- Voided check records must be retained as if they were issued
- PDF copies of all issued checks should be stored alongside pay stubs

> Source: Patriot Software — record retention  
> URL: https://www.patriotsoftware.com/blog/payroll/payroll-tax-record-keeping-irs-requirements/

### 2.6 The `check_writer` Ruby Gem

`check_writer` (github.com/rylwin/check_writer) generates PDF checks via Prawn with:
- Amount-to-words conversion (e.g., `$1,218.91` → `"One thousand two hundred eighteen and 91/100"`)
- Bottom-check layout (1/3 page check + 2 stubs)
- MICR line rendering (GnuMICR font) — not needed for pre-printed stock
- Configurable payee, payor, bank info, memo, routing/account numbers

**Caveat:** The gem was last maintained targeting Ruby 1.9.3 and appears unmaintained. It uses Prawn under the hood. Given this, the recommended approach is to **build our own `CheckGenerator` using Prawn directly** (same as `PayStubGenerator`) rather than adding a dependency on an unmaintained gem. We can borrow the amount-to-words logic (MIT licensed) and implement our own layout tuned to Bank of Guam stock dimensions.

> URL: https://github.com/rylwin/check_writer

---

## 3. QuickBooks Parity Requirements

From `QB_PARITY_CHECKLIST.md` and research:

| QB Feature | Our Requirement | Priority |
|-----------|----------------|----------|
| Check register (check # → employee → amount) | List of checks issued per pay period | 🔴 P1 |
| Auto-sequential check numbers | `next_check_number` on Company, auto-assigned on commit | 🔴 P1 |
| Check PDF layout (amount in words, payee, date) | `CheckGenerator` service | 🔴 P1 |
| Batch print (select all checks for a period) | Batch endpoint + UI download | 🔴 P1 |
| Alignment calibration (offset fine-tune) | Per-company offset settings OR fixed layout + phototest | 🟠 P2 |
| Void a check | `voided` flag + reason on `PayrollItem` | 🟠 P2 |
| Reprint (new check # for re-issued check) | Reprint action → void old, assign new # | 🟠 P2 |
| Mark check as printed without printing | `check_printed_at` update via API | 🟠 P2 |
| Checks-only employees (vs direct deposit) | `payment_method` on Employee | 🟠 P2 |
| Bank reconciliation report | List of checks by status (issued/voided/cleared) | 🟡 P3 |
| Electronic deposit stub for DD employees | Existing pay stub PDF covers this | ✅ Already done |

---

## 4. Architecture Options

### Option A: Extend `PayStubGenerator` to Support Both Modes

Add a `:check` mode to `PayStubGenerator`. When `:check` mode is selected, output the check face + stubs in one PDF. Otherwise, output the existing earnings statement.

**Pros:** Minimal new code, same Prawn pipeline  
**Cons:** Two very different layouts in one class violates SRP; harder to maintain and test independently

### Option B: New `CheckGenerator` Service (Recommended)

Create `api/app/services/check_generator.rb` alongside `pay_stub_generator.rb`. Both use Prawn. `CheckGenerator` produces a check-stock-aligned PDF; `PayStubGenerator` remains the earnings statement.

**Pros:** Clean separation, each has its own layout logic and spec, easy to iterate on check layout without breaking pay stubs  
**Cons:** Slightly more files

### Option C: External Check Printing Service (Checkeeper / OnlineCheckWriter)

Use a SaaS API (Checkeeper.com, OnlineCheckWriter.com) to generate and mail checks.

**Pros:** No layout work at all; handles mailing  
**Cons:** Per-check cost ($0.50–$1.50/check), requires sending sensitive employee data to third party, no offline mode, adds external dependency. **Not appropriate** for Cornerstone's use case (they print in-house).

### Option D: `check_writer` Gem

Add `check_writer` gem and configure it.

**Pros:** Amount-to-words and MICR layout ready-made  
**Cons:** Unmaintained (last committed 2014, targets Ruby 1.9.3), bottom-check-only format may not match Bank of Guam stock, MICR not needed for pre-printed stock anyway. **Ruled out.**

**Decision: Option B — new `CheckGenerator` service.**

---

## 5. Recommended Approach

### Core Stack

- **PDF generation:** Prawn (already in Gemfile) — no new gems required
- **Amount in words:** Implement `NumberToWords` helper module (simple Ruby, ~50 lines, MIT-style logic from `check_writer`)
- **Check layout:** Custom, tuned to Bank of Guam pre-printed stock dimensions
- **Storage:** Same R2 pipeline as pay stubs (`checks/{year}/{company_id}/{check_number}.pdf`)
- **Check sequencing:** `next_check_number` integer on `companies` table, auto-incremented on commit with DB-level locking
- **Void/reprint:** Add `voided`, `voided_at`, `voided_by`, `void_reason`, `reprint_of_check_number` to `payroll_items`

### Check PDF Layout (3-part, letter size)

The standard US payroll check layout on letter paper (8.5" × 11"):

```
┌─────────────────────────────────────────────────────┐  ← Page top (0")
│  STUB 1 — Employee copy                             │
│  Earnings / deductions / net pay detail             │  3.67" tall
├─────────────────────────────────────────────────────┤  ← 3.67"
│  STUB 2 — Employer copy (duplicate of stub 1)      │
│  Same earnings detail                               │  3.67" tall
├─────────────────────────────────────────────────────┤  ← 7.33"
│  CHECK — detachable bottom                         │
│  Payee, date, amount (numeric + words), memo,       │  3.67" tall
│  signature line                                     │
└─────────────────────────────────────────────────────┘  ← Page bottom (11")
```

> **Note:** The actual check position (top vs bottom) must be confirmed against the specific Bank of Guam check stock Cornerstone uses. Leon needs to measure one check sheet to confirm whether the check tear-off is at the top or bottom. The layout above assumes bottom-check (most common for pre-printed payroll stock). **This is the primary assumption that must be validated before coding the layout.**

### Check Face Fields

```
[Company Name]                             Check No: [####]
[Company Address]                          Date: [MM/DD/YYYY]

Pay to the order of: [Employee Full Name]  $ [1,234.56]

[One thousand two hundred thirty-four and 56/100 ────────── DOLLARS]

[Bank Name]
[Branch Address]

Memo: Payroll [Period Start] - [Period End]         _________________________
                                                     Authorized Signature
```

### Stubs (upper 2/3 of page)

Same content as today's `PayStubGenerator` output — earnings, deductions, YTD totals. Both stubs are identical (one for employee, one for employer file).

---

## 6. Data Model Updates

### 6.1 Companies Table — new columns

```ruby
# Migration: add_check_printing_to_companies
add_column :companies, :next_check_number, :integer, default: 1001, null: false
add_column :companies, :check_stock_type, :string, default: "bottom_check"  # bottom_check | top_check
add_column :companies, :check_offset_x, :decimal, precision: 5, scale: 3, default: 0.0  # inches
add_column :companies, :check_offset_y, :decimal, precision: 5, scale: 3, default: 0.0  # inches
# Bank info for check face (if not pre-printed — keep optional)
add_column :companies, :bank_name, :string
add_column :companies, :bank_address, :string
add_column :companies, :bank_routing_number, :string  # encrypted at rest (optional — not needed for pre-printed)
add_column :companies, :bank_account_number, :string  # encrypted at rest (optional)
```

> **Assumption:** Bank routing + account numbers are NOT needed on the PDF when using pre-printed check stock (they're already on the stock). These fields are optional and only needed if we ever support blank stock printing.

### 6.2 PayrollItems Table — new columns

```ruby
# Migration: add_void_reprint_to_payroll_items
add_column :payroll_items, :voided, :boolean, default: false, null: false
add_column :payroll_items, :voided_at, :datetime
add_column :payroll_items, :voided_by_user_id, :integer, foreign_key: :users
add_column :payroll_items, :void_reason, :string
add_column :payroll_items, :reprint_of_check_number, :string  # original check # if this is a reprint
add_column :payroll_items, :check_print_count, :integer, default: 0, null: false

add_index :payroll_items, :voided
add_index :payroll_items, :reprint_of_check_number
```

### 6.3 Check Events Table (new — audit log for prints)

```ruby
# Migration: create_check_events
create_table :check_events do |t|
  t.references :payroll_item, null: false, foreign_key: true
  t.references :user, null: false, foreign_key: true
  t.string :event_type, null: false   # printed | voided | reprinted | alignment_test
  t.string :check_number
  t.string :reason
  t.string :ip_address
  t.timestamps
end
add_index :check_events, [:payroll_item_id, :event_type]
add_index :check_events, :check_number
```

This gives a complete, immutable audit trail of every print event — separate from the main `audit_logs` table so it can be queried independently for bank reconciliation.

### 6.4 PayrollItem Model Updates

```ruby
# app/models/payroll_item.rb additions
belongs_to :voided_by_user, class_name: "User", optional: true
has_many :check_events

scope :checks_only, -> { where.not(check_number: nil).where(voided: false) }
scope :voided_checks, -> { where(voided: true) }
scope :printed, -> { where.not(check_printed_at: nil) }
scope :unprinted, -> { where(check_printed_at: nil, voided: false) }

def void!(user:, reason:)
  raise "Already voided" if voided?
  transaction do
    update!(voided: true, voided_at: Time.current, voided_by_user_id: user.id, void_reason: reason)
    check_events.create!(user: user, event_type: "voided", check_number: check_number, reason: reason)
  end
end

def mark_printed!(user:, ip_address: nil)
  transaction do
    update!(check_printed_at: Time.current, check_print_count: check_print_count + 1)
    check_events.create!(user: user, event_type: "printed", check_number: check_number, ip_address: ip_address)
  end
end
```

---

## 7. API Design

### New Endpoints

```
# Check generation + download
GET  /api/v1/admin/pay_periods/:id/checks              # List all checks for period
POST /api/v1/admin/pay_periods/:id/checks/batch_pdf    # Generate combined batch PDF for all checks
GET  /api/v1/admin/payroll_items/:id/check             # Download single check PDF
POST /api/v1/admin/payroll_items/:id/check/mark_printed # Mark as printed (without downloading)
POST /api/v1/admin/payroll_items/:id/void              # Void a check
POST /api/v1/admin/payroll_items/:id/reprint           # Void old + issue reprint with new check #

# Check number management
PATCH /api/v1/admin/companies/:id/next_check_number   # Set starting check number (admin only)
GET   /api/v1/admin/companies/:id/check_register      # Check register report

# Alignment / settings
PATCH /api/v1/admin/companies/:id/check_settings      # Update offset_x, offset_y, stock_type
GET   /api/v1/admin/companies/:id/alignment_test_pdf  # Download alignment test PDF
```

### Check Number Assignment Logic

Check numbers are assigned at **commit time**, not print time. This matches QuickBooks behavior and ensures every committed payroll item has a check number before anyone touches the printer.

```ruby
# In PayPeriodsController#commit — inside the transaction
if params[:assign_check_numbers]  # or always, for check-paying companies
  starting_number = company.next_check_number
  company.with_lock do
    @pay_period.payroll_items
      .where(check_number: nil)
      .order(:id)
      .each_with_index do |item, idx|
        item.update!(check_number: (starting_number + idx).to_s)
      end
    company.update!(next_check_number: starting_number + items_count)
  end
end
```

> **Why at commit?** Prevents check numbers from being assigned to draft payrolls that might be deleted. Matches QuickBooks. Also means the check register and audit trail are complete before the printer is touched.

### Batch PDF Endpoint

`POST /api/v1/admin/pay_periods/:id/checks/batch_pdf`

Returns a single merged PDF with all check pages for the period. Each page is one employee's check (3-part layout). Pages are ordered by check number ascending. PDF is streamed directly (no R2 store for batch — it's regenerated on demand, reducing storage cost).

Response: `Content-Type: application/pdf`, `Content-Disposition: attachment; filename="checks_2026-03-07_batch.pdf"`

### Void Endpoint

`POST /api/v1/admin/payroll_items/:id/void`

```json
{ "reason": "Paper jam on check #1042 — physical check destroyed" }
```

- Requires committed payroll item
- Cannot void an already-voided item
- Does NOT affect YTD totals (the pay calculation was correct; only the physical instrument was voided)
- Logs to `check_events`

### Reprint Endpoint

`POST /api/v1/admin/payroll_items/:id/reprint`

1. Voids the current `PayrollItem` (sets `voided: true`, records original check #)
2. Creates a new `PayrollItem` cloned from the original with:
   - New check number (next from sequence)
   - `reprint_of_check_number: original_check_number`
   - `check_printed_at: nil` (not yet printed)
3. Returns the new `PayrollItem` ID + new check number

> **Note:** Reprint creates a new payroll item rather than modifying the existing one. This preserves immutability of the original record for audit purposes.

---

## 8. UI / Workflow Design

### 8.1 Pay Period Detail Page — New "Print Checks" Section

After a pay period is committed, a new **"Print Checks"** panel appears (below the payroll table):

```
┌─────────────────────────────────────────────────────────────────┐
│  💳 Print Checks                                               │
│  23 checks ready · 0 printed · 0 voided                        │
│                                                                  │
│  [⬇ Download Batch PDF]  [✓ Mark All as Printed]               │
│                                                                  │
│  Check #  │ Employee          │ Amount     │ Status    │ Actions│
│  ─────────┼───────────────────┼────────────┼───────────┼────────│
│  1042     │ John Santos       │ $1,218.91  │ ⏳ Unprinted│ ⬇ 🚫 │
│  1043     │ Maria Cruz        │ $987.42    │ ✅ Printed  │ ⬇ 🔄 │
│  1044     │ Carlos Reyes      │ $1,055.00  │ ❌ Voided   │ 🔄   │
│  ...                                                            │
└─────────────────────────────────────────────────────────────────┘
```

Actions:
- `⬇` = Download single check PDF
- `🚫` = Void (opens reason dialog)  
- `🔄` = Reprint (opens confirm dialog)

### 8.2 Print Flow

1. User clicks **"Download Batch PDF"**
2. Browser downloads `checks_2026-03-07_MoSas.pdf`
3. User opens PDF in Acrobat / Preview and prints to laser printer
4. User loads pre-printed check stock into printer tray
5. Printer prints variable data on stock
6. User returns to app, reviews checks against paper
7. If all good: clicks **"Mark All as Printed"** → sets `check_printed_at` for all unprinted items
8. If one fails: voids that check → initates reprint for that employee

### 8.3 Alignment Test PDF

A special single-page PDF with a grid overlay and all fields labeled (e.g., "PAYEE NAME GOES HERE") printed in the normal positions. Operator prints on plain paper, overlays on check stock to verify alignment before printing the real batch.

Accessible via: **Settings → Check Printing → Download Alignment Test**

### 8.4 Check Settings UI

Under **Company Settings → Checks**:
- Starting check number (editable only if no checks issued yet for this year)
- Check stock type: "Bottom check (most common)" / "Top check"
- Fine offset X/Y: ±0.5" in 0.05" increments (two number inputs)
- Bank name + address (optional — for blank stock compatibility)

---

## 9. Safety Controls

### 9.1 Duplicate Print Prevention

| Control | Implementation |
|---------|---------------|
| `check_printed_at` timestamp | Set on first successful mark-as-printed |
| `check_print_count` counter | Increments on every print event; UI warns if > 1 |
| Confirmation modal on reprint | "This check was already printed on [date]. Are you sure?" |
| Voiding required before reprint | Reprint endpoint voids original first |
| Audit log for every print | `check_events` table |

### 9.2 Check Number Uniqueness

| Control | Implementation |
|---------|---------------|
| DB unique index on `check_number` | `add_index :payroll_items, :check_number, unique: true` |
| `next_check_number` locked via `with_lock` | Prevents race condition on concurrent commits |
| Sequential assignment only | Check numbers never manually entered (except in `check_settings` to set starting point) |

> **Breaking change from current behavior:** Currently `check_number` is a manually-entered free text field. Post-CPR-66, it will be auto-assigned and read-only. Existing manually-entered check numbers will be preserved.

### 9.3 Voiding Controls

- Only `admin` or `super_admin` roles can void a check
- Void requires a written reason (minimum 10 characters)
- Voided items display in the check register with `VOID` watermark when PDF is re-downloaded
- Voided checks are NOT deleted from the database — ever

### 9.4 Access Control

- All check endpoints require `admin` role minimum
- Batch PDF download is logged to `check_events` (event_type: `batch_downloaded`)
- Print-action IP address captured for audit

### 9.5 Post-Commit Immutability

- Check numbers cannot be changed after assignment
- Payroll amounts cannot be changed after commit (existing protection)
- To correct an error: void + adjustment payroll run (CPR-67 scope)

---

## 10. Acceptance Test Plan

### 10.1 Unit Tests (RSpec — `spec/services/check_generator_spec.rb`)

| Test | Pass Criteria |
|------|--------------|
| Generates valid PDF binary | `result.start_with?("%PDF")` |
| Amount-to-words: `$1,218.91` | `"One thousand two hundred eighteen and 91/100"` |
| Amount-to-words: `$0.00` | `"Zero and 00/100"` |
| Amount-to-words: `$1,000,000.00` | `"One million and 00/100"` |
| Check number appears in PDF text | PDF text extraction includes `"1042"` |
| Payee name appears | PDF includes employee full name |
| Net pay numeric appears | `"$1,218.91"` in PDF text |
| Date formatted correctly | `"MM/DD/YYYY"` format |
| Voided item generates VOID watermark | PDF text includes `"VOID"` |

### 10.2 API Tests (RSpec request specs)

| Test | Pass Criteria |
|------|--------------|
| `GET /checks` returns check list for committed period | 200, array of items with check numbers |
| `GET /checks` on draft period returns error | 422 |
| `POST /batch_pdf` returns PDF | 200, `Content-Type: application/pdf` |
| `POST /mark_printed` sets `check_printed_at` | 200, timestamp set |
| `POST /mark_printed` twice warns | 200, `already_printed: true` |
| `POST /void` with valid reason | 200, `voided: true` |
| `POST /void` without reason | 422, validation error |
| `POST /void` on already-voided | 422 |
| `POST /reprint` creates new item + voids original | 201, new check # assigned |
| Check numbers are unique across pay periods | DB constraint test |
| Concurrent commit race condition | Two simultaneous commits get non-overlapping check numbers |

### 10.3 Integration Test — Alignment (Physical)

This is the most critical test and cannot be done in software alone.

**Step 1: Get a sheet of Bank of Guam check stock from Cornerstone**  
- Measure the check area dimensions (height, width, position from top)
- Note whether check is at top or bottom of the sheet
- Note position of key fields: date box, payee line, amount box, written amount line, memo line, signature line

**Step 2: Configure `CheckGenerator` coordinates to match measurements**  
- Input dimensions into `CheckGenerator` constants (or company settings)

**Step 3: Print alignment test PDF on plain paper**  
- Hold up to check stock in front of a light source
- Verify all labeled boxes align with the printed areas on the stock

**Step 4: Print a real check on one sheet of check stock**  
- Verify payee name lands in correct field
- Verify dollar amount lands in `$` box
- Verify written amount does not overflow its line
- Verify date lands in date box
- Verify memo line is legible
- Verify no text lands in MICR area (pre-printed on stock; we must not overprint it)

**Step 5: Attempt bank deposit of the test check**  
- Issue one small-amount check to a known employee for testing
- Employee attempts to deposit at Bank of Guam
- Confirm no processing issues or teller flags

**Step 6: Sign off**  
- Leon or Cornerstone manager signs off on alignment
- Document the final `check_offset_x` and `check_offset_y` values in the company settings
- Document the printer model used (different printers may have different feed tolerances)

### 10.4 End-to-End Test (Staging)

Using MoSa's test data (2024-08-12 pay period from `test_uploads/`):

1. Import from Revel PDF + LoansAndTips.xlsx
2. Run payroll calculations
3. Approve + commit pay period
4. Confirm check numbers assigned sequentially starting from configured number
5. Download batch PDF
6. Verify PDF has correct page count (one per employee with check)
7. Void one check (enter reason)
8. Reprint voided check (confirm new check number assigned)
9. Download batch PDF again (voided check shows VOID watermark, reprint is new page)
10. Mark all remaining checks as printed
11. Verify audit trail (`check_events` table shows all events)

---

## 11. Rollout Plan — MoSa's First

### Phase 1: Backend + PDF (Sprint 1 — ~3 days)

| Task | Owner | Estimate |
|------|-------|----------|
| DB migrations (companies + payroll_items + check_events) | Dev | 0.5 day |
| `NumberToWords` module (amount-to-words) | Dev | 0.5 day |
| `CheckGenerator` service (Prawn layout) | Dev | 1 day |
| Check number auto-sequencing in commit | Dev | 0.5 day |
| Void / reprint API endpoints | Dev | 0.5 day |
| RSpec unit tests for `CheckGenerator` | Dev | 0.5 day |
| RSpec request specs for new endpoints | Dev | 0.5 day |

### Phase 2: Frontend UI (Sprint 1 continued — ~2 days)

| Task | Owner | Estimate |
|------|-------|----------|
| "Print Checks" panel on Pay Period detail page | Dev | 1 day |
| Void modal (reason input + confirm) | Dev | 0.5 day |
| Reprint flow (confirm + show new check #) | Dev | 0.5 day |
| Check settings page (starting number, offsets) | Dev | 0.5 day |
| Alignment test PDF download button | Dev | 0.25 day |

### Phase 3: Physical Alignment & QA (Sprint 2 — ~2 days)

| Task | Owner | Notes |
|------|-------|-------|
| Get Bank of Guam check stock sample from Cornerstone | Leon | 1 sheet to start |
| Measure check layout, input coordinates | Dev + Leon | May need 2-3 iterations |
| Print alignment test on plain paper, verify | Leon | In Guam |
| Print test check on real stock | Leon | Confirm alignment |
| Bank deposit test | Employee volunteer | Real check, small amount |
| Sign-off from Cornerstone | Leon / Cornerstone | Final approval |

### Phase 4: MoSa's Live Payroll

1. Enable check printing feature flag for MoSa's company record
2. Process next biweekly payroll (should be ~$50K in checks for ~50 employees)
3. Leon or Cornerstone staff processes the batch PDF
4. Monitor for any issues (alignment, bank rejections, user confusion)
5. Post-run: review `check_events` audit log

### Phase 5: Other Clients

After one successful MoSa's run, roll out to other Cornerstone clients. Each client will need their own alignment verification if they use a different printer.

---

## 12. Risk Register & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Check stock layout varies by company / bank | Medium | High | Measure each client's stock; store per-company offsets; alignment test PDF |
| Printer feeds check stock inconsistently (paper jam, skew) | Medium | Medium | Train operators to use plain-paper test first; keep spare stock for reprints |
| Bank rejects printed checks (bad alignment or overprinted MICR) | Low | High | Never print in MICR area; alignment test before production run; bank deposit test in Phase 3 |
| Duplicate check issued (system + human error) | Low | High | DB unique index, `check_print_count` warning, mark-as-printed required flow |
| Check number sequence gap (e.g., voided check) | Low | Low | Gaps in sequence are normal (voided checks create gaps); document this |
| `next_check_number` race condition on concurrent commits | Low | Medium | `with_lock` on company row during assignment |
| `check_writer` gem instability | N/A | N/A | Ruled out; using custom Prawn implementation |
| Employee receives double payment via both check + direct deposit | Medium | High | `payment_method` field on Employee; UI warning if both check # and DD info present |
| Lost physical check | Low | Medium | Void + reprint flow; void requires reason logged |
| Unauthorized check printing | Low | High | Admin-only endpoints; IP logging; check_events audit trail |
| Prawn PDF doesn't print correctly on all OS/printer combos | Medium | Medium | Test on Mac (Preview + Print), Windows (Acrobat) — Cornerstone likely uses one of each |
| Check layout doesn't account for signature (physical vs digital) | Medium | Medium | Include signature line on check; Cornerstone currently signs manually |

---

## 13. Implementation Checklist

### Backend
- [ ] Migration: `add_check_printing_to_companies`
- [ ] Migration: `add_void_reprint_to_payroll_items`
- [ ] Migration: `create_check_events`
- [ ] `NumberToWords` module (`lib/number_to_words.rb`)
- [ ] `CheckGenerator` service with Prawn layout
- [ ] Auto-sequence check numbers in `PayPeriodsController#commit`
- [ ] `PayrollItem#void!` and `PayrollItem#mark_printed!` model methods
- [ ] `ChecksController` or new actions on `PayrollItemsController`
- [ ] Batch PDF endpoint (merged Prawn doc)
- [ ] Alignment test PDF endpoint
- [ ] Unique index on `check_number`
- [ ] RSpec: `CheckGenerator` unit specs
- [ ] RSpec: API request specs

### Frontend
- [ ] "Print Checks" panel on `PayPeriodDetail` page
- [ ] Single check PDF download button per row
- [ ] Batch PDF download button
- [ ] "Mark All as Printed" / individual mark-as-printed
- [ ] Void modal with reason input
- [ ] Reprint confirmation modal
- [ ] Company check settings page (starting #, offsets, stock type)
- [ ] Alignment test PDF download
- [ ] Check status badge (Unprinted / Printed / Voided / Reprinted)

### Physical QA
- [ ] Obtain Bank of Guam check stock sample
- [ ] Measure layout and configure `CheckGenerator` coordinates
- [ ] Plain-paper alignment test
- [ ] Real-stock test print
- [ ] Bank deposit test
- [ ] Cornerstone sign-off

### Launch
- [ ] Feature flag: enable for MoSa's
- [ ] Run first production payroll with check printing
- [ ] Monitor `check_events` audit log
- [ ] Retrospective / lessons learned

---

## Appendix A: Key File Locations

| File | Purpose |
|------|---------|
| `api/app/services/check_generator.rb` | New — main PDF generator |
| `api/app/services/pay_stub_generator.rb` | Existing — earnings statement (keep as-is) |
| `api/lib/number_to_words.rb` | New — amount-to-words helper |
| `api/app/models/payroll_item.rb` | Add void!/mark_printed! methods |
| `api/app/models/company.rb` | Add next_check_number, offsets |
| `api/app/models/check_event.rb` | New model |
| `api/app/controllers/api/v1/admin/checks_controller.rb` | New controller |
| `api/db/migrate/YYYYMMDD_add_check_printing_to_companies.rb` | New migration |
| `api/db/migrate/YYYYMMDD_add_void_reprint_to_payroll_items.rb` | New migration |
| `api/db/migrate/YYYYMMDD_create_check_events.rb` | New migration |
| `web/src/pages/PayPeriodDetail.tsx` | Add Print Checks panel |
| `web/src/components/checks/ChecksPanel.tsx` | New component |
| `web/src/components/checks/VoidModal.tsx` | New component |
| `web/src/components/checks/ReprintModal.tsx` | New component |
| `web/src/pages/CheckSettings.tsx` | New page |

---

## Appendix B: Amount-to-Words Logic (Pseudocode)

```ruby
module NumberToWords
  def self.convert(amount)
    # amount: Float or BigDecimal, e.g., 1218.91
    dollars = amount.to_i
    cents = ((amount - dollars) * 100).round.to_i
    "#{integer_to_words(dollars).capitalize} and #{cents.to_s.rjust(2, '0')}/100"
  end

  # Handles 0–999,999,999
  # e.g., 1218 → "one thousand two hundred eighteen"
  def self.integer_to_words(n)
    # ... standard recursive ones/teens/tens/hundreds/thousands/millions
  end
end
```

Full implementation is ~80 lines. There is also the `number_to_currency_words` gem (actively maintained, Ruby 3.x compatible) as an alternative to building from scratch.

---

*Document owner: Leon Shimizu / Shimizu Technology*  
*Based on: PRD.md, QB_PARITY_CHECKLIST.md, code audit of api/app/, and external research cited inline*  
*Created: 2026-03-10*
