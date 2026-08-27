import { describe, expect, it } from 'vitest';
import { countActivePayrollChecks, parsePayRunYear } from './pay-run-filters';

describe('parsePayRunYear', () => {
  it('returns a valid numeric year for the pay-period API filter', () => {
    expect(parsePayRunYear('2026')).toBe(2026);
  });

  it.each([null, '', 'not-a-year', '2026abc', '26', '10000'])('omits an invalid year filter: %s', (value) => {
    expect(parsePayRunYear(value)).toBeUndefined();
  });
});

describe('countActivePayrollChecks', () => {
  it('excludes voided and unassigned payroll checks from the active count', (): void => {
    expect(countActivePayrollChecks([
      { check_number: '1001', voided: false },
      { check_number: '1002', voided: true },
      { check_number: null, voided: false },
    ])).toBe(1);
  });
});
