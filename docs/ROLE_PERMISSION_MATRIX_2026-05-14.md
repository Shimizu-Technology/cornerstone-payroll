# Staff role and permission matrix

**Reviewed:** August 23, 2026. **Updated:** November 17, 2026 (managers hold client administration; all payroll staff can mark workers inactive and reactivate them).

This is the approved staff authorization contract for Cornerstone Payroll. The backend policy registry in `api/app/policies/staff_role_policy.rb` is the executable source for high-impact actions. Frontend route and navigation guards mirror it for usability, but the backend remains authoritative.

## Roles and scope

| Role | Scope | Intended use |
| --- | --- | --- |
| `super_admin` | Every organization | Platform recovery, tenant provisioning, and the rare worker tax-classification record transition. Not a routine payroll identity. |
| `org_admin` | One organization | Firm owner/admin. Manages the firm's users, clients, tax rules, integrations, audit history, and organization-wide tools. |
| `admin` | One organization | Legacy alias for `org_admin` until existing Cornerstone accounts are migrated. |
| `manager` | Assigned companies | Payroll manager. Performs payroll work and manages client-specific configuration, client administration and sensitive workforce approvals. |
| `accountant` | Assigned companies | Payroll operator. Maintains employees, imports time and payroll evidence, calculates/processes payroll, checks, corrections, reports, transmittals, and other assigned-client operations. |
| `client` | Assigned companies | Portal-safe employee requests, documents, completed pay periods, and approved reports only. |
| `employee` | Home company | Reserved for future employee self-service; it has no staff-console access. |

## Capability matrix

| Capability | Super admin | Org/legacy admin | Manager | Accountant | Client | Employee |
| --- | --- | --- | --- | --- | --- | --- |
| Staff workspace and assigned-client read access | Yes | Yes | Yes | Yes | No | No |
| Assigned-client payroll operations | Yes | Yes | Yes | Yes | No | No |
| Mark a worker inactive or reactivate an inactive worker (`manage_employee_status`) | Yes | Yes | Yes | Yes | No | No |
| Reactivate (rehire) a terminated worker (`manage_employee_status` and `manage_client_configuration`) | Yes | Yes | Yes | Yes\* | No | No |
| Client configuration and sensitive workforce approval (`manage_client_configuration`) | Yes | Yes | Yes | Yes\* | No | No |
| Client administration (`manage_client_administration`) | Yes | Yes | Yes | Yes\* | No | No |
| Organization administration | Yes | Yes | No | No | No | No |
| Platform administration | Yes | No | No | No | No | No |
| Client portal | No | No | No | No | Yes | No |

\* Only for a client whose company assignment has **Client management** delegation. Delegation is rechecked on every request.

“Payroll operations” includes employee maintenance, departments, pay periods and items, imports, calculate/approve/unapprove/commit, checks and corrections, reports and filing preparation, loans, transmittals, portal documents, and assigned-client contact details. This is intentionally available to accountants because it is their core job.

“Client configuration” includes pay schedule/legal workweek confirmation, check stock/layout/sequence, reminder configuration, the shared printer-profile library, every-period entry setup (Standing Changes), employee termination (and reactivating a terminated worker) and work-profile changes, and approval or rejection of client payroll-sensitive employee changes. Reusable payroll-field definitions (`manage_payroll_fields`) and creating or using printer profiles (`create_printer_profiles`, `use_printer_profiles`) are separate capabilities that accountants also hold. Managing the shared printer-profile library (`manage_printer_profile_library`) stays with managers and admins.

“Worker status” (`manage_employee_status`) covers **Mark inactive** and **Reactivate** for inactive workers, from the employee profile or from an import review's **Reactivate Name** action. Reactivating a terminated worker is a rehire and also needs client configuration, like terminating. Without it, the profile says "A manager or admin can rehire this worker." and the import review says "Name was terminated. A manager or admin can rehire them." Each status change rechecks the operator's client access under the company lock and keeps its actor, effective date and reason in the worker's status history and is audited as `employees#deactivate` or `employees#reactivate`.

“Client administration” (`manage_client_administration`) covers the full client edit (name, EIN, pay frequency, active status, bank, check stock and next check number, simple payroll register, historical payroll workspace and **Require client approval before payroll commit**), the employee intake window, staff portal notification recipients, and marking W-2GU filing ready. Managers hold it for their assigned clients since November 17, 2026. On a test workspace the full client edit stays with organization admins, whatever the workspace access level. Archive and restore remain the way to change a workspace's status.

“Organization administration” includes users and invitations, client assignments and creation, audit history, tax configuration and effective-dated pay-component tax rules, external time-source secrets, and the organization-wide invoice center.

## Employee intake and document exceptions

Organization/system administrators can enable or disable a company-specific incomplete-entry window, with a reason and expiration. Assigned staff can use an active window; client requests keep their staff-approval boundary. Managers/admins review an admitted employee's payroll setup and follow-up. The exception preserves only approved missing fields after strict entry returns.

Operators can record receipt of employee documents. Verified, rejected and waived outcomes require client-configuration permission (manager/admin); operators cannot regress a reviewed outcome to received. Every review retains its actor and reason. Intake permission does not waive documents or filing readiness.

## High-impact endpoint contract

Every endpoint below is registered in `StaffRolePolicy` and is enforced by `Admin::BaseController` before the controller action runs:

| Required capability | Endpoint groups |
| --- | --- |
| Platform administration | all organization endpoints; employee tax-classification record transition |
| Organization administration | all user, invitation, company-assignment, audit-log, tax-config, and invoice controllers; client creation; time-source create/update/delete/test; pay-component tax-rule create/update |
| Client configuration | pay-schedule update; reminder update/test; check settings and next-number update; employee-change review/approve/reject; terminate; work-profile create |
| Payroll fields and printer profiles (accountants included) | payroll-field definition create/update/archive (`manage_payroll_fields`); printer-profile create/clone (`create_printer_profiles`); printer-profile apply/clear and selection (`use_printer_profiles`); apply-to-all-companies and library defaults (`manage_printer_profile_library`, managers and admins only) |
| Client administration | employee intake settings update; portal notification recipients; W-2GU mark ready. Full company update fields are gated inside `companies#update`. |
| Worker status | employee mark inactive (`employees#deactivate`) and reactivate (`employees#reactivate`); rechecked inside `EmployeeStatusTransitionService`, which also requires client configuration to reactivate a terminated worker |

Read access remains narrower than a mutation response suggests:

- Managers, accountants, and clients only receive companies assigned within their own organization.
- An `X-Company-Id` outside that set is rejected; it cannot grant access.
- Accountants without Client management may update only a client's address, city/state/ZIP, phone, and email. They cannot change EIN, company identity/status, pay frequency, bank/check configuration, the next check number or client approval through the company endpoint. Managers, admins and delegated accountants get the full client edit.
- Accountants may read client configuration needed to process payroll, but configuration mutations are rejected.
- Managers may inspect non-secret time-source metadata for imports, but only organization admins may create, test, rotate, or deactivate the secret-bearing integration.
- Client users never enter the staff namespace, and staff users do not enter the client namespace. Every `/api/v1/client/*` endpoint returns 403 for a staff role (`ClientPortalAccess`), so staff edits are always validated and audited as staff actions.
- Client responses mask tax identifiers to the last four digits (`ssn_last_four`, `contractor_ein_last_four`). Full SSNs and EINs are encrypted at rest and returned only to staff.

## Segregation and audit limits

This matrix defines authorization, not a two-person approval control. An authorized payroll operator can currently calculate, approve, and commit the same payroll. If Cornerstone requires preparer/reviewer segregation, add named preparer and approver capabilities plus an explicit “cannot approve your own run” rule; do not infer that control from the `manager` label.

High-impact authorization does not replace company scoping, payroll lifecycle locks, immutable committed records, audit events, or provider-side MFA. All of those controls must pass independently.

## Verification requirements

- The policy spec checks every role/capability pair and confirms every registered action still exists.
- Request specs prove denied mutations do not persist data while permitted read paths remain available.
- The frontend must not advertise client-configuration or sensitive-approval pages to accountants.
- Cross-company and cross-organization request tests remain mandatory.
- Any new high-impact action must be added to the policy registry, this matrix, and focused authorization tests in the same PR.

## Published payroll preview review (November 17, 2026)

Assigned payroll staff (`super_admin`, `org_admin`, `admin`, `manager`, `accountant`) calculate, review and approve a run first. Staff approval publishes its PREVIEW checks and pay stubs to assigned client portal users. Client approval gates **commit**, only when the company's `client_payroll_approval_required` setting is enabled.

| Action | Assigned staff | Assigned client |
| --- | --- | --- |
| Approve/unapprove the payroll run | Yes | No |
| View/download the current published preview | Staff preview endpoint | Own company's approved run and current revision only; audited |
| Approve the published revision | Record an explicit email attestation for an assigned client user, with evidence reference | Acknowledge the exact revision; optional note |
| Request changes | Review the client's request and unapprove before editing | Required note; actor, time and revision retained |
| Commit | Yes; current client approval required when enabled | No |
| Upload/post/decide a manual draft PDF or manually mark Payroll files paid | Retired | Retired |
| Read earlier Payroll files drafts/history | Yes | Previously posted drafts only |

Unapprove supersedes the client revision and withdraws its approval without deleting evidence. Re-approval publishes a new revision. Publication notifies assigned portal clients; client decisions notify configured staff recipients through the existing portal notification system. Existing email enablement and preferences apply. Payroll files paid status follows the actual commit. See the [MoSa runbook](rollout/02-MOSA-CYCLE-RUNBOOK.md#6-publish-the-preview-and-obtain-exact-client-approval) for existing approved-run handling. The staff procedure is in the [MoSa biweekly payroll cycle runbook](runbooks/MOSA_PAYROLL_CYCLE.md).

## MoSa payroll workflow permissions (November 17, 2026)

These are the actions added or changed by PRs #465–#475. Each row was checked against `StaffRolePolicy`, `Admin::BaseController`, the controller action and the UI gate on `main` at `7ae3a77b`.

How to read the table:

- **Yes\*** means an accountant can do it only when their company assignment has **Client management** delegation. `manage_client_configuration`, `manage_client_check_settings` and `manage_client_administration` are delegatable (`StaffRolePolicy::DELEGATABLE_CAPABILITIES`), and delegation is rechecked on every request.
- "Admin" covers both `org_admin` and the legacy `admin` role.
- **Staff access** means no capability beyond `staff_workspace`. The controller has no `StaffRolePolicy` entry, so every assigned staff role can use it. Company scope still applies.

| Action | Super admin | Admin | Manager | Accountant | Client | Capability in code | Enforced in |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Download preview** of checks and stubs (calculated or approved run) | Yes | Yes | Yes | Yes | No | Staff access | `checks#preview_pdf` (audited as `checks#preview_pdf`) |
| View or download the **published** preview for the current revision | No | No | No | No | Yes | Client role (`ClientPortalAccess`) | `client/pay_periods#preview_pdf`; approved run and current revision only; audited |
| Download pre-commit reports marked "PREVIEW, payroll not yet committed" | Yes | Yes | Yes | Yes | No | Staff access | `reports` downloads decorated by `PayrollReportPreview` |
| **Mark inactive** (employee profile) | Yes | Yes | Yes | Yes | No | `manage_employee_status` | `employees#deactivate` (policy registry), rechecked under the company lock and in `EmployeeStatusTransitionService.deactivate!` |
| **Reactivate** an inactive worker (profile or import review) | Yes | Yes | Yes | Yes | No | `manage_employee_status` | `employees#reactivate` (policy registry), rechecked under the company lock and in `EmployeeStatusTransitionService.reactivate!`. Without it the import review says "You don't have access to reactivate Name." |
| **Reactivate** (rehire) a terminated worker | Yes | Yes | Yes | Yes\* | No | `manage_employee_status` + `manage_client_configuration` | `EmployeeStatusTransitionService.reactivate!` returns 403 "A manager or admin can rehire a terminated worker". The profile says "A manager or admin can rehire this worker." The import review says "Name was terminated. A manager or admin can rehire them." |
| Terminate a worker | Yes | Yes | Yes | Yes\* | No | `manage_client_configuration` | `employees#terminate` (policy registry) |
| Match an import again after reactivation | Yes | Yes | Yes | Yes | No | Staff access | `payroll_imports#rematch`; import still in review, not portal-linked |
| Add the second import file, or tick **No tips or loans this period** | Yes | Yes | Yes | Yes | No | Staff access | `payroll_imports#preview` / `#apply`; the waiver is recorded on the import |
| **Remove an import file** | Yes | Yes | Yes | Yes | No | Staff access | `payroll_imports#remove_source`; needs a reason, the import still in review, not from a client revision, not the only file |
| Confirm replacing hand-entered hours on apply | Yes | Yes | Yes | Yes | No | Staff access | `payroll_imports#apply` with `confirm_hours_overwrite`; recorded in the import's raw data |
| Set the **starting check number** on a pay run | Yes | Yes | Yes | Yes\* | No | `manage_client_check_settings` | `pay_periods#create` → `apply_starting_check_number!` (**Starting Check Number (optional)** when creating a run). The UI disables the field without it. |
| Change **Next Check Number** in check settings | Yes | Yes | Yes | Yes\* | No | `manage_client_check_settings` | `checks#update_next_check_number`, `checks#update_check_settings` (policy registry) |
| See "Paper checks will be numbered from N (last used: M)" at commit | Yes | Yes | Yes | Yes | No | Staff access | `check_number_summary` on approved runs. **Review check settings** shows only when `can_change` (`manage_client_check_settings`). |
| Configure **Standing Changes** (every-period entry fields and the missing-regular rule) | Yes | Yes | Yes | Yes\* | No | `manage_client_configuration` | `payroll_standing_changes` (whole controller, including reads and `rule`); audited |
| Fill an expected entry (**Save and calculate**) | Yes | Yes | Yes | Yes | No | Staff access | `pay_periods#run_payroll` with salary overrides or job hours |
| **None this period** / **Not paid this period** and their undo | Yes | Yes | Yes | Yes | No | `payroll_operations` | `payroll_entry_resolutions#create` / `#destroy`; audited |
| Submit configured entries in the portal | No | No | No | No | Yes | Client role | `client/payroll_submission_periods#submissions` |
| Approve, unapprove and commit the run | Yes | Yes | Yes | Yes | No | Staff access | `pay_periods#approve` / `#unapprove` / `#commit` |
| **Approve this revision** (client) | No | No | No | No | Yes | Client role (`current_user.client?`) | `client/pay_periods#approve_review` |
| **Request changes** (client, note required) | No | No | No | No | Yes | Client role (`current_user.client?`) | `client/pay_periods#request_changes` |
| **Record Email Approval** for an assigned client user | Yes | Yes | Yes | Yes | No | Staff access | `pay_periods#record_client_approval`; needs an evidence reference |
| Acknowledge outstanding client file requests at commit | Yes | Yes | Yes | Yes | No | Staff access | `pay_periods#commit` with `acknowledge_outstanding_file_requests`; the request IDs, titles and statuses go into the commit audit entry |
| Turn **Require client approval before payroll commit** on or off | Yes | Yes | Yes | Yes\* | No | `manage_client_administration` | `companies#update` (`ADMIN_EDITABLE_COMPANY_FIELDS`); audited |

Notes:

- **Client decisions are client-only.** Staff can't approve or request changes as the client. The client endpoints reject staff roles, and the admin namespace rejects clients.
- **Registry gap (closed in PR #479).** `employees#deactivate` and `employees#reactivate` are both in `StaffRolePolicy::ACTION_CAPABILITIES` with `manage_employee_status`, and the policy spec covers them.
- **Two roles for owner pay.** Filling an owner-pay entry needs only payroll access. Setting up which entries exist needs client configuration. So an accountant without delegation can fill Mo's and Sarah's pay but can't add or change the fields.
