This change addresses Cornerstone's feedback about AIRE actions on unrelated clients, obscured report export options, and leftover report instructions. It does not change existing production integration settings.

**Per-client integration setting**

Administrators can open **Client Management → Time tracking** for a specific client, or use **Time Tracking Sources** under Client Settings for the active client. The source form now has an explicit **Enable time tracking integration for this client** control. Save the source to apply it. [View the setting](client-time-tracking-setting.png).

This uses the existing source's `active` setting rather than adding a second company flag. New source forms start disabled; existing saved configurations keep their current setting. There is no database migration and no hardcoded check for company names.

| Client configuration | Payroll behavior |
| --- | --- |
| No enabled source | No new time-import or AIRE-linking action |
| Enabled AIRE source | Draft time import and committed-payroll AIRE linking available |
| Enabled non-AIRE source | Draft time import available; no AIRE-linking action |
| Source disabled with previously applied AIRE batches | Read-only saved records remain available |
| Voided payroll | No new AIRE linking; saved history remains available |

The server supplies current source capabilities and saved AIRE evidence with individual pay-period responses, including mutation responses that replace browser state. Payroll lists do not load this extra history. Disabling a source also blocks applying or reconciling a previously fetched preview. It does not erase records or interrupt payment status acknowledgements for payroll already linked.

**View AIRE Record** now opens saved batch metadata without fetching from AIRE or opening an editable reconciliation workflow. It retains batch identifiers/checksums, cutoff and status timestamps, reconciliation notes, and recorded rounding differences. It works for empty applied batches and inactive sources. Credentials, source URLs, and raw payloads are excluded. Check-delivery wording mentions AIRE only for linked checks.

The source settings component is keyed by client so delayed responses cannot restore the previous client's form after a switch. Administrator-only configuration links match the existing route/API permissions.

**Report exports and copy**

The shared export menu now uses the browser's popover top layer. It escapes card stacking contexts and clipped containers while retaining its position inside modal DOM for focus and accessibility behavior. It clamps/flips within the viewport, supports constrained scrolling and keyboard navigation, follows nested scrolling/resizing, and preserves single-format and busy states. [View the repaired Tax Summary menu](export-menu-fixed.png).

Removed the SCR/AIRE/MHI implementation note from payroll-register JSON, screen preview, and Excel. Removed CEO terminology and the unfinished report-roadmap card. Reworded technical 941/W-2 caveats while preserving manual-entry requirements, rounding qualifications, historical limitations, and all calculation code. Register exception checks remain intact.

New transmittals no longer assume that the client handles EFTPS payments or retirement uploads. Existing saved notes and computed obligation summaries remain. Automatically appended migration provenance no longer becomes a printable recipient note; the source associations remain available for audit. Previously saved documents or operator notes were not rewritten.

**Validation**

- Backend integration run: **421 examples, 0 failures** across pay periods, checks, time-source configuration/imports, finalized-batch application, reports, 941, W-2, and transmittal bootstrap.
- Final follow-up after preserving capabilities in mutation responses and adding its regression: **77 examples, 0 failures**, including all **8** new integration-setting cases and the pay-period request suite.
- Integrated Chromium run: **50 tests passed**, covering the new export/integration scenarios and existing historical-payroll regressions.
- Export component independently passed **7 Chromium and 7 WebKit tests** before integration; its code was then integrated unchanged.
- Frontend gate passed: TypeScript, ESLint, **58 unit tests**, and production build. The existing large-bundle advisory remains; no dependency changes were made.
- Ruby lint checked the changed Ruby files; the new spec's spacing was corrected and its final lint passed. `git diff --check` passed.
- Final client-setting layout was visually inspected and its save/reload browser scenario passed after the layout adjustment.

The browser tests use synthetic API responses. The backend request/service specs validate real report generation and integration behavior against an isolated local test database. These results do not certify current production configuration or complete a live payroll acceptance run.

New regression files: `web/e2e/public-report-download-menu.spec.ts`, `web/e2e/public-report-export-page.spec.ts`, `web/e2e/public-time-tracking-settings.spec.ts`, and `api/spec/requests/api/v1/admin/time_tracking_client_settings_spec.rb`.

PR review follow-up: both import paths now lock the source row within the existing payroll transaction, serializing deactivation with payroll writes. Two PostgreSQL concurrency tests verify that a pending deactivation blocks each operation until it commits and then rejects the stale preview. Saved AIRE timestamps use the shared Guam formatter. Additional tests cover report caveats, saved transmittal notes (including empty notes), calculated notes for new transmittals, and failed previews. All **2,409 backend examples** pass locally, the frontend gate passes, and all **8** additional browser scenarios pass. Brakeman reports no warnings.

The owned test database was removed, browsers closed, and development server stopped. Shared PostgreSQL and all baseline resources were left running.
