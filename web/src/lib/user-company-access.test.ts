import { describe, expect, it } from 'vitest';
import type { CompanyListItem } from '@/services/api';
import {
  assignmentCompanyIdsForRole,
  groupAssignmentCompanies,
  isTestWorkspaceCompany,
  practiceMoveTargets,
  toggleAssignment,
} from './user-company-access';

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

  it('allows one ready practice copy for a separate client login', () => {
    const ready = { ...testWorkspace, test_workspace_purpose: 'sandbox', migration_rehearsal_status: 'ready' } as CompanyListItem;
    expect(assignmentCompanyIdsForRole('client', [2], [production, ready])).toEqual([2]);
    expect(assignmentCompanyIdsForRole('client', [2], [production, { ...ready, test_workspace_expired: true }])).toEqual([]);
  });

  it('preserves test workspace choices for staff and clears roles without assignments', () => {
    expect(assignmentCompanyIdsForRole('accountant', [1, 2], [production, testWorkspace])).toEqual([1, 2]);
    expect(assignmentCompanyIdsForRole('admin', [1, 2], [production, testWorkspace])).toEqual([]);
  });

  it('keeps sealed and backup copies out of a client login', () => {
    const ready = { ...testWorkspace, test_workspace_purpose: 'sandbox', migration_rehearsal_status: 'ready' } as CompanyListItem;
    expect(assignmentCompanyIdsForRole('client', [2], [{ ...ready, test_workspace_sealed_at: '2026-11-01T00:00:00Z' }])).toEqual([]);
    expect(assignmentCompanyIdsForRole('client', [2], [{ ...ready, test_workspace_purpose: 'backup_snapshot' }])).toEqual([]);
    expect(assignmentCompanyIdsForRole('client', [2], [{ ...ready, migration_rehearsal_status: 'pending' }])).toEqual([]);
  });
});

const sandbox = (id: number, extra: Partial<CompanyListItem> = {}) => ({
  id, name: `Copy ${id}`, organization_id: 7, active: true, payroll_environment: 'migration_rehearsal', test_workspace: true,
  test_workspace_purpose: 'sandbox', migration_rehearsal_status: 'ready', ...extra,
}) as CompanyListItem;
const live = { ...production, organization_id: 7, active_employees: 3 } as CompanyListItem;
const ready = sandbox(10);
const preparing = sandbox(11, { migration_rehearsal_status: 'pending' });
const failed = sandbox(12, { migration_rehearsal_status: 'failed' });
const archived = sandbox(13, { active: false, test_workspace_archived_at: '2026-11-14T00:00:00Z' });
const expired = sandbox(14, { test_workspace_expired: true });
const backup = sandbox(15, { test_workspace_purpose: 'backup_snapshot', test_workspace_read_only: true });
const rehearsal = sandbox(16, { test_workspace_purpose: 'migration_rehearsal', test_workspace_purpose_label: 'Migration rehearsal' });
const all = [live, ready, preparing, failed, archived, expired, backup, rehearsal];
const ids = (options: { company: CompanyListItem }[]) => options.map(option => option.company.id);

describe('assignment picker grouping', () => {
  it('groups a client login into production clients and practice copies, with closed copies set aside', () => {
    const groups = groupAssignmentCompanies(all, 'client');
    expect(ids(groups.production)).toEqual([1]);
    expect(ids(groups.practice)).toEqual([10, 11]);
    expect(groups.practice.map(option => option.selectable)).toEqual([true, false]);
    expect(groups.practice[1]).toMatchObject({ preparing: true, detail: 'Preparing… refresh in a moment' });
    // Backups and rehearsals are staff-only, so a client login never sees them.
    expect(ids(groups.unavailable)).toEqual([12, 13, 14]);
    expect(groups.unavailable.every(option => !option.selectable)).toBe(true);
  });

  it('offers staff every open test workspace and lets them remove a stale closed one', () => {
    const groups = groupAssignmentCompanies(all, 'accountant', [13]);
    expect(ids(groups.practice)).toEqual([10, 11, 12, 16]);
    expect(groups.practice.every(option => option.selectable)).toBe(true);
    expect(ids(groups.unavailable)).toEqual([13, 14, 15]);
    expect(groups.unavailable.map(option => option.selectable)).toEqual([true, false, false]);
  });

  it('keeps a client login to real clients or exactly one practice copy', () => {
    expect(toggleAssignment('client', [1], ready, all)).toEqual([10]);
    expect(toggleAssignment('client', [10], live, all)).toEqual([1]);
    expect(toggleAssignment('client', [10], ready, all)).toEqual([]);
    expect(toggleAssignment('accountant', [1], ready, all)).toEqual([1, 10]);
    expect(toggleAssignment('accountant', [1, 10], ready, all)).toEqual([1]);
  });

  it('offers only ready practice copies in the login organization as move targets', () => {
    const otherFirm = sandbox(20, { organization_id: 8 });
    expect(practiceMoveTargets([...all, otherFirm], 7, 13).map(company => company.id)).toEqual([10]);
    expect(practiceMoveTargets([...all, otherFirm], 7, 10)).toEqual([]);
  });
});
