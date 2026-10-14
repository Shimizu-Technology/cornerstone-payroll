import type { CompanyListItem } from '@/services/api';

export function isTestWorkspaceCompany(company: CompanyListItem | null | undefined): boolean {
  return company?.test_workspace ?? company?.payroll_environment === 'migration_rehearsal';
}

// A test workspace needs the server's effective permission, not a staff role.
// Missing optional data for ordinary clients preserves the existing UI contract;
// authoritative server guards still govern every write.
export function canWriteCompany(company: CompanyListItem | null | undefined): boolean {
  if (company?.workspace_can_write === false) return false;
  const workspace = company?.test_workspace ?? company?.payroll_environment === 'migration_rehearsal';
  if (!workspace) return true;
  if (company?.test_workspace_read_only || company?.test_workspace_expired || company?.test_workspace_archived_at || company?.test_workspace_sealed_at || company?.test_workspace_purpose === 'backup_snapshot') return false;
  return company?.workspace_can_write === true;
}

export function companyReadOnlyMessage(company: CompanyListItem | null | undefined): string {
  if (company?.test_workspace_expired) return 'This test workspace has expired. You can review its records; changes are unavailable.';
  if (company?.test_workspace_purpose === 'backup_snapshot' || company?.test_workspace_sealed_at) return 'This preserved snapshot is for review and recovery only. Changes are unavailable.';
  if (company?.test_workspace_archived_at) return 'This test workspace is archived. Changes are unavailable.';
  return 'You have read-only access to this workspace. Review records and reports; an authorized operator must make changes.';
}
