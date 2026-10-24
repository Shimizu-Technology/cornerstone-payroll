# Pay-run redesign C

Owner: `payroll-redesign`. Application source: `36b291d1` (UI logic/layout in `5a6e9754`, count labels in `04fd3b86`); integrates staging-v2 `ce12d1da` (#385). Lead reviews and merges. PR A #383 and PR B #384 are already merged.

Payroll now follows Hours → Results → Approve & commit. Saved status chooses the current step; disclosure state only changes what the accountant inspects. Committed runs keep Results open for post-commit review. Hours and commitment collapse to a saved summary. Adjustment and late-hours runs state their selected-employee scope; parallel runs explain that commitment is unavailable.

Hours contains one compact source checkpoint, coverage acknowledgement and the existing late-hours banner and entry. Source/calendar/batch/payment details remain in disclosures. The default results table shows employee, hours, gross, deductions, net, flags and Details. Show tax detail persists across reloads and restores the existing full table, including its custom pay, source and payment controls. Phone results are cards with name and net together; Filters uses the shared phone sheet.

Amounts come from saved payroll items. Neither the compact table nor header re-derives earnings from hours/rates. Filtered footer totals are identified. Existing calculation, approval, commitment, client review, correction and permission guards remain. All four tabs, read-only summary, read-only Reports and overview/client routes retain their contracts.

The lead’s four findings and CodeRabbit’s four findings are addressed in [review round 1](REVIEW-1.md). The header is the single filled primary; in-step actions stay available as secondary controls. Flags have a wider wrapping column and Details/menu retain separate space. Filters use compact selects and a growing search field. Feedback appears and receives focus in the current step, and loan conflicts link to their inputs.

## Evidence

- [Desktop contact sheet](contact-1280.jpg) and [phone contact sheet](contact-390.jpg): seven matched before/after states.
- [Measurements](MEASUREMENTS.md), including original-audit comparisons in [JSON](measurements.json).
- [Every original action and its location](ACTIONS.md), [raw before](actions-before.json), [raw after](actions-after.json), [normalized diff](actions-location-diff.json), [source before](source-actions-before.json), [source after](source-actions-after.json) and [guarded component hashes](retained-action-components.json).
- [Viewport acceptance](viewport-acceptance.json): 18 passed checks across nine states and two widths. First desktop rows show name and net together; every phone current-step action fits the first viewport; no page overflow. Flag text stays inside its cell.
- [Interaction checks](interaction-results.json): tax preference/keyboard/frame stability, employee-dialog focus, phone filters, overview query alias, permission-guarded late-hours dialog and return navigation at both widths.
- [Saved outcomes](saved-outcomes.json): calculate, recalculate, approve and commit on desktop/phone, each verified against the saved API after reload; four normal/reduced-motion dialog checks.
- [Read-only Reports](readonly-results.json): 12 direct/navigation scenarios across workspace reviewer, backup snapshot and training baseline; permitted GET reports work and no writer controls, forbidden POSTs or 403s appear.
- [Axe summary](axe-summary.json). Required #377 families have zero violations. Remaining advisories are the existing shell/account-menu/tab label naming, phone shell region and Hours worksheet's interactive collapse header. Compact Details naming was fixed. This is a family-scoped clean result, not an assertion that every advisory rule passes.
- [Impeccable 4.6.0](impeccable.json): no findings.

Full logs, raw axe results, seed/capture/inventory scripts, six WebM recordings and earlier red attempts are in `/Users/leonshimizu/Desktop/ShimizuTechnology/output/payroll-aire-review-2026-10-24/impl/payroll-redesign/pr-c/`. Recordings are `recordings/steps-totals-{1280-no-preference,390-reduce}.webm` and `recordings/dialog-{1280,390}-{no-preference,reduce}.webm`. Changed-total opacity was recorded at 600 ms normal / 150 ms reduced; structural effects use 150 ms.

Headless Chromium used 1280×800 and 390×844, copied local payroll/AIRE fixtures and synthetic records. These are agent-executed checks. No physical device, printer, live provider/payment/filing/email operation, successful connected import, late-hours financial execution or separate two-app certification is claimed. The financial saved-outcome check uses fresh manual runs; connected fixtures retain their actual source/provenance guards. No API implementation, migration, schema, dependency or deployment change belongs to C. Backend specs were not rerun under the lead's explicit web-only C gates.
