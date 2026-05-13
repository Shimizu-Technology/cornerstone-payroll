# Role And Permission Matrix

This document captures the role boundaries after the organization tenant work. The goal is to keep "accounting firm workspace" and "payroll client company" separate, while preserving the payroll workflows that already work for Cornerstone.

## Role Summary

| Role | Scope | Intended Use |
| --- | --- | --- |
| `super_admin` | Platform-wide | Cornerstone platform owner. Can see every organization, create firms, manage organization admins, and help with support across tenants. |
| `org_admin` | One organization | Firm owner/admin for a tenant. Can manage users and client companies inside only their own organization. |
| `admin` | One organization | Legacy admin role. Treated like `org_admin` for now so existing Cornerstone admins keep working during the transition. |
| `manager` | Assigned client companies | Staff role for payroll operations on assigned clients within the user's organization. |
| `accountant` | Assigned client companies | Staff role for accounting/payroll work on assigned clients within the user's organization. |
| `client` | Assigned client companies | Client portal user. Only sees portal-safe workflows for assigned client companies. |
| `employee` | Home company only | Employee/self-service role. Not currently used for firm administration. |

## Access Rules

- `Organization` is the tenant boundary. Users and client companies must belong to exactly one organization.
- `Company` means payroll client company, not accounting firm workspace.
- `current_organization_id` comes from the signed-in user.
- `X-Company-Id` can select an active client only when the current user can access that company.
- `CompanyAssignment` rows must connect a user and company in the same organization. This protects the system even when a platform super admin can see every organization.
- `super_admin` users can access all companies for support and platform administration, but they should not be used for routine payroll processing.
- `org_admin` and legacy `admin` users can manage users and clients only inside their organization.
- `manager`, `accountant`, and `client` users only get access to assigned companies that are still inside their organization.

## Product Notes

- The Organizations screen is intentionally visible only to `super_admin` users.
- The active company switcher is labeled as an active client selector because it changes payroll-client context, not tenant organization context.
- New external accounting firms should be created as organizations, then given at least one `org_admin`.
- The `admin` role should eventually be migrated or renamed once Cornerstone is comfortable with the new organization model.

## Local Smoke Tests

- As a `super_admin`, open Organizations and confirm you can create/edit organizations and invite org admins.
- As an `org_admin` or legacy `admin`, confirm Organizations is hidden and direct navigation is forbidden.
- As an org admin, create a client company and confirm it appears only inside that organization.
- As assigned staff, switch active clients and confirm payroll pages stay scoped to the selected client.
- Confirm payroll calculation, check printing, reports, and taxes still work for an existing Cornerstone client.
