import { describe, expect, it } from 'vitest';
import type { CompanyListItem } from '@/services/api';
import { canWriteCompany } from './company-write-access';
const live = { id: 1, payroll_environment: 'live' } as CompanyListItem;
const sandbox = { ...live, payroll_environment: 'migration_rehearsal', test_workspace: true, test_workspace_purpose: 'sandbox' } as CompanyListItem;
describe('effective company write access', () => {
  it('preserves ordinary client behavior while requiring explicit workspace permission', () => {
    expect(canWriteCompany(live)).toBe(true);
    expect(canWriteCompany(sandbox)).toBe(false);
    expect(canWriteCompany({ ...sandbox, workspace_can_write: false })).toBe(false);
    expect(canWriteCompany({ ...sandbox, workspace_can_write: true })).toBe(true);
  });
  it.each(['test_workspace_expired', 'test_workspace_read_only', 'test_workspace_archived_at', 'test_workspace_sealed_at'])('does not treat %s as writable', key => {
    expect(canWriteCompany({ ...sandbox, workspace_can_write: true, [key]: key.endsWith('_at') ? '2026-10-14T00:00:00Z' : true })).toBe(false);
  });
});

describe('capability-specific workspace writes', () => {
  it('does not turn payroll operator permission into configuration administration', () => {
    const operator = { ...sandbox, workspace_can_write: true, workspace_write_permissions: { payroll_operations: true, manage_client_configuration: false, manage_payroll_fields: true } };
    expect(canWriteCompany(operator)).toBe(true);
    expect(canWriteCompany(operator, 'manage_client_configuration')).toBe(false);
    expect(canWriteCompany(operator, 'manage_payroll_fields')).toBe(true);
    expect(canWriteCompany({ ...operator, workspace_write_permissions: { ...operator.workspace_write_permissions, manage_client_configuration: true } }, 'manage_client_configuration')).toBe(true);
  });
  it('fails closed for missing non-payroll permissions in known workspaces while preserving ordinary compatibility', () => {
    expect(canWriteCompany({ ...sandbox, workspace_can_write: true }, 'manage_client_configuration')).toBe(false);
    expect(canWriteCompany(live, 'manage_client_configuration')).toBe(true);
  });
});
