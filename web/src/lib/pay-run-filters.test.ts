import { describe, expect, it } from 'vitest';
import { countActivePayrollChecks, parsePayRunId, parsePayRunYear } from './pay-run-filters';

describe('parsePayRunYear', (): void => {
  it('returns a valid numeric year for the pay-period API filter', (): void => {
    expect(parsePayRunYear('2026')).toBe(2026);
    expect(parsePayRunYear('1900')).toBe(1900);
  });

  it.each([null, '', 'not-a-year', '2026abc', '26', '1899', '10000'])('omits an invalid year filter: %s', (value): void => {
    expect(parsePayRunYear(value)).toBeUndefined();
  });
});

describe('countActivePayrollChecks', (): void => {
  it('excludes voided and unassigned payroll checks from the active count', (): void => {
    expect(countActivePayrollChecks([
      { check_number: '1001', voided: false },
      { check_number: '1002', voided: true },
      { check_number: null, voided: false },
      { check_number: '   ', voided: false },
    ])).toBe(1);
  });
});

describe('parsePayRunId', (): void => {
  it('accepts a positive integer route ID', (): void => {
    expect(parsePayRunId('123')).toBe(123);
  });

  it.each([undefined, '', '0', '-1', '01', '1.5', '1e3', '0x10', '123abc'])('rejects a malformed route ID: %s', (value): void => {
    expect(parsePayRunId(value)).toBeUndefined();
  });
});
