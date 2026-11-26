import { describe, expect, it } from 'vitest';
import { guamBusinessDate, guamTaxPeriod } from './payrollBusinessDate';

// 2027-01-01 00:30 in Guam is still Dec 31, 2026 in California and UTC.
const GUAM_NEW_YEAR = new Date('2026-12-31T14:30:00Z');

describe('Guam business date', () => {
  it('uses the Guam date whatever the browser time zone', () => {
    expect(guamBusinessDate(GUAM_NEW_YEAR)).toBe('2027-01-01');
  });

  it("gives the Guam date's tax year, quarter and month", () => {
    expect(guamTaxPeriod(GUAM_NEW_YEAR)).toEqual({ tax_year: '2027', tax_quarter: '1', tax_month: '1' });
    expect(guamTaxPeriod(new Date('2026-09-30T15:00:00Z'))).toEqual({ tax_year: '2026', tax_quarter: '4', tax_month: '10' });
  });
});
