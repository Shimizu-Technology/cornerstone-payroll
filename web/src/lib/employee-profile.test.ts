import { describe, expect, it } from 'vitest';
import type { Employee } from '@/types';
import { canonicalSsn, importedProfileAllowsBlank, validateHireDate } from './employee-profile';

const imported = {
  configuration_source: 'quickbooks_history', configuration_review_status: 'needs_review',
  configuration_review_items: [{ code: 'employee_address_missing', message: 'Verify address', fields: ['address_line1', 'city', 'state', 'zip'] }],
} as Employee;

describe('incremental imported profile corrections', () => {
  it('compares raw imported and formatted SSNs by canonical digits', () => {
    expect(canonicalSsn('000000001')).toBe(canonicalSsn('000-00-0001'));
    expect(canonicalSsn('000-00-0002')).not.toBe(canonicalSsn('000000001'));
  });
  it('permits only fields held for source review, preserving normal requirements', () => {
    expect(importedProfileAllowsBlank(imported, 'address_line1')).toBe(true);
    expect(importedProfileAllowsBlank(imported, 'hire_date')).toBe(false);
    expect(importedProfileAllowsBlank({ ...imported, configuration_review_status: 'complete' }, 'address_line1')).toBe(false);
    expect(importedProfileAllowsBlank(null, 'address_line1')).toBe(false);
  });
  it('rejects the corrupted year without rejecting historical or blank source dates', () => {
    expect(validateHireDate('0006-04-20')).toMatch(/year/);
    expect(validateHireDate('1998-05-26')).toBeNull();
    expect(validateHireDate('')).toBeNull();
  });
});
