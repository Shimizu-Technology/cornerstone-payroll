# QA Checklist — Payroll Correction UX (CPR-73)

**Ticket:** CPR-73  
**Branch:** CPR-73-correction-ux-polish  
**Author:** Theo (Shimizu Technology)  
**Status:** Draft  

Use this checklist each release cycle to verify the correction workflow end-to-end.
Mark each item ✅ PASS or ❌ FAIL. Attach evidence (screenshots or spec output) where noted.

---

## Setup

- [ ] Logged in as admin user
- [ ] A committed pay period exists (status = committed, no corrections yet)
- [ ] Correction panel is visible at bottom of pay period detail page

---

## 1. Void Source Period

| # | Step | Expected Result | Status | Notes |
|---|------|----------------|--------|-------|
| 1.1 | Click "Void This Pay Period" button | Void modal opens with warning list and two fields (reason + VOID confirm) | | |
| 1.2 | Submit form with empty reason | Inline validation error: "A reason is required" | | |
| 1.3 | Submit with reason < 10 chars | Validation error: "must be at least 10 characters" | | |
| 1.4 | Submit with placeholder reason "test" | Validation error about providing a descriptive reason | | |
| 1.5 | Type valid reason (≥ 10 chars), leave VOID confirm empty | Submit button stays disabled OR error fires on confirm field | | |
| 1.6 | Type VOID (partial / lowercase "void") | Submit button remains disabled | | |
| 1.7 | Type VOID (exact), valid reason → submit | Modal shows loading state, button disabled during request | | |
| 1.8 | After success | Modal closes, page shows "Period Voided" red banner with reason + timestamp | | |
| 1.9 | Verify YTD reversed | DB: `EmployeeYtdTotal.gross_pay` = 0 for period employees | | |
| 1.10 | "Void This Pay Period" button no longer visible | can_void = false | | |
| 1.11 | "Create Correction Run" button now visible | can_create_correction_run = true | | |
| 1.12 | Escape key closes modal when not in-flight | | | |
| 1.13 | Focus returns to trigger button after modal close | | | |

---

## 2. Create Correction Run

| # | Step | Expected Result | Status | Notes |
|---|------|----------------|--------|-------|
| 2.1 | On voided period, click "Create Correction Run" | Modal opens with info panel, reason field, optional pay date | | |
| 2.2 | Submit with blank reason | Validation error fires | | |
| 2.3 | Submit with reason < 10 chars | Validation error: min length | | |
| 2.4 | Fill valid reason, submit | Modal shows loading state | | |
| 2.5 | After success | Navigated to new draft correction run pay period | | |
| 2.6 | New period shows "Correction Run" amber badge | | | |
| 2.7 | New period shows source period linkage link | | | |
| 2.8 | New period has same employees pre-populated | | | |
| 2.9 | Override pay date with valid ISO date | New period has correct pay_date | | |
| 2.10 | Override pay date with invalid date "03/22/2026" | API returns 422, modal shows error with recovery copy | | |
| 2.11 | Attempt to create second correction run on same voided period | Error: "already has a correction run" + recovery guidance | | |

---

## 3. Void Correction Run

| # | Step | Expected Result | Status | Notes |
|---|------|----------------|--------|-------|
| 3.1 | On committed correction run, "Void This Correction Run" button visible | | | |
| 3.2 | Click button → modal opens with correction-run-specific warning copy | Mentions YTD reversal + source period re-opened | | |
| 3.3 | Submit with valid reason + VOID | Correction run marked voided, source period superseded_by_id cleared | | |
| 3.4 | Source period detail: "Create Correction Run" re-appears | can_create_correction_run = true again | | |
| 3.5 | Audit history on source period shows void_initiated event for the correction run | | | |

---

## 4. Delete Draft Correction Run

| # | Step | Expected Result | Status | Notes |
|---|------|----------------|--------|-------|
| 4.1 | On draft correction run, "Delete Draft Correction Run" button visible | | | |
| 4.2 | Click button → modal opens with orange-themed warning + "What happens" list | | | |
| 4.3 | No VOID-confirmation text field (less severe than void) | | | |
| 4.4 | Submit with blank reason | Validation error fires | | |
| 4.5 | Submit with valid reason (≥ 10 chars) | Loading state, submit disabled | | |
| 4.6 | After success | Navigated to source period; source is re-opened | | |
| 4.7 | Source period shows "Create Correction Run" button | | | |
| 4.8 | Audit history on source period shows correction_run_deleted event | | | |
| 4.9 | correction_run_deleted event carries the operator's reason | | | |
| 4.10 | Attempting to delete a committed correction run returns 422 | | | |

---

## 5. Re-Correction Chain Visibility

| # | Step | Expected Result | Status | Notes |
|---|------|----------------|--------|-------|
| 5.1 | Source period voided → correction run #1 created → deleted → correction run #2 created | All steps complete without error | | |
| 5.2 | Audit timeline on source period shows all 4 events in chronological order | void_initiated, correction_run_created, correction_run_deleted, correction_run_created | | |
| 5.3 | Each event row shows: action badge, timestamp, actor, reason, financial snapshot | | | |
| 5.4 | Correction run linkage buttons navigate to correct periods | | | |
| 5.5 | Deleted correction run is NOT navigable (it no longer exists) | | | |

---

## 6. Error Paths and Recovery

| # | Step | Expected Result | Status | Notes |
|---|------|----------------|--------|-------|
| 6.1 | Server error on void (simulated) | Modal shows error with specific next-step guidance, not just raw message | | |
| 6.2 | Network error on create correction run | Error includes "Check your network connection. No changes were made." | | |
| 6.3 | Double-void: void same period twice (concurrent tab) | Second attempt shows "already been voided" + guidance to refresh | | |
| 6.4 | History load failure | Error message visible below "View Correction History" button | | |

---

## 7. Accessibility and Focus Management

| # | Step | Expected Result | Status | Notes |
|---|------|----------------|--------|-------|
| 7.1 | Open void modal with keyboard (Enter on focused button) | Modal opens and focus moves inside | | |
| 7.2 | Tab through all modal fields | Focus stays trapped inside modal | | |
| 7.3 | Shift+Tab from first field wraps to last | | | |
| 7.4 | Escape closes modal (when not in-flight) | Focus returns to trigger button | | |
| 7.5 | All form fields have visible labels | | | |
| 7.6 | Required fields marked visually and with aria-required | | | |
| 7.7 | Error messages have role="alert" or aria-live | | | |
| 7.8 | In-flight submit button has aria-busy="true" | | | |
| 7.9 | Voided banner has role="status" | | | |
| 7.10 | Audit timeline is an `<ol>` with aria-label | | | |

---

## 8. Runbook Parity (CPR-72 Alignment)

| # | Item | Expected Wording / Behavior | Status |
|---|------|-----------------------------|--------|
| 8.1 | Void modal warning copy matches CPR-72 runbook guidance | "YTD totals will be reversed" visible | |
| 8.2 | Create correction run modal lists correct next steps per runbook | Calculate → Review → Commit flow described | |
| 8.3 | Delete draft modal mentions "no YTD totals affected" | | |
| 8.4 | Action button labels match runbook terminology | "Void This Pay Period", "Create Correction Run", "Void This Correction Run", "Delete Draft Correction Run" | |

---

## Sign-off

| Role | Name | Date | Status |
|------|------|------|--------|
| Developer | | | |
| QA Reviewer | | | |
| Ops Approval | | | |

**Evidence files:** attach to `docs/rollout/evidence/cornerstone-internal/`
