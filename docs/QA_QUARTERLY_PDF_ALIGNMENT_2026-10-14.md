# Quarterly draft PDF alignment

Actual Form 941 download review found that lines 6, 7, 10 and 12 were printed one official row too high. Line 6 appeared in 5f; a negative one-cent adjustment appeared on line 6 without its minus sign. The on-screen calculations were correct.

The overlay now uses the labeled fields in the [IRS Form 941, Rev. March 2026](https://www.irs.gov/pub/irs-pdf/f941.pdf). The current IRS download matches the stored template exactly (SHA256 `38a3d8cf7a455101d52543c8c48e66202bc25c189ead878627e35c797c88e2ad`). No government asset, tax calculation, recorded withholding, readiness decision or filing state changes. The [IRS instructions](https://www.irs.gov/instructions/i941) require a minus sign for adjustments that decrease tax; the shared dollar/cents formatter preserves it for amounts between zero and minus one dollar.

| Example | Line 6 | Line 7 | Lines 10 and 12 | Review state |
|---|---:|---:|---:|---|
| Negative cents | 3.06 | -0.01 | 3.05 | The remaining -0.01 residual still requires review. |
| Positive cents | 15.30 | 0.01 | 15.31 | The remaining 0.01 residual still requires review. |

Unprovided lines 5f, 8, 9 and 11 remain blank. Reviewed overrides use their own labeled fields. Page 2 monthly liabilities and Schedule B daily/monthly totals retain their existing positions.

Form 941 output was already a static overlay with no canonical AcroForm, but retained blank source input annotations. Its output now removes only those Widget annotations, preserving other annotations and links. The source template remains interactive and unchanged. All six negative/positive Form 941 page rasters are identical with or without this cleanup. Other quarterly templates retain their existing annotation behavior; a broader cleanup prototype was narrowed after it removed the SW-2 source button graphics.

New regressions locate generated text in the immutable source template's named field rectangles, cover negative and positive adjustments, untouched neighboring fields, reviewed overrides, all three Form 941 pages, monthly liabilities and Schedule B totals. Render-only synthetic PDFs include both Form 941 examples, Schedule B, W-1 and a two-page SW-2; every page was inspected. These documents establish layout behavior, not an actual payroll or filing journey.

Root-owned desktop and 390px acceptance remains required: download and open the actual quarterly exports, compare screen/XLSX/PDF and saved ledger values, preserve edited values and return context, and confirm the residual still prevents unsupported readiness. Drafts remain marked NOT FILED. Agency filing and production data changes are outside this slice.
