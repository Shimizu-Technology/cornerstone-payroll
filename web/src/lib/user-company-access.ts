import type { CompanyListItem } from '@/services/api';
import type { UserRole } from '@/types';

export const needsClientAssignment = (role: UserRole): boolean =>
  role === 'manager' || role === 'accountant' || role === 'client';

export const isTestWorkspaceCompany = (company: CompanyListItem): boolean =>
  company.test_workspace ?? company.payroll_environment === 'migration_rehearsal';

// Archived, expired, sealed and backup workspaces can't take new access.
export function closedWorkspaceLabel(company: CompanyListItem): string | null {
  if (!isTestWorkspaceCompany(company)) return null;
  if (company.test_workspace_archived_at) return 'Archived';
  if (company.test_workspace_expired) return 'Expired';
  if (company.test_workspace_purpose === 'backup_snapshot') return 'Read-only backup';
  if (company.test_workspace_read_only || company.test_workspace_sealed_at) return 'Read only';
  if (company.active === false) return 'Inactive';
  return null;
}

export const isSandboxCopy = (company: CompanyListItem): boolean =>
  isTestWorkspaceCompany(company) && company.test_workspace_purpose === 'sandbox';

// Mirrors the server's User#practice_portal_open? copy checks.
export const isOpenPracticeCopy = (company: CompanyListItem): boolean =>
  isSandboxCopy(company) && company.migration_rehearsal_status === 'ready' && closedWorkspaceLabel(company) === null;

export const isPreparingPracticeCopy = (company: CompanyListItem): boolean =>
  isSandboxCopy(company) && company.migration_rehearsal_status === 'pending' && closedWorkspaceLabel(company) === null;

export function assignmentCompanyIdsForRole(
  role: UserRole,
  selectedIds: number[],
  companies: CompanyListItem[]
): number[] {
  if (!needsClientAssignment(role)) return [];
  if (role !== 'client') return selectedIds;

  if (selectedIds.length === 1 && companies.some(company => company.id === selectedIds[0] && isOpenPracticeCopy(company))) {
    return selectedIds;
  }

  const productionCompanyIds = new Set(
    companies.filter(company => !isTestWorkspaceCompany(company)).map(company => company.id)
  );
  return selectedIds.filter(companyId => productionCompanyIds.has(companyId));
}

export interface AssignmentOption {
  company: CompanyListItem;
  /** Unavailable options stay toggleable only when already selected, so stale grants can be removed. */
  selectable: boolean;
  detail: string;
  preparing?: boolean;
}

export interface AssignmentGroups {
  production: AssignmentOption[];
  practice: AssignmentOption[];
  unavailable: AssignmentOption[];
}

// Groups the Assign Payroll Clients picker the way Client Management groups
// its list. A client portal login sees only sandbox practice copies, because a
// practice-only login is limited to one copy and no real clients.
export function groupAssignmentCompanies(
  companies: CompanyListItem[],
  role: UserRole,
  selectedIds: number[] = []
): AssignmentGroups {
  const groups: AssignmentGroups = { production: [], practice: [], unavailable: [] };
  for (const company of companies) {
    if (!isTestWorkspaceCompany(company)) {
      groups.production.push({ company, selectable: true, detail: `${company.active_employees ?? 0} employees` });
      continue;
    }

    const selected = selectedIds.includes(company.id);
    const closed = closedWorkspaceLabel(company);
    if (role === 'client') {
      if (!isSandboxCopy(company)) continue;
      if (closed) groups.unavailable.push({ company, selectable: false, detail: `${closed} · can't be assigned` });
      else if (company.migration_rehearsal_status === 'ready') groups.practice.push({ company, selectable: true, detail: 'Practice copy · separate client login only' });
      else if (company.migration_rehearsal_status === 'pending') groups.practice.push({ company, selectable: false, preparing: true, detail: 'Preparing… refresh in a moment' });
      else groups.unavailable.push({ company, selectable: false, detail: 'Copy did not finish · can’t be assigned' });
      continue;
    }

    const label = company.test_workspace_purpose_label || 'Test workspace';
    if (closed) {
      groups.unavailable.push({ company, selectable: selected, detail: `${label} · ${closed}` });
    } else {
      const preparing = company.migration_rehearsal_status === 'pending';
      groups.practice.push({ company, selectable: true, preparing, detail: `${label} · operator access${preparing ? ' · preparing' : ''}` });
    }
  }
  return groups;
}

// A client login holds either real clients or exactly one practice copy.
export function toggleAssignment(
  role: UserRole,
  selectedIds: number[],
  company: CompanyListItem,
  companies: CompanyListItem[]
): number[] {
  const selected = selectedIds.includes(company.id);
  if (role !== 'client') return selected ? selectedIds.filter(id => id !== company.id) : [...selectedIds, company.id];
  if (isTestWorkspaceCompany(company)) return selected ? [] : [company.id];

  const testWorkspaceIds = new Set(companies.filter(isTestWorkspaceCompany).map(candidate => candidate.id));
  const realIds = selectedIds.filter(id => !testWorkspaceIds.has(id));
  return selected ? realIds.filter(id => id !== company.id) : [...realIds, company.id];
}

// Ready practice copies a closed practice login can move to: other copies of
// the same real client, since each copy holds that client's payroll data.
export const practiceMoveTargets = (
  companies: CompanyListItem[],
  organizationId: number | undefined,
  currentCopyId: number | null | undefined,
  sourceCompanyId: number | null | undefined
): CompanyListItem[] =>
  sourceCompanyId == null ? [] : companies.filter(company => isOpenPracticeCopy(company) && company.id !== currentCopyId &&
    company.migration_source_company_id === sourceCompanyId &&
    (organizationId === undefined || company.organization_id === organizationId));
