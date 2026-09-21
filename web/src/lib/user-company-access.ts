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

  const productionCompanyIds = new Set(
    companies.filter(company => !isTestWorkspaceCompany(company)).map(company => company.id)
  );
  return selectedIds.filter(companyId => productionCompanyIds.has(companyId));
}
