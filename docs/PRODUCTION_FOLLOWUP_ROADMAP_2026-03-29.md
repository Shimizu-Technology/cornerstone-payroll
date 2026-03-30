# Production Follow-Up Roadmap - 2026-03-29

## Purpose

This document tracks the next round of production follow-up work for Cornerstone Payroll after initial production rollout and live usage. It captures confirmed issues, product decisions, and implementation priorities so work can proceed in the right order.

Status values:

- `confirmed`: verified with code, logs, or direct runtime behavior
- `needs_product_decision`: direction is not fully settled and should be clarified before implementation
- `planned`: agreed direction, not started
- `in_progress`: actively being implemented
- `resolved`: implemented and verified

## Current Priority Order

1. `confirmed` - Fix user-management scoping so user/admin data is tied to the staff workspace, not the currently selected payroll client.
2. `needs_product_decision` - Finalize the real permission model for `admin`, `manager`, and `accountant`, then make backend and frontend match it.
3. `confirmed` - Reduce production slowness, starting with expensive company-list loading and repeated aggregate work.
4. `confirmed` - Improve employee page behavior: show employee totals, verify/fix search behavior, and remove permission-confusing UI states.
5. `planned` - Add recurring additional earnings support for monthly stipends / monthly bonuses on top of hourly and multi-rate pay.
6. `planned` - Add realtime updates and collaboration improvements after permissions, correctness, and performance are stable.

## Confirmed Findings

### 1. User Management Is Scoped Wrong

- `confirmed` - User Management currently behaves like it belongs to the active payroll client instead of the staff workspace.
- Real-world symptom:
  - creating a user while switched into one client can make the user list appear empty or inconsistent when switching to another client
- Root cause:
  - user-management endpoints were scoped using client-switch context even though users belong to the staff/home company workspace
- Affected areas:
  - `api/app/controllers/api/v1/admin/users_controller.rb`
  - `api/app/controllers/api/v1/admin/company_assignments_controller.rb`
- Desired behavior:
  - User Management should be staff-global for the operator's staff/home company
  - payroll client switching should not change which staff users exist
  - client assignment should control which payroll clients a non-admin staff user can access

### 2. Accountant Permissions Need A Proper Rewrite

- `confirmed` - current backend behavior treats accountants as read-only for most mutating admin actions
- Evidence:
  - production logs show `POST /api/v1/admin/employees` returning `403 Forbidden` from `require_manager_or_admin!`
- `needs_product_decision` - desired product behavior now appears to be:
  - accountants should be able to create and edit employees
  - accountants should be able to do the payroll work they need for assigned clients
  - accountants should not see clients they are not assigned to
  - accountants should not see or access staff-global admin functionality they should not control
- Important note:
  - the current frontend and backend are internally inconsistent
  - some screens imply accountants can manage payroll, but the API still blocks many writes

### 3. Production Feels Slow

- `confirmed` - production requests feel delayed even when query counts are low
- Most likely immediate cause:
  - `api/app/controllers/api/v1/admin/companies_controller.rb` currently loads full employee associations with `includes(:employees)` just to calculate counts
  - employee rows contain encrypted attributes, so loading many employees is expensive even if only counts are needed
- Secondary likely causes:
  - dashboard endpoints do repeated aggregate queries
  - `auth/me` and company-loading flows run frequently on the frontend
- Desired behavior:
  - active client/company list should feel immediate
  - dashboard should load quickly enough that the app feels responsive
  - common admin pages should not feel delayed between clicks

### 4. Employee Page Needs Cleanup

- `confirmed` - employee page should show an employee count even when there is only one page of results
- `confirmed` - employee search needs verification and likely improvement
- Current search risk:
  - multi-word searches like full names may not behave the way operators expect
  - `%` and `_` behave as SQL wildcards in the current `ILIKE` search pattern
- Desired behavior:
  - employee count is always visible
  - searching by first name, last name, full name, or email behaves predictably
  - the list should not show stale results if multiple requests race

### 5. Recurring Additional Earnings Are Needed

- `planned` - the payroll engine already supports one-off `bonus` entries on payroll items
- Current limitation:
  - there is no recurring monthly stipend / monthly bonus setup at the employee level
- Real-world need:
  - some employees receive multi-rate hourly pay plus a fixed monthly amount like `$1,500/month`
- Desired behavior:
  - operators should be able to define recurring additional earnings once
  - the payroll system should place the earning in the correct payroll cycle automatically
  - this should reduce manual entry mistakes

### 6. Realtime / Multi-User Sync Is A Follow-Up Feature

- `planned` - the app does not currently have true live updates for employee/admin/payroll state
- `planned` - there is no current websocket-based collaborative update flow in the frontend
- Important clarification:
  - websockets do not replace server-side authorization, locking, or validation
  - race-condition handling still needs server-side protection even if realtime UI is added

## Product Direction To Lock In

### Staff Role Model

- `needs_product_decision` - recommended direction:
  - `admin`: staff/global admin for users, client assignments, tax config, and other administration
  - `manager`: operational payroll manager for assigned clients
  - `accountant`: operational payroll user for assigned clients, including employee maintenance and payroll processing, but not staff-global administration
- This should be decided before changing multiple controllers independently.

### Staff Workspace vs Client Workspace

- `planned` - separate the concepts clearly:
  - staff workspace: users, assignments, tax configuration, audit/admin operations
  - client workspace: employees, departments, pay periods, payroll runs, reports, client-scoped settings
- Switching active payroll clients should affect client-scoped pages only.

### Recurring Additional Earnings Rules

- `needs_product_decision` - define how recurring earnings should work:
  - earning type label, such as `Monthly Stipend` or `Monthly Bonus`
  - amount
  - frequency
  - effective start and optional end date
  - tax treatment
  - behavior when payroll frequency is not monthly:
    - pay on first payroll of month
    - pay on last payroll of month
    - prorate across payrolls in the month

## Proposed Implementation Plan

### Phase 1 - Immediate Production Fixes

- `planned` - ship the user-management scope fix
- `planned` - replace expensive company list loading with aggregated counts
- `planned` - add visible employee totals on the employees page
- `planned` - improve employee search correctness

### Phase 2 - Permission Model Cleanup

- `planned` - finalize accountant/manager/admin write permissions
- `planned` - enforce the same rules in:
  - backend controllers
  - frontend route guards
  - sidebar navigation
  - page-level create/edit/delete buttons
  - empty states and read-only states
- `planned` - verify accountants only see assigned clients in company switching and client-scoped pages

### Phase 3 - Recurring Additional Earnings

- `planned` - add employee-level recurring additional earnings configuration
- `planned` - support common use cases:
  - monthly stipend
  - recurring bonus
  - fixed monthly leadership pay on top of hourly work
- `planned` - surface these earnings cleanly in:
  - payroll calculation
  - payroll item edit/review
  - check generation
  - pay stubs
  - YTD/reporting totals

### Phase 4 - Realtime And Collaboration

- `planned` - add websocket or realtime subscription support for important shared screens
- `planned` - likely targets:
  - pay period detail
  - employee list
  - user assignments
  - check status / print state
- `planned` - add server-side concurrency protection where needed:
  - optimistic locking or conflict detection for shared edits
  - explicit locking only where financial integrity requires it

## Acceptance Criteria For The Priority Items

### User Management Scope

- switching active clients does not make the user list disappear
- created users always appear in User Management for the correct staff workspace
- client assignments remain editable regardless of the currently selected payroll client

### Performance

- company dropdown loads quickly without hydrating all employee records
- dashboard interactions feel meaningfully faster in production
- common navigation actions do not feel delayed by avoidable backend work

### Accountant Permissions

- accountants can do the allowed operational work for assigned clients
- accountants cannot see unassigned clients in the client switcher
- accountants cannot access staff-global admin pages or actions that are outside their role
- the frontend does not offer actions that the backend will immediately reject

### Employees Page

- total employee count is visible even with one page of results
- searching by full name behaves as operators expect
- search results remain stable while typing and filtering

## Suggested First Work Session

1. Implement and ship the user-management scope fix.
2. Fix `companies#index` performance by removing `includes(:employees)` for list counts.
3. Add employee total count and improve employee search semantics.
4. Then start the permission-model rewrite for accountants and managers.

## Notes

- A local-only patch was previously started to hide employee write flows from accountants, but that should not be pushed if the desired product direction is that accountants can create and edit employees.
- Realtime updates are worth doing, but they should come after the permission model and current production performance issues are stabilized.
