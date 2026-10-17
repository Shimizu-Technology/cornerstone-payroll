# Official Form 941 tax-year scope

An actual 2025 Q2 draft download used a filename for 2025 but printed 2026 in the official Form 941 header and payment voucher. Cornerstone currently bundles only the March 2026 IRS template. Its official Form 941 PDFs now support tax year 2026 only.

The generator owns the supported-year list and availability message. The report API supplies that metadata, and the interface offers the official PDF and complete PDF packet only after availability is confirmed. Unsupported requests return HTTP 422 with a clear route to the worksheet, reconciliation workbook and matching IRS revision. The guard covers standalone and packet PDFs, edited previews/downloads and editable Form 941 defaults. Direct generator calls cannot bypass it with edited fields.

Historical worksheet/report data and Excel exports remain available. Schedule B, Guam W-1 and SW-2 use their existing dynamic-year fields and retain their individual exports. No IRS asset, PDF layout, tax calculation, filing responsibility rule, payroll amount or source history changes in this repair. Supporting another year requires a separately verified official template and mapping; changing the printed year on the 2026 form is insufficient.

The IRS [2025 instructions](https://www.irs.gov/pub/irs-prior/i941--2025.pdf) identify the March 2025 revision for 2025. The [2026 instructions](https://www.irs.gov/instructions/i941) identify the March 2026 revision for 2026 and link to prior revisions.

Regression coverage includes all six entry points for 2025 and 2027, empty historical worksheets/workbooks, other prior-year government PDFs, supported 2026 standalone/packet generation, zero filing/payroll mutations and server-derived interface availability across year changes. Existing Form 941 coordinate/sign regressions remain required. Root's actual desktop and 390px export, context recovery and saved-outcome checks remain release gates; automated tests alone do not prove those journeys.
