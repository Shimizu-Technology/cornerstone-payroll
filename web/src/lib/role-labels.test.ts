import { describe, expect, it } from 'vitest';
import { roleLabel } from './role-labels';

describe('roleLabel', () => {
  it('names the legacy admin role the same as Organization Admin', () => {
    expect(roleLabel('admin')).toBe('Organization Admin');
    expect(roleLabel('org_admin')).toBe('Organization Admin');
  });

  it('uses the Users page names for every role', () => {
    expect(roleLabel('super_admin')).toBe('Super Admin');
    expect(roleLabel('client')).toBe('Client Portal User');
    expect(roleLabel('accountant')).toBe('Accountant');
  });

  it('falls back for a missing or unknown role', () => {
    expect(roleLabel(undefined)).toBe('User');
    expect(roleLabel('payroll_reviewer')).toBe('Payroll Reviewer');
  });
});
