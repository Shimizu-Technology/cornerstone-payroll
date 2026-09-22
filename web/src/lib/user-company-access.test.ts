import { describe, expect, it } from 'vitest';
import type { CompanyListItem } from '@/services/api';
import { assignmentCompanyIdsForRole, isTestWorkspaceCompany } from './user-company-access';

const production = { id: 1, name: 'Production', payroll_environment: 'live' } as CompanyListItem;
const testWorkspace = {
  id: 2,
  name: 'Training',
  payroll_environment: 'migration_rehearsal',
  test_workspace: true,
} as CompanyListItem;

describe('user company access', () => {
  it('recognizes explicit and legacy test workspace metadata', () => {
    expect(isTestWorkspaceCompany(testWorkspace)).toBe(true);
    expect(isTestWorkspaceCompany(production)).toBe(false);
  });

  it('removes hidden test workspaces for client portal users', () => {
    expect(assignmentCompanyIdsForRole('client', [1, 2], [production, testWorkspace])).toEqual([1]);
  });

  it('preserves test workspace choices for staff and clears roles without assignments', () => {
    expect(assignmentCompanyIdsForRole('accountant', [1, 2], [production, testWorkspace])).toEqual([1, 2]);
    expect(assignmentCompanyIdsForRole('admin', [1, 2], [production, testWorkspace])).toEqual([]);
  });
});
