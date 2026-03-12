# Client Cutover Gate Criteria — Go / No-Go Rules
**Cornerstone Payroll · QuickBooks Cutover Pack (CPR-72)**

> **Purpose:** Define exactly when a client is cleared to move from Parallel Mode
> (QuickBooks authoritative) to Cornerstone-Primary Mode (Cornerstone Payroll authoritative).
>
> **No client moves to Cornerstone-Primary without meeting ALL gates below.**
> There are no exceptions without explicit documented override by Leon.

---

## Definitions

| Term | Meaning |
|------|---------|
| **Parallel Mode** | Both QB and CP run the same period. QB is the payout/filing source. |
| **Cornerstone-Primary Mode** | CP is the system of record. QB is read-only / fallback. |
| **Consecutive PASS cycles** | Two back-to-back PASS cycles with no FAIL in between. A FAIL resets the count. |
| **PASS cycle** | All sections of the Parallel-Run Validation Template are PASS + signoff complete. |
| **Cutover** | The moment a client officially switches from QB to CP as the authoritative payroll source. |

---

## Standard Cutover Gate (All Clients)

A client is eligible for cutover only when **ALL** of the following are true:

### Gate 1 — Consecutive PASS Cycles ✅

| Requirement | Rule |
|-------------|------|
| Minimum PASS cycles | **2 consecutive** PASS cycles (no FAIL between them) |
| Cycle recency | Both PASS cycles must be from **live production payroll periods** (not test data) |
| Time gap | No more than **6 weeks between the two PASS cycles** (stale validation doesn't count) |

> **Leon Override:** 1 PASS cycle + explicit documented override by Leon is permitted for low-risk manual clients (ST, Cornerstone internal, DDG). Override must be recorded in the client's cutover record below.

---

### Gate 2 — Numerical Accuracy ✅

All of the following must be true across both PASS cycles:

| Field | Requirement |
|-------|-------------|
| Employee count | Exact match both cycles (0 tolerance) |
| Gross pay (total) | Within tolerance both cycles (Import: $0.00; Manual: ≤$1.00/period) |
| FIT/DRT withholding per employee | ≤ $0.01 both cycles |
| SS employee per employee | ≤ $0.01 both cycles |
| Medicare employee per employee | ≤ $0.01 both cycles |
| Employer SS (total) | ≤ $0.50/period both cycles |
| Employer Medicare (total) | ≤ $0.50/period both cycles |
| Net pay per employee | ≤ $0.01 both cycles |
| Net pay total | ≤ $0.50/period both cycles |
| Check totals (if applicable) | Exact match both cycles ($0.00 tolerance) |

---

### Gate 3 — System Readiness ✅

| Requirement | Rule |
|-------------|------|
| Employee master data complete | All active employees have correct pay rate, employment type, filing status, allowances |
| Pay period workflow | Both PASS cycles completed full draft→calculated→approved→committed flow without errors |
| Report artifacts | Payroll register + tax summary generated for both PASS cycles |
| No open P1 / blocking tickets | Zero unresolved P1 tickets for this client |
| Check printing (if client uses checks) | Check printing validated on real stock for this client |

---

### Gate 4 — Operational Readiness ✅

| Requirement | Rule |
|-------------|------|
| Operator trained | At least one Cornerstone Ops person can run a full cycle for this client independently |
| Fallback plan documented | Fallback to QB process confirmed + contact identified |
| Cutover date agreed | Leon + Cornerstone Ops have agreed on the specific cutover date |
| Client notified (if applicable) | Client has been informed of the system change (if they receive direct output) |

---

### Gate 5 — Explicit Signoff ✅

Both of the following signatures are required before cutover proceeds:

| Signoff | Name | Date |
|---------|------|------|
| Leon Shimizu (technical approval) | | |
| Cornerstone Ops Lead (operational approval) | | |

> **This signoff is mandatory. A PASS cycle alone is not sufficient for cutover.**

---

## Hard NO-GO Conditions (Any One Blocks Cutover)

The following conditions are **absolute blockers** — no override permitted:

| Condition | Reason |
|-----------|--------|
| Any unresolved FAIL cycle within the last 2 cycles | System trust not established |
| Employee count mismatch in either PASS cycle (even if later explained) | Fundamental data integrity issue |
| Gross pay variance > threshold in either cycle | Financial accuracy not confirmed |
| Any committed payroll that was later found to have errors (post-commit, pre-fix) | Trust requires clean track record |
| Open P1 ticket for this client | Blocking issues must resolve first |
| No fallback plan documented | Cannot move to CP-primary without safety net |
| Tax withholding variance > $1.00 aggregate in either cycle | IRS/DRT compliance risk |
| `voided` or correction payroll pending unresolved for this client | Cannot cut over mid-correction |

---

## Per-Client Cutover Record

### MoSa's Joint

| Field | Value |
|-------|-------|
| Input mode | Import (automated) |
| Cutover type | Standard (2 consecutive PASS) |
| Cycle 1 PASS date | _(fill when achieved)_ |
| Cycle 2 PASS date | _(fill when achieved)_ |
| All hard NO-GO conditions clear? | _(Yes / No — details)_ |
| Gate 3 system readiness confirmed? | _(Yes / No — details)_ |
| Gate 4 operational readiness confirmed? | _(Yes / No — details)_ |
| Cutover date agreed | _(fill when agreed)_ |
| Leon signoff | _(name + date)_ |
| Ops Lead signoff | _(name + date)_ |
| **Cutover approved?** | **YES / NO / PENDING** |
| Notes | |

---

### Shimizu Technology

| Field | Value |
|-------|-------|
| Input mode | Manual |
| Cutover type | Standard (2 consecutive PASS) or Leon override (1 PASS) |
| Cycle 1 PASS date | _(fill when achieved)_ |
| Cycle 2 PASS date | _(fill when achieved — or "Override: see note")_ |
| Override rationale (if 1-cycle) | _(document here if override used)_ |
| All hard NO-GO conditions clear? | _(Yes / No)_ |
| Gate 3 system readiness confirmed? | _(Yes / No)_ |
| Gate 4 operational readiness confirmed? | _(Yes / No)_ |
| Cutover date agreed | _(fill when agreed)_ |
| Leon signoff | _(name + date)_ |
| Ops Lead signoff | _(name + date)_ |
| **Cutover approved?** | **YES / NO / PENDING** |
| Notes | Small 2-person team; low risk; good pilot candidate for 1-cycle override |

---

### Cornerstone Internal

| Field | Value |
|-------|-------|
| Input mode | Manual |
| Cutover type | Standard (2 consecutive PASS) or Leon override (1 PASS) |
| Cycle 1 PASS date | _(fill when achieved)_ |
| Cycle 2 PASS date | _(fill when achieved)_ |
| All hard NO-GO conditions clear? | _(Yes / No)_ |
| Gate 3 system readiness confirmed? | _(Yes / No)_ |
| Gate 4 operational readiness confirmed? | _(Yes / No)_ |
| Cutover date agreed | _(fill when agreed)_ |
| Leon signoff | _(name + date)_ |
| Ops Lead signoff | _(name + date)_ |
| **Cutover approved?** | **YES / NO / PENDING** |
| Notes | Internal team — fastest feedback loop for issues |

---

### Duck Duck Goose (DDG)

| Field | Value |
|-------|-------|
| Input mode | Manual (timesheet) |
| Cutover type | Standard (2 consecutive PASS) or Leon override (1 PASS) |
| Cycle 1 PASS date | _(fill when achieved)_ |
| Cycle 2 PASS date | _(fill when achieved)_ |
| All hard NO-GO conditions clear? | _(Yes / No)_ |
| Gate 3 system readiness confirmed? | _(Yes / No)_ |
| Gate 4 operational readiness confirmed? | _(Yes / No)_ |
| Cutover date agreed | _(fill when agreed)_ |
| Leon signoff | _(name + date)_ |
| Ops Lead signoff | _(name + date)_ |
| **Cutover approved?** | **YES / NO / PENDING** |
| Notes | 3 employees (2 hourly, 1 salary); straightforward mixed-type |

---

### Spike Coffee Roasters (SPR)

| Field | Value |
|-------|-------|
| Input mode | Manual (email/timesheet source) |
| Cutover type | Standard (2 consecutive PASS required — no override; tips complexity) |
| Cycle 1 PASS date | _(fill when achieved)_ |
| Cycle 2 PASS date | _(fill when achieved)_ |
| All hard NO-GO conditions clear? | _(Yes / No)_ |
| Gate 3 system readiness confirmed? | _(Yes / No)_ |
| Gate 4 operational readiness confirmed? | _(Yes / No)_ |
| Cutover date agreed | _(fill when agreed)_ |
| Leon signoff | _(name + date)_ |
| Ops Lead signoff | _(name + date)_ |
| **Cutover approved?** | **YES / NO / PENDING** |
| Notes | 10–15 employees; tips expected; 2-cycle standard required (no override) |

---

## Post-Cutover: What Changes

When a client reaches Cornerstone-Primary Mode:

| Item | Before (Parallel) | After (CP-Primary) |
|------|-------------------|---------------------|
| Payout source | QuickBooks | Cornerstone Payroll |
| Tax filing source | QuickBooks | Cornerstone Payroll |
| QB usage | Full parallel run | Read-only / reference only |
| Validation template | Required every cycle | Recommended for 2 more cycles, then spot-check |
| Fallback path | QB authoritative | QB as emergency fallback (read-only data) |
| Error escalation | See Section 5 of CLIENT_ROLLOUT_PLAN.md | Leon + Dev define correction path case-by-case |

---

## Reverting to Parallel Mode (Post-Cutover Emergency)

If a critical issue is discovered after cutover:

1. Leon declares a **P1 incident** immediately
2. Cornerstone Ops reverts to QB as the manual reference for the **current open period only**
3. Do NOT re-open previously committed periods without Leon + Dev team explicit approval
4. Document incident in `docs/rollout/05-ISSUE-REMEDIATION-LOG.md`
5. Client re-enters parallel mode for minimum **2 additional consecutive PASS cycles** before re-cutting over

---

_Document version: CPR-72 · Last updated: 2026-03-12_
