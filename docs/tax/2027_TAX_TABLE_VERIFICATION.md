# 2027 payroll tax table verification pack

Prepared 2026-11-26 from `origin/main` at `3ee8d41e5`. Research only: no tax configuration was changed and nothing was recorded in production.

## Needs a code change before verification

**None.** No 2027 value stored in the app differs from a published official value.

Two things still block verification. Neither needs a code change; an administrator enters both in the app:

1. **The 2027 federal income tax withholding tables are empty.** The 2027 draft seed holds only Social Security and Medicare values (`api/db/seeds/tax_config_2027_draft.rb:5-17`). The app refuses verification until all three filing statuses have complete tables (`api/app/models/annual_tax_config.rb:130-132`).
2. **No 2027 retirement (401(k)) limits are stored.** The only seeded year is 2026 (`api/db/seeds.rb:11-20`). Readiness doesn't check these limits, but any 2027 payroll with a 401(k) deduction stops with "Retirement limits are not configured for 2027" (`api/app/services/payroll_retirement_calculation.rb:93-100`).

## Summary for the CEO

Every 2027 number the app holds today is right. The Social Security wage base ($192,300), the 6.2% and 1.45% rates, and the 0.9% Additional Medicare Tax above $200,000 match the SSA announcement and the IRS's draft 2027 Publication 15. Two pieces are still missing. The first is the 2027 income tax withholding tables. The IRS released an early draft of Publication 15-T on November 12, 2026, with the 2027 tables in an Excel attachment, and the final version usually follows in December. The second is the 2027 401(k) limits. The IRS finalized those on November 12 (Notice 2026-66), so they can be entered now. Guam has no separate tables: the app applies the federal Publication 15-T tables as Guam Territorial Income Tax, and FUTA doesn't apply to Guam employers. To clear the readiness check, enter the withholding tables from the final Publication 15-T (or from the draft if January payroll can't wait, then re-check against the final). Then record verification on the Tax Configuration page. A super administrator enters the 401(k) limits on the same page.

## How the app defines "verified"

- Each tax year is one `AnnualTaxConfig` row with `verification_status` of `draft` or `verified`, plus `verified_by` (user ID), `verified_at` and `source_references` (`api/db/migrate/20261024093000_add_tax_configuration_verification.rb:5-9`).
- Payroll for a year runs only if that year's row is `verified` (`api/app/models/annual_tax_config.rb:101-110`). Years after 2026 can't fall back to the legacy tables.
- `verify!` (`api/app/models/annual_tax_config.rb:126-140`) requires:
  - an organization administrator: super admin, admin or org admin (`api/app/models/user.rb:157-159`);
  - a source note that isn't blank;
  - complete withholding brackets for single, married and head of household, starting at $0 with no gaps and an open top bracket (`api/app/models/annual_tax_config.rb:142-150`);
  - a review token matching the values on screen. If anyone changed the tables after you opened the page, the app makes you reload first.
- Changing any rate, wage base, deduction or bracket afterwards resets the year to `draft` (`api/app/models/annual_tax_config.rb:170-176`, `api/app/models/filing_status_config.rb:18`, `api/app/models/tax_bracket.rb:12`).
- The readiness check lists every year that is current, within the next 60 days, or the pay date of an uncommitted pay period, and flags any that aren't verified (`api/app/services/tax_year_readiness.rb:10-24`, `api/app/services/production_readiness.rb:269-271`).
- Verification is recorded in the tax configuration audit log (`api/app/controllers/api/v1/admin/tax_configs_controller.rb:55-69`).

## Comparison table

Status key: **Matches**, **Differs**, **Not yet published** (the final official document isn't out yet), **Missing in app** (the official value is published but the app has no value), **N/A** (the app doesn't use it).

### Social Security, Medicare and FUTA

| Item | App value (2027) | Official 2027 value | Source | Status |
|---|---|---|---|---|
| Social Security wage base | $192,300 (`api/db/seeds/tax_config_2027_draft.rb:7`) | $192,300 | SSA 2027 COLA announcement, Oct 2026 ([cbb.html](https://www.ssa.gov/OACT/COLA/cbb.html), [2027 fact sheet](https://www.ssa.gov/news/en/cola/factsheets/2027.html)); IRS draft Pub 15 (2027), dated Oct 14, 2026, "What's New" ([p15--dft.pdf](https://www.irs.gov/pub/irs-dft/p15--dft.pdf)) | Matches |
| Social Security rate (each, employee and employer) | 6.2% (`:8`) | 6.2% | Draft Pub 15 (2027), "What's New" | Matches |
| Medicare rate (each) | 1.45% (`:9`) | 1.45%, no wage limit | Draft Pub 15 (2027), "What's New" | Matches |
| Additional Medicare Tax rate (employee only) | 0.9% (`:10`) | 0.9% | Draft Pub 15 (2027), section 9; statutory | Matches |
| Additional Medicare withholding threshold | $200,000 (`:11`) | $200,000, not indexed | Draft Pub 15 (2027), section 9 | Matches |
| FUTA | Not applied; the QuickBooks importer treats it as not a Guam liability (`api/app/services/quickbooks_history/bundle_parser.rb:984`) | Doesn't apply to employers in Guam | Draft Pub 15 (2027), section 14: "FUTA tax doesn't apply to employers in American Samoa, Guam, and the CNMI" | Matches |

The SSA pages refused automated download (HTTP 403), so the $192,300 figure was confirmed from the IRS draft Pub 15 and the SSA Federal Register notice ([2026-21796](https://public-inspection.federalregister.gov/2026-21796.pdf)). Open the SSA page in a browser for a final look.

### Federal income tax withholding (Pub 15-T, Worksheet 1A, 2020+ Form W-4)

The app stores one row per filing status. `standard_deduction` holds the Worksheet 1A line 1g adjustment, and the brackets are the **STANDARD** annual percentage-method schedule, entered as `from / to / rate`.

Official values below come from the Excel attachment ("2027 Pub 15-T numbers only.xlsx", sheet "1B % Method Tables - Automated") in the **early release draft** of the 2027 Pub 15-T ([p15t--dft.pdf](https://www.irs.gov/pub/irs-dft/p15t--dft.pdf), page dated Nov 9, 2026, posted about Nov 12, 2026). The tables printed inside that PDF are **not** 2027 figures: each one is marked "This illustrates what the 2027 tables would look like by using the 2026 tax parameters." The Excel figures tie exactly to Rev. Proc. 2026-35, released Nov 5, 2026 ([rp-26-35.pdf](https://www.irs.gov/pub/irs-drop/rp-26-35.pdf)): standard deductions of $16,600, $33,200 and $24,925, and the section 1(j) rate tables. The IRS says a second early release draft, with the tables in the publication itself, will follow. Before 2026 the final Pub 15-T came out in December, so expect it in **December 2026**.

| Item | App value (2027) | Official 2027 value (draft) | Source | Status |
|---|---|---|---|---|
| Worksheet 1A adjustment, single / married filing separately | None | $8,600 (unchanged) | Draft Pub 15-T (2027), Worksheet 1A line 1g | Not yet published (final); app empty |
| Worksheet 1A adjustment, married filing jointly | None | $12,900 (unchanged) | Same | Not yet published (final); app empty |
| Worksheet 1A adjustment, head of household | None | $8,600 (unchanged) | Same | Not yet published (final); app empty |
| STANDARD schedule, single | None | See table A | Draft Pub 15-T Excel | Not yet published (final); app empty |
| STANDARD schedule, married filing jointly | None | See table A | Same | Not yet published (final); app empty |
| STANDARD schedule, head of household | None | See table A | Same | Not yet published (final); app empty |
| Step 2 checkbox schedules (all statuses) | Not stored; derived (see note) | See table B | Same | Not yet published (final); derivation matches draft |
| Pre-2020 Form W-4 allowance ($4,300) | N/A: pre-2020 W-4s are rejected (`api/app/models/employee.rb:21`, `api/app/services/guam_tax_calculator_v2.rb:43-45`) | $4,300 | Draft Pub 15-T Excel | N/A |

**Table A: entries for "Enter withholding tables" (STANDARD schedule, annual)**

Enter rates as decimals. Leave the final "To" empty.

| Single / MFS (adjustment $8,600) | Married filing jointly (adjustment $12,900) | Head of household (adjustment $8,600) |
|---|---|---|
| 0 – 8,000 @ 0.00 | 0 – 20,300 @ 0.00 | 0 – 16,325 @ 0.00 |
| 8,000 – 20,800 @ 0.10 | 20,300 – 45,900 @ 0.10 | 16,325 – 34,575 @ 0.10 |
| 20,800 – 60,025 @ 0.12 | 45,900 – 124,350 @ 0.12 | 34,575 – 85,975 @ 0.12 |
| 60,025 – 117,125 @ 0.22 | 124,350 – 238,550 @ 0.22 | 85,975 – 125,425 @ 0.22 |
| 117,125 – 216,325 @ 0.24 | 238,550 – 436,950 @ 0.24 | 125,425 – 224,625 @ 0.24 |
| 216,325 – 272,550 @ 0.32 | 436,950 – 549,400 @ 0.32 | 224,625 – 280,875 @ 0.32 |
| 272,550 – 669,375 @ 0.35 | 549,400 – 813,950 @ 0.35 | 280,875 – 677,675 @ 0.35 |
| 669,375 – (no limit) @ 0.37 | 813,950 – (no limit) @ 0.37 | 677,675 – (no limit) @ 0.37 |

Spot check from the draft's "tentative amount" column: single at $20,800 shows $1,280 (= 12,800 × 10%), and married at $124,350 shows $11,974.

**Table B: Step 2 checkbox schedule (draft, for reference only; not entered in the app)**

| Single / MFS | Married filing jointly | Head of household |
|---|---|---|
| 0 – 8,300 @ 0% | 0 – 16,600 @ 0% | 0 – 12,462.50 @ 0% |
| 8,300 – 14,700 @ 10% | 16,600 – 29,400 @ 10% | 12,462.50 – 21,587.50 @ 10% |
| 14,700 – 34,312.50 @ 12% | 29,400 – 68,625 @ 12% | 21,587.50 – 47,287.50 @ 12% |
| 34,312.50 – 62,862.50 @ 22% | 68,625 – 125,725 @ 22% | 47,287.50 – 67,012.50 @ 22% |
| 62,862.50 – 112,462.50 @ 24% | 125,725 – 224,925 @ 24% | 67,012.50 – 116,612.50 @ 24% |
| 112,462.50 – 140,575 @ 32% | 224,925 – 281,150 @ 32% | 116,612.50 – 144,737.50 @ 32% |
| 140,575 – 338,987.50 @ 35% | 281,150 – 413,425 @ 35% | 144,737.50 – 343,137.50 @ 35% |
| 338,987.50+ @ 37% | 413,425+ @ 37% | 343,137.50+ @ 37% |

**Note on Step 2 and the 2027 calculation method (no value difference).** The exact Pub 15-T method, with a stored Step 2 table, is switched on only for the official 2026 configuration (`api/app/services/guam_tax_calculator_v2.rb:39-40`, `api/app/models/annual_tax_config.rb:212-214`). For 2027 the engine uses its older progressive method (`api/app/services/guam_tax_calculator_v2.rb:204-212`). For employees with the Step 2 box checked, that method halves the Worksheet 1A adjustment and halves every bracket boundary (`:376-394`). Applied to table A, this gives table B exactly: for single, $8,600 ÷ 2 + $8,000 ÷ 2 = $8,300, and $8,600 ÷ 2 + $60,025 ÷ 2 = $34,312.50. Withholding should therefore match the draft. Two small effects remain:

- If the final Pub 15-T rounds the Step 2 boundaries, as the 2026 final did ($108,938 rather than $108,937.50), results can differ by under one cent per paycheck.
- 2027 paycheck records will show `withholding_method: legacy_progressive` with no Pub 15-T source, where 2026 records show `irs_pub_15_t_worksheet_1a_2026`.

Neither changes a tax amount or blocks verification. A follow-up could extend the Pub 15-T method and its source label to 2027 if an exact audit trail is wanted.

### Retirement plan limits

These are stored per year in `AnnualRetirementLimit`, separate from tax-year verification. The official values come from IRS Notice 2026-66, published Nov 12, 2026 ([n-26-66.pdf](https://www.irs.gov/pub/irs-drop/n-26-66.pdf); [IR-2026-136](https://www.irs.gov/newsroom/401k-limit-increases-to-25500-for-2027-ira-limit-remains-7500)). This notice is final.

| Item | App value (2027) | Official 2027 value | Source | Status |
|---|---|---|---|---|
| 402(g) elective deferral, 401(k)/403(b)/457(b) | None (2026 is $24,500) | $25,500 | Notice 2026-66 | Missing in app |
| Age 50+ catch-up, 414(v)(2)(B)(i) | None (2026 is $8,000) | $8,500 | Notice 2026-66 | Missing in app |
| Ages 60–63 catch-up, 414(v)(2)(E)(i); replaces the age-50 amount | None (2026 is $11,250) | $11,750 | Notice 2026-66 | Missing in app |
| Roth catch-up wage threshold, 414(v)(7)(A), tested on **2026** FICA wages | None (2026 is $150,000) | $155,000 | Notice 2026-66 | Missing in app |
| 415(c) annual additions | None (2026 is $72,000) | $75,000 | Notice 2026-66 | Missing in app |
| 401(a)(17) compensation limit | None (2026 is $360,000) | $375,000 | Notice 2026-66 | Missing in app |
| SIMPLE plan limits ($17,500 / $19,100 deferral; $4,000 / $3,850 / $5,250 catch-up) | N/A: the app calculates standard 401(k) plans only (`api/app/services/payroll_retirement_calculation.rb:105-108`) | Published | Notice 2026-66 | N/A |

The 2026 row has the same layout (`api/db/seeds.rb:11-20`), so 2027 is a straight data entry.

### Other benefits

| Item | App value | Official 2027 value | Source | Status |
|---|---|---|---|---|
| Health FSA salary reduction limit / carryover | N/A: not modeled | $3,500 / $700 | Rev. Proc. 2026-35, section 125(i) | N/A |
| HSA contribution limits | N/A: not modeled | Not researched; the app has no HSA limit | n/a | N/A |

### Guam

The app treats Guam income tax withholding as the federal Pub 15-T tables applied as Guam Territorial Income Tax (`api/app/services/guam_tax_calculator_v2.rb:1-12`, `api/db/seeds.rb:26`). Pub 15 tells employers in Guam to contact their local tax department about income tax withholding (draft Pub 15 (2027), section 7 caution). There is no Guam-specific 2027 table in the app and none is needed beyond the federal tables. FICA applies in Guam as in the states; FUTA does not. Before verifying, it's worth a short check that Guam Department of Revenue and Taxation guidance for 2027 still points to Pub 15-T. This pack didn't check that.

### Counts

| Status | Count | Items |
|---|---|---|
| Matches | 6 | SS wage base, SS rate, Medicare rate, Additional Medicare rate, Additional Medicare threshold, FUTA |
| Differs | 0 | — |
| Not yet published (final) | 7 | Three Worksheet 1A adjustments, three STANDARD schedules, the Step 2 schedules (the draft is available for all seven, and the app has none entered) |
| Missing in app (officially published) | 6 | 2027 401(k) limits from Notice 2026-66 |
| N/A | 4 | Pre-2020 W-4 allowance, SIMPLE, health FSA, HSA |

## Click path to record 2027 verification

Who can do it: **verifying the tax tables** needs an organization administrator (super admin, admin or org admin). **Entering 401(k) limits** needs a super administrator, and the button is hidden in a test workspace (`api/app/controllers/api/v1/admin/annual_retirement_limits_controller.rb:7-12`).

1. Sign in to Cornerstone Payroll. In the sidebar, open **Tax Configuration** (`/settings/tax-config`).
2. In the tax-year list, find **2027** and click **View details**. The header reads "2027 · Draft — payroll blocked".
   - If there is no 2027 row, click **Add tax year** and create 2027 **without** copying 2026. Copying would bring over 2026's $184,500 wage base. Then use **Tax Rates & Thresholds** to set the five values in the first table above.
3. In **Compare with the prior year**, check the five Social Security and Medicare values against the first table above.
4. Click **Enter withholding tables**. For **single**, **married** and **head of household**, enter the "Annual deduction / worksheet adjustment" and the brackets from table A. Use **Add … bracket** to add rows, use decimal rates, and leave only the last "To" empty. Click **Save draft tables**. The year stays in draft.
5. Expand each of the three **withholding comparison** sections and check every row against table A, or against the final Pub 15-T if it's out.
6. In **Verification source note (required)**, enter something like: "2027 verified [date] by [name]: SSA 2027 COLA $192,300; Pub 15 (2027) rates; Pub 15-T (2027) [final / early release draft dated Nov 9, 2026] Worksheet 1A adjustments and STANDARD schedules for single, married and head of household; Rev. Proc. 2026-35. URLs: https://www.ssa.gov/OACT/COLA/cbb.html https://www.irs.gov/publications/p15t https://www.irs.gov/pub/irs-drop/rp-26-35.pdf".
7. Click **Verify 2027 tax tables**. If the app says the tables changed after you opened them, click **Reload values for review**, check again, and verify.
8. Super administrator: at the top of the same page, in **Annual 401(k) limits**, click **Add IRS retirement limits**. Enter tax year 2027, $25,500, $8,500, $11,750, $155,000, $75,000 and $375,000. Use source name "IRS Notice 2026-66" and source URL `https://www.irs.gov/pub/irs-drop/n-26-66.pdf`, add a reason, and click **Save retirement limits**.
9. Recalculate any 2027 draft payrolls before approval. The page prompts for this. Re-run the production readiness check: the "2027 payroll tax tables are verified" line should now pass.

## What to re-check when the final 2027 Pub 15-T is released

Expected in December 2026, at <https://www.irs.gov/publications/p15t>.

1. **Every boundary in table A, for all three statuses.** If any differs from the draft, correct it through **Enter withholding tables**. Saving a change resets the year to draft, so it has to be verified again. Then recalculate any 2027 payroll calculated in the meantime.
2. **Worksheet 1A line 1g is still $12,900 (married filing jointly) and $8,600 (all others).**
3. **The Step 2 checkbox tables match table A ÷ 2 plus half the adjustment** (table B). If the final rounds the boundaries, the difference is under one cent per paycheck. If it changes the method itself, open a code change.
4. **The tax-rate brackets still tie to Rev. Proc. 2026-35.** A law change after November 5 would show up here.
5. **Nothing new in Worksheet 1A** that the app doesn't handle, such as a new W-4 step or a new 2027 Form W-4 field.
6. **The final Pub 15 still shows $192,300, 6.2%, 1.45%, 0.9% above $200,000, and the Guam FUTA exclusion.**
7. **Update the source note** to cite the final publication if you verified from the draft. Re-verifying with an unchanged table needs no data edits, but changing a value does.
