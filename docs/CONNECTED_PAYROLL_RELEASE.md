# Connected Payroll Release

## Outcome

This release makes the payroll operations that already exist feel like one connected system. It does not change payroll calculations, tax rules, filing logic, check numbering, or database relationships.

The defining journey is:

```text
filtered pay-run queue
  -> pay-run workspace
  -> employee workspace
  -> exact payroll item / paycheck
  -> source pay run and check context
  -> original filtered queue
```

## User-facing records

| Record | Stable identity | Required scope | Canonical route | Primary roles |
|---|---|---|---|---|
| Employee workspace | `employee_id` | Company | `/companies/:companyId/employees/:employeeId/:tab` | Staff |
| Pay-run workspace | `pay_period_id` | Company | `/companies/:companyId/pay-runs/:payPeriodId/:tab` | Staff |
| Payroll item / paycheck | `payroll_item_id` | Company + pay run | `/companies/:companyId/pay-runs/:payPeriodId/payroll-items/:payrollItemId` | Staff |

Employee and pay-run list routes are also company-scoped so a copied URL cannot silently depend on whichever client was last selected in local storage.

## Route contract

```text
/companies/:companyId/employees
/companies/:companyId/employees/new
/companies/:companyId/employees/:employeeId/overview
/companies/:companyId/employees/:employeeId/pay-setup
/companies/:companyId/employees/:employeeId/pay-history
/companies/:companyId/employees/:employeeId/activity
/companies/:companyId/employees/:employeeId/edit

/companies/:companyId/pay-runs
/companies/:companyId/pay-runs/:payPeriodId/overview
/companies/:companyId/pay-runs/:payPeriodId/work
/companies/:companyId/pay-runs/:payPeriodId/checks
/companies/:companyId/pay-runs/:payPeriodId/activity
/companies/:companyId/pay-runs/:payPeriodId/payroll-items/:payrollItemId
```

Legacy `/employees*` and `/pay-periods*` paths remain compatibility entry points. They resolve to the active authorized company and preserve their query string.

## Relationship coverage

| From | To | Forward path | Reverse path | Context preserved |
|---|---|---|---|---|
| Employee queue | Employee | Open exact employee workspace | Back to employees | Search, status, department, employment type, sort, page |
| Employee | Pay run | Pay-history row | Employee link from pay run and payroll item | Employee tab and originating queue |
| Pay-run queue | Pay run | Open exact run | Back to pay runs | Search, status, year, sort |
| Pay run | Employee | Employee name/context action | Pay-history and recent-pay links | Pay run and active workspace tab |
| Pay run | Payroll item | Open exact payroll result | Pay-run and employee links | Originating run tab/list |
| Payroll item | Check context | Check identity and lifecycle on the record | Payroll item remains canonical | Pay run and employee scope |

## Safety boundaries

- Every API read continues to enforce the current company on the server.
- Route scope is synchronized only after the requested company is confirmed in the authorized company list.
- Invalid, unavailable, or unauthorized company routes render a safe state and do not issue scoped record requests.
- `return_to` accepts only same-origin absolute application paths; protocol-relative and external URLs are rejected.
- Client portal behavior remains on its existing read/edit surfaces. The connected workspaces are staff operational records.
- No payroll arithmetic, tax, filing, check mutation, or persistence behavior changes in this release.

## Acceptance matrix

| Concern | Acceptance check |
|---|---|
| Stable address | Refreshing an employee, pay run, or payroll item restores the same scoped record. |
| Forward relationship | A payroll result opens the exact employee and exact payroll-item records. |
| Reciprocal relationship | Employee pay history links to its pay run and payroll item; the payroll item links back to both. |
| Return context | Returning from a record restores list filters and workspace context. |
| Company identity | A company-scoped route selects only an authorized company and never silently opens the record under another client. |
| Authorization | Cross-company employee, pay-run, payroll-item, and report reads return a safe not-found response. |
| Missing record | Missing or stale links render a clear retry/back state without leaking another company record. |
| Accessibility | Record links have explicit names, tabs are keyboard reachable, focus is visible, and primary targets meet the 44px mobile target. |
| Responsive behavior | Workspaces remain navigable at desktop and phone widths without hiding record identity or return actions. |
| Regression | Existing payroll calculation, approval, rollback, commit, and post-commit protections remain green. |

## Deliberately deferred

- A firm-wide multi-client work queue
- First-class compliance-obligation records
- Universal record search and activity indexing
- First-class routes for every report, document, invoice, transmittal, and message
- Broad schema changes or a graph database
