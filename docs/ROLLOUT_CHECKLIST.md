# MoSa Payroll Import — Rollout Checklist

**Target:** Production go-live of automated MoSa payroll import at Cornerstone Tax  
**Status:** Pre-rollout (validation complete, ready for parallel run)  
**Owner:** Leon / Shimizu Technology

---

## Go / No-Go Criteria

### ✅ GO conditions (all must be true)

| # | Criterion | Current Status |
|---|-----------|---------------|
| 1 | All 26 pay periods parse without error | ✅ 26/26 OK |
| 2 | Zero unmatched employee names | ✅ 0 unmatched |
| 3 | Zero parser outlier rows (>200h) | ✅ 0 outliers |
| 4 | Zero gross_diff for all periods | ✅ all 0.0 |
| 5 | Employee backfill completed (35 employees created) | ✅ Done |
| 6 | Validation script runs end-to-end < 5 min | ✅ ~2 min |
| 7 | Tests passing (53 specs, 0 failures) | ✅ 53/53 |
| 8 | Parallel run sign-off from Cornerstone (see Week 2) | ⏳ Pending |

### 🛑 NO-GO conditions (any one blocks launch)

- Any period shows `error` or `skip` status in validation report
- Any unmatched employee names (means incomplete backfill)
- Any gross_diff ≠ 0.0 (financial mismatch — must investigate before launch)
- Cornerstone staff unable to access/review validation report
- No fallback plan confirmed with MoSa accountant

---

## Week-by-Week Rollout Plan

### Week 1 — Parallel Run Setup (Cornerstone reviews validation)

**Goal:** Confirm our numbers match Cornerstone's existing manual records.

**Actions:**
- [ ] Share `data/mosa-2025/validation_report.md` with Cornerstone staff
- [ ] Cornerstone cross-checks 3 spot-check periods against their ledger:
  - Recommended: PP19 (Sep 22–Oct 4), PP20 (Oct 6–19), PP25 (Dec 15–27)
- [ ] Verify employee list (81 employees) matches Cornerstone's HR records
- [ ] Confirm pay rates for the 35 backfilled employees are correct in DB
- [ ] Developer reviews any outstanding questions from Cornerstone

**Sign-off gate:** Cornerstone confirms spot-check numbers match. ✍️

---

### Week 2 — Parallel Run (live period)

**Goal:** Process the NEXT live MoSa payroll period with both old (manual) and new (automated) systems simultaneously.

**Actions:**
- [ ] When next payroll email arrives, run `scripts/mosa_run.sh download` + `validate`
- [ ] Add new period to PAY_PERIODS config and re-run
- [ ] Compare automated output vs manual calculation for new period
- [ ] Document any discrepancies (expected: hours diffs ≤ 80h, gross_diff = 0)
- [ ] Share automated report with Cornerstone accountant for review

**Sign-off gate:** Zero gross discrepancies on live period. Cornerstone accountant confirms. ✍️

---

### Week 3 — Limited Production Import (apply to DB)

**Goal:** Apply one new period to production DB; verify downstream systems.

**Actions:**
- [ ] Set `MOSA_APPLY=1` for one period (most recent only)
- [ ] Confirm payroll items created correctly in admin UI
- [ ] Verify tax calculations (DRT withholding, SS, Medicare) look correct
- [ ] Verify loan/tip deductions applied correctly
- [ ] Run existing test suite: `bundle exec rspec`
- [ ] Check no unexpected effects on reports/exports

**Sign-off gate:** Cornerstone reviews generated payroll items for the test period. ✍️

---

### Week 4 — Full Production (all historical + ongoing)

**Goal:** Backfill all 26 historical periods + establish ongoing cadence.

**Actions:**
- [ ] Apply remaining 25 historical periods to DB (in order PP00 → PP25)
- [ ] Generate full-year payroll summary report for Cornerstone
- [ ] Set up monitoring cadence (see below)
- [ ] Train Cornerstone staff on:
  - Viewing validation reports
  - Requesting re-runs if needed
  - Who to contact if something looks wrong
- [ ] Archive this checklist and mark rollout COMPLETE

**Sign-off gate:** Cornerstone CEO (Dafne) formally accepts full-year import. ✍️

---

## Monitoring Cadence

Once live, check after each new payroll period:

```
Every payroll cycle (biweekly):
  1. Email arrives → run scripts/mosa_run.sh download
  2. Add new period config (2 min)
  3. Run scripts/mosa_run.sh validate
  4. Review: Periods OK = N/N, unmatched = 0, gross_diff = 0 for all
  5. If clean → apply (MOSA_APPLY=1)
  6. Share report with Cornerstone
```

**Monthly:** Review validation_report.md for any trend anomalies (unusual headcount drops, gross pay spikes).

**Quarterly:** Review the 35 backfilled employees' pay rates — update any that HR has since confirmed.

---

## Fallback Plan

### If automated import fails mid-period

1. **Do NOT panic** — the manual process still works; revert to it for this cycle.
2. Keep the PDF and Excel in `data/mosa-2025/raw/` — don't delete.
3. Note the specific error from the validation report.
4. Contact Leon (developer) with the error details.
5. Expected fix time: < 4 hours for known parser issues; 1–2 days for new edge cases.

### If gross_diff ≠ 0 for a period

This is a financial discrepancy — **do not apply to DB until resolved.**

1. Check if the PDF has a new Revel export format (column positions shifted).
2. Check if an employee has two rows in the PDF (manager + server role).
3. Run: `DEBUG=1 bundle exec rails runner scripts/mosa_full_year_validation.rb`
4. Compare individual employee records against PDF manually.

### Rollback (if production DB has bad data)

The import creates `PayrollItem` records with a traceable `pay_period_id`. To roll back a specific period:

```bash
cd api
rails runner "PayPeriod.find_by(start_date: 'YYYY-MM-DD').payroll_items.destroy_all"
```

This is safe and reversible — it doesn't touch Employee or Company records.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Revel PDF layout changes | Medium | High | Fallback parser handles column drift; 200h threshold catches outliers |
| New employee not in DB | Medium | Low | Backfill script catches unmatched names before apply |
| Mislabeled email subject | Low | Low | Verified: PP20 found despite "September" subject label |
| Pay rate data missing for backfilled employees | High | Medium | Backfilled with pay_rate=0; HR must update before payroll reports |
| Gmail API token expiry | Low | Medium | Refresh via: `gog auth refresh --account jerry.shimizutechnology@gmail.com` |
| DB environment mismatch (staging vs prod) | Medium | High | Always confirm environment with `rails runner "puts Rails.env"` before applying |

---

## Key Numbers (Final Validation, 2026-03-09)

| Metric | Value |
|--------|-------|
| Total pay periods | 26 (PP00–PP25) |
| Coverage | 2024-12-30 to 2025-12-27 |
| Total employees | 81 (46 original + 35 backfilled) |
| Total gross wages | ~$1,014,787 |
| Total tips | ~$195,937 |
| Total DRT withholding | ~$37,874 |
| Total net pay | ~$863,063 |

---

*Document owner: Leon Shimizu / Shimizu Technology*  
*Last updated: 2026-03-09*
