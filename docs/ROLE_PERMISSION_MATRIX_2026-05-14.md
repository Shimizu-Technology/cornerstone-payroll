# Staff role and permission matrix

**Reviewed:** August 23, 2026

This is the approved staff authorization contract for Cornerstone Payroll. The backend policy registry in `api/app/policies/staff_role_policy.rb` is the executable source for high-impact actions. Frontend route and navigation guards mirror it for usability, but the backend remains authoritative.

## Roles and scope

| Role | Scope | Intended use |
| --- | --- | --- |
| `super_admin` | Every organization | Platform recovery, tenant provisioning, and the rare worker tax-classification record transition. Not a routine payroll identity. |
| `org_admin` | One organization | Firm owner/admin. Manages the firm's users, clients, tax rules, integrations, audit history, and organization-wide tools. |
| `admin` | One organization | Legacy alias for `org_admin` until existing Cornerstone accounts are migrated. |
| `manager` | Assigned companies | Payroll manager. Performs payroll work and manages client-specific configuration and sensitive workforce approvals. |
| `accountant` | Assigned companies | Payroll operator. Maintains employees, imports time and payroll evidence, calculates/processes payroll, checks, corrections, reports, transmittals, and other assigned-client operations. |
| `client` | Assigned companies | Portal-safe employee requests, documents, completed pay periods, and approved reports only. |
| `employee` | Home company | Reserved for future employee self-service; it has no staff-console access. |

## Capability matrix

| Capability | Super admin | Org/legacy admin | Manager | Accountant | Client | Employee |
| --- | --- | --- | --- | --- | --- | --- |
| Staff workspace and assigned-client read access | Yes | Yes | Yes | Yes | No | No |
| Assigned-client payroll operations | Yes | Yes | Yes | Yes | No | No |
| Client configuration and sensitive workforce approval | Yes | Yes | Yes | No | No | No |
| Organization administration | Yes | Yes | No | No | No | No |
| Platform administration | Yes | No | No | No | No | No |
| Client portal | No | No | No | No | Yes | No |

“Payroll operations” includes employee maintenance, departments, pay periods and items, imports, calculate/approve/unapprove/commit, checks and corrections, reports and filing preparation, loans, transmittals, portal documents, and assigned-client contact details. This is intentionally available to accountants because it is their core job.

“Client configuration” includes pay schedule/legal workweek confirmation, check stock/layout/sequence, reusable payroll-field definitions, reminder configuration, printer-profile application across companies, employee termination/reactivation and work-profile changes, and approval or rejection of client payroll-sensitive employee changes.

“Organization administration” includes users and invitations, client assignments and creation, audit history, tax configuration and effective-dated pay-component tax rules, external time-source secrets, and the organization-wide invoice center.

## High-impact endpoint contract

Every endpoint below is registered in `StaffRolePolicy` and is enforced by `Admin::BaseController` before the controller action runs:

| Required capability | Endpoint groups |
| --- | --- |
| Platform administration | all organization endpoints; employee tax-classification record transition |
| Organization administration | all user, invitation, company-assignment, audit-log, tax-config, and invoice controllers; client creation; time-source create/update/delete/test; pay-component tax-rule create/update |
| Client configuration | pay-schedule update; payroll-field definition create/update/archive; reminder update/test; check settings and next-number update; apply printer profile to all companies; employee-change review/approve/reject; terminate/reactivate; work-profile create |

Read access remains narrower than a mutation response suggests:

- Managers, accountants, and clients only receive companies assigned within their own organization.
- An `X-Company-Id` outside that set is rejected; it cannot grant access.
- Non-admin staff may update only a client's address, city/state/ZIP, phone, and email. They cannot change EIN, company identity/status, pay frequency, bank/check configuration, or the next check number through the company endpoint.
- Accountants may read client configuration needed to process payroll, but configuration mutations are rejected.
- Managers may inspect non-secret time-source metadata for imports, but only organization admins may create, test, rotate, or deactivate the secret-bearing integration.
- Client users never enter the staff namespace, and staff users do not enter the client namespace.

## Segregation and audit limits

This matrix defines authorization, not a two-person approval control. An authorized payroll operator can currently calculate, approve, and commit the same payroll. If Cornerstone requires preparer/reviewer segregation, add named preparer and approver capabilities plus an explicit “cannot approve your own run” rule; do not infer that control from the `manager` label.

High-impact authorization does not replace company scoping, payroll lifecycle locks, immutable committed records, audit events, or provider-side MFA. All of those controls must pass independently.

## Verification requirements

- The policy spec checks every role/capability pair and confirms every registered action still exists.
- Request specs prove denied mutations do not persist data while permitted read paths remain available.
- The frontend must not advertise client-configuration or sensitive-approval pages to accountants.
- Cross-company and cross-organization request tests remain mandatory.
- Any new high-impact action must be added to the policy registry, this matrix, and focused authorization tests in the same PR.
