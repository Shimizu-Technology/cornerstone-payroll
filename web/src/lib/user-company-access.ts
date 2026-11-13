import type { CompanyListItem } from '@/services/api';
import type { UserRole } from '@/types';

export const needsClientAssignment = (role: UserRole): boolean =>
  role === 'manager' || role === 'accountant' || role === 'client';

export const isTestWorkspaceCompany = (company: CompanyListItem): boolean =>
  company.test_workspace ?? company.payroll_environment === 'migration_rehearsal';

export function assignmentCompanyIdsForRole(
  role: UserRole,
  selectedIds: number[],
  companies: CompanyListItem[]
): number[] {
  if (!needsClientAssignment(role)) return [];
  if (role !== 'client') return selectedIds;

  if (selectedIds.length === 1 && companies.some(company => company.id === selectedIds[0] &&
    company.test_workspace_purpose === 'sandbox' && company.migration_rehearsal_status === 'ready' &&
    company.active !== false && !company.test_workspace_read_only && !company.test_workspace_expired && !company.test_workspace_archived_at)) return selectedIds;

  const productionCompanyIds = new Set(
    companies.filter(company => !isTestWorkspaceCompany(company)).map(company => company.id)
  );
  return selectedIds.filter(companyId => productionCompanyIds.has(companyId));
}
