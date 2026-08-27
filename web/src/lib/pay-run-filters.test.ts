import { describe, expect, it } from 'vitest';
import { parsePayRunYear } from './pay-run-filters';

describe('parsePayRunYear', () => {
  it('returns a valid numeric year for the pay-period API filter', () => {
    expect(parsePayRunYear('2026')).toBe(2026);
  });

  it.each([null, '', 'not-a-year', '2026abc', '26', '10000'])('omits an invalid year filter: %s', (value) => {
    expect(parsePayRunYear(value)).toBeUndefined();
  });
});
