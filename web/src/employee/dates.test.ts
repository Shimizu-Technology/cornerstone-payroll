/** @vitest-environment node */
import { describe, expect, it } from 'vitest';
import { today } from './config';
import { accessDay, guamDay } from './contracts';
import { daysBetween, daysUntilLabel } from './format';

describe('Guam calendar days', () => {
  it('counts today in Guam, whatever zone the device or CI runner is in', () => {
    // 09:00 on Nov 25 in Guam is still Nov 24 in UTC and on the US mainland.
    const morning = new Date('2026-11-25T09:00:00+10:00');
    expect(guamDay(morning)).toBe('2026-11-25');
    expect(today(morning)).toBe('2026-11-25');
    expect(today(new Date('2026-11-24T13:59:59Z'))).toBe('2026-11-24');
    expect(today(new Date('2026-11-24T14:00:00Z'))).toBe('2026-11-25');
  });

  it('reads an access instant as the Guam day it ends on', () => {
    expect(accessDay('2028-03-01T23:59:59+10:00')).toBe('2028-03-01');
    expect(accessDay('2028-03-01T13:59:59Z')).toBe('2028-03-01');
    expect(accessDay('2028-03-01')).toBe('2028-03-01');
    expect(accessDay('2028-13-45T00:00:00Z')).toBeNull();
    expect(accessDay('soon')).toBeNull();
    expect(accessDay(null)).toBeNull();
  });

  it('says "In N days" from the Guam date to the payday', () => {
    expect(daysUntilLabel('2026-12-04', today(new Date('2026-11-25T09:00:00+10:00')))).toBe('In 9 days');
    expect(daysUntilLabel('2026-11-26', '2026-11-25')).toBe('Tomorrow');
    expect(daysUntilLabel('2026-11-25', '2026-11-25')).toBe('Today');
    expect(daysUntilLabel('2026-11-24', '2026-11-25')).toBeNull();
    // Across a month and a year end.
    expect(daysBetween('2026-12-30', '2027-01-02')).toBe(3);
    expect(daysUntilLabel('not a date', '2026-11-25')).toBeNull();
  });
});
