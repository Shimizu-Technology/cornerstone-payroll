# Incomplete employee entry

Implementation: [PR #310](https://github.com/Shimizu-Technology/cornerstone-payroll/pull/310). The final PR release comment records the merge revision and deployment verification.

## Scope and behavior

Full employee details remain required by default. In the selected client's Employees page, an organization or system administrator can allow incomplete entry for 1, 4, or 24 hours with a reason. The server enforces expiry; the administrator can restore strict entry immediately. The window does not authorize payroll payments or waive documents.

Name, valid worker classification, pay basis, rate and frequency remain required. During the window, SSN (or a business contractor's EIN), hire date, address parts and the initial employee withholding election can be deferred. Business contractors still need their legal business name. Supplied identifiers are validated; a supplied SSN still requires confirmation on manual entry. Unknown values remain blank.

Each admitted employee retains the authorized missing fields, reason, authorizing administrator, creator, follow-up owner and due date. The creator owns follow-up initially, due seven days after entry. Employees show Profile incomplete and a missing-information checklist; staff can filter the roster by incomplete profiles. Restoring strict intake governs new entries while approved gaps on existing employees remain editable incrementally. Completed values cannot be cleared under the original exception.

## Payroll and reporting

Employee profile completeness, payroll-setup review, document readiness and filing readiness are separate decisions. A manager or administrator reviews the incomplete employee's pay setup and earliest payroll participation before that employee is eligible for payroll. Missing hire dates do not automatically admit the person to prior runs. Changes that materially affect reviewed payroll setup invalidate that review.

When an employee withholding election is absent, initial entry does not manufacture a dated election. A manager can explicitly authorize default single withholding with zero credits/adjustments, a reason and effective date. This is stored as default_withholding and remains distinguishable from an employee-supplied election. Receiving the employee election resolves the outstanding profile item. This software workflow does not itself establish that a firm's withholding decision or document waiver is appropriate.

New manual, client-request and bulk-import employee entry seed the same applicable document checklist. Client-created employees remain inactive pending staff approval. Operators can record document receipt; managers/admins verify, reject or waive with a reason. An operator cannot downgrade a reviewed item to evade that permission rule. No entry window or payroll-setup confirmation automatically satisfies documents.

Payroll approval and commitment preserve document readiness, financial lifecycle locks and current calculation requirements. Standard checks omit missing address lines. W-2GU filing readiness continues to block missing SSNs and incomplete addresses. Completing a profile does not recalculate committed payroll; generated check packages retain their existing freshness checks.

Existing legacy employees and QuickBooks historical review exceptions are not retroactively placed into this intake workflow.

## Verification and rollout

The critical acceptance journey is administrator enablement, operator minimal entry, restoration of strict entry, incremental completion of the admitted record, rejection of a new incomplete record, explicit payroll review, separate document review, and normal payroll/check/filing behavior. Verify role and company boundaries, expiry during an open form, invalid supplied values, reviewed-field changes, client approval and bulk import.

Use synthetic, disposable local data for browser and payroll verification. Required backend/frontend/browser CI checks and actual reviewer coverage must pass before merge. Migration is additive; all production settings begin strict. Netlify publishes the frontend from main; Render deploys API/worker from main and the API runs db:safe_prepare before release. Verify the merged revision on all three deployments, migration success, /up, /health/dependencies and new runtime errors. No production payroll or external sends are needed to verify this rollout.

Implementation/verification evidence is recorded in the PR. Merged code and synthetic tests do not establish operator acceptance or filing readiness.
