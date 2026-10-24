# PR B bounded code review

Reviewed the working tree at parent HEAD `c8289dfd7f24179112c760e4bd147475bfc649d6` against `origin/staging-v2` (`34c99bb2`), including current uncommitted PayPeriodDetail/Workspace/Summary changes. Read-only source review; no tests, browsers, servers, or databases were started. Code remained unchanged. Findings are source-derived reproduction paths, not claims of browser execution.

Scope: PayRunWorkspace, PayPeriodDetail, ProcessingActions, SupportingDetails, Summary, record header, routing/readonly preservation, payment ownership and refresh seams. Excluded by lead instruction: collapsed steps, compact employee results, first-screen name/net acceptance, Calculate-before-inputs behavior (PR C).

## Review-fix verification — all reported issues closed

Re-inspected the current working tree at HEAD `c8289dfd7f24179112c760e4bd147475bfc649d6` plus the owner's uncommitted fixes. No code changes, tests, browsers, servers, or databases were started by this reviewer. **No material residual finding in this bounded review.** This is source verification of the fixes, not independent execution of the full gate.

- **P2 correction refresh: resolved.** PayPeriodDetail includes `sections.checks.checkPrintRefreshToken` in checksContent options; PayRunWorkspace forwards it as `externalRefreshToken`; its PayRunChecks combines private + external monotonic counters. ChecksPanel, NonEmployeeChecksPanel and the print-queue eligibility effect all observe the effective token. The existing actual-route controller stays mounted. This restores the previously broken correction invalidation seam without recreating duplicate panel ownership.
- **P2 duplicate uncommitted payment actions: resolved.** The writer route passes `showDraftPaymentControls={false}`. Both mobile and desktop Workspace paymentRecords gate their change buttons on committed status or that explicit fallback flag. Uncommitted changes therefore have one reachable control/dialog owner in SupportingDetails; committed changes continue through Workspace. Standalone/fallback behavior remains available.
- **P3 malformed hash: resolved.** decodeURIComponent now executes inside try/catch, and malformed fragments are ignored instead of throwing from the effect.
- **Regression evidence inspected:** PayRunWorkspace.test.tsx adds `refreshes payment instruments after a correction in the persistent controller`, asserts forwarded effective tokens 1 and 2 across tab navigation, and reads the child refresh prop. The owner reports red-before (expected 1, got 0) and 125 focused passing tests after the fix. Those run results are owner-supplied; this read-only reviewer did not execute them.

**Wording/behavior limit:** the retained SupportingDetails PaymentMethodDialog in PayRunReviewDialogs.tsx still calls `loadPayPeriod(payPeriod.id, true)` without the third retainInputs argument. That matches pre-B behavior and can reset unsaved worksheet drafts after a successful method save. The fix restores a single original owner; it should not be described as proving draft preservation for that save path. Tab navigation itself preserves controller state. This unchanged baseline behavior is not reopened as a new B regression.

The original findings and rationale remain below as the review trail. Their proposed alternative fixes are superseded by the verified implementation above.

## Original findings — resolved in review-fix round

### P2 — Workspace payment panels do not observe controller correction refreshes

Locations: `web/src/pages/PayPeriodDetail.tsx:94`; `web/src/pages/pay-periods/PayRunWorkspace.tsx:212` (checks render callback) and its PayRunChecks local state/child refresh props; `web/src/pages/pay-periods/pay-run/PayRunCorrections.tsx:43`.

The richer Workspace PayRunChecks persists across tabs and has a private `checkPrintRefreshToken`. The render callback receives only `searchTerm` and `onChecksLoaded`. A successful correction (notably void) increments **the controller's** `checkPrintRefreshToken`, but that token no longer reaches Workspace's employee/nonemployee/print panels. Previously the extracted PayRunChecks and NonEmployeeChecks consumed this token directly.

Reproduction path: open a committed run / Checks (loads active checks), switch to Activity, successfully void the payroll, then return to Checks. The parent payRun prop updates, but ChecksPanel's data loader only depends on run id and its refresh token (`ChecksPanel.tsx:158,173–176`); changing the PayPeriod object does not reload its check rows. NonEmployeeChecksPanel likewise loads on its own callback/refresh token. Consequently, stale pre-void rows can still show active checks or issue/reissue controls until a full page reload. Server rejection is not a replacement for accurate saved UI state.

Fix: include the controller token in checksContent's context, pass it to Workspace PayRunChecks, and ensure it refreshes ChecksPanel, NonEmployeeChecksPanel, queue eligibility, and the unified package view. Keep the private token for local check actions or combine the two into a stable refresh key. Add a regression that visits Checks, completes a correction through Activity, returns to Checks, and sees refreshed voided/cancelled records without browser reload.

### P2 — Uncommitted payment-method actions now have two owners on the same tab

Locations: `web/src/pages/PayPeriodDetail.tsx:93–95`; `web/src/pages/pay-periods/PayRunWorkspace.tsx:443,467` (responsive paymentRecords actions) and `:570` (PaymentMethodDialog); `web/src/pages/pay-periods/pay-run/PayRunSupportingDetails.tsx:33–59`; `web/src/pages/pay-periods/pay-run/PayRunReviewDialogs.tsx`.

For a non-rehearsal calculated/approved run with positive-net items, Workspace PayRunChecks renders paymentRecords with `Change payment method for {employee}`, then SupportingDetails renders a second payment-method list with the **same** action for that employee. The first opens Workspace's PaymentMethodDialog; the second opens the controller's separate dialog. Previously these two presentations were on different tabs. They are now duplicated in one Checks tab.

Besides repeated controls and repeated employee/method lists, saves take different refresh paths: Workspace calls onChanged and the controller's sibling refresh preserves staged worksheet inputs, while the supporting/controller dialog calls `loadPayPeriod(id, true)` without retainInputs and resets worksheet inputs. Two equivalent-looking buttons can therefore differ in whether unsaved payroll changes survive.

Fix: retain one uncommitted payment-method presentation/dialog owner when the richer Workspace checks slot is supplied. Move needed profile-default guidance/counts into that presentation. Preserve standalone fallback behavior when no checks slot is passed. Add a calculated-run test asserting one visible method-change action per positive-net employee and staged-input preservation through its save path.

## Original advisory hardening — resolved

### P3 — Unchecked fragment decoding can reject a valid route

Location: `web/src/pages/PayPeriodDetail.tsx:44`.

The new hash-navigation effect passes an arbitrary URL fragment to decodeURIComponent without a guard. Opening `/companies/…/pay-runs/…/overview#%` redirects to work and then throws URIError from the effect; malformed percent-encoded UTF-8 has the same result. Ignore an invalid fragment or safely fall back to the raw fragment. Ordinary fixed application-generated anchors work as written. This is an edge-case hardening item rather than a normal-flow release blocker.

## Preservation checks that look sound in the reviewed source

- Writer `overview` and invalid-tab aliases resolve to work and preserve return context and hash. Read-only work renders the summary directly, without mounting the processing controller. Sealed/training Checks links redirect to Payroll; workspace-access reviewers retain Checks; client routes still select unchanged ClientPayPeriodDetail.
- The controller remains mounted through tab changes, preserving worksheet maps/filters. All controller sections share one source of state. Workspace Activity is active-only; other hidden sections retain their component state.
- Operational ChecksPanel, NonEmployeeChecksPanel, and UnifiedCheckPrintDialog have one owner in the actual workspace route; extracted copies are only a no-slot fallback. The nonemployee observer reaches final-record refresh state; Check Settings and the previous employee-check searchTerm are forwarded/restored.
- Header source-review, approval and commit preserve the original financial/approval/source guards. Connected draft source review is a filled Button. Parallel commit remains disabled and explained. Secondary import/setup/rollback/pay-date/link actions remain reachable in overflow.
- Reports, liabilities, notes/history/corrections move to their assigned tabs; totals remain ink/tabular and Net spans both phone columns. Existing blocker text and recovery actions remain in shared Alert wrappers.
- Rehearsal preview, promoted record-only unpaid recovery, mobile/desktop payment records, review dialog, print eligibility and latest-request-wins summary refresh remain in the richer Checks implementation.

No claim of a complete independent review or acceptance gate: this is the requested bounded source review. No task-owned resources required cleanup.


## Owner follow-up after bounded review

The retained delivery-method dialog now reloads with retainInputs=true. A new regression failed before because staged hours reset and passes after; 127 focused tests and the full 1,182-test web gate pass. The release lane also reproduced a draft retaining payroll records that previously depended on writer Overview. Saved payroll records keeps those review buttons reachable on Payroll; the phone release journey opens the existing dialog. These later changes await the lead's final review and are not claimed as independently reviewed by the read-only agent.
