import type { CompanyListItem } from '@/services/api';

export function isTestWorkspaceCompany(company: CompanyListItem | null | undefined): boolean {
  return company?.test_workspace ?? company?.payroll_environment === 'migration_rehearsal';
}

// Finance books, invoices and customer links take only the server's list of
// billable live clients. Ordinary navigation keeps the neutral company payload.
export function isBillingClient(company: CompanyListItem | null | undefined, billingCompanyIds?: number[] | null): boolean {
  if (!company) return false;
  if (billingCompanyIds) return billingCompanyIds.includes(company.id);
  return !isTestWorkspaceCompany(company);
}

// The practice-portal flag is scoped by the server to the client's own copy.
// Client profile changes use client endpoints and their approval flow, not the
// staff payroll permission represented by workspace_can_write.
export function canWriteClientEmployeeProfile(company: CompanyListItem | null | undefined): boolean {
  if (!company?.practice_portal) return canWriteCompany(company);
  return company.active !== false && !company.test_workspace_read_only && !company.test_workspace_expired
    && !company.test_workspace_archived_at && !company.test_workspace_sealed_at
    && company.test_workspace_purpose !== 'backup_snapshot';
}

// A test workspace needs the server's effective permission, not a staff role.
// Missing optional data for ordinary clients preserves the existing UI contract;
// authoritative server guards still govern every write.
export function canWriteCompany(company: CompanyListItem | null | undefined, capability = 'payroll_operations'): boolean {
  if (company?.workspace_can_write === false) return false;
  if (company?.test_workspace_read_only || company?.test_workspace_expired || company?.test_workspace_archived_at || company?.test_workspace_sealed_at || company?.test_workspace_purpose === 'backup_snapshot') return false;
  const workspace = company?.test_workspace ?? company?.payroll_environment === 'migration_rehearsal';
  if (!workspace) return company?.workspace_write_permissions?.[capability] !== false;
  if (capability === 'payroll_operations') return company?.workspace_write_permissions?.[capability] ?? company?.workspace_can_write === true;
  return company?.workspace_write_permissions?.[capability] === true;
}

export function companyReadOnlyMessage(company: CompanyListItem | null | undefined): string {
  if (company?.test_workspace_expired) return 'This test workspace has expired. You can review its records; changes are unavailable.';
  if (company?.test_workspace_purpose === 'backup_snapshot' || company?.test_workspace_sealed_at) return 'This preserved snapshot is for review and recovery only. Changes are unavailable.';
  if (company?.test_workspace_archived_at) return 'This test workspace is archived. Changes are unavailable.';
  return 'You have read-only access to this workspace. Review records and reports; an authorized operator must make changes.';
}
