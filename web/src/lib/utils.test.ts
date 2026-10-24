import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { formatDate, formatDateRange, formatGuamDateTime, formatGuamDateTimeShort } from './utils';

describe('date-only formatting', (): void => {
  const originalTimeZone = process.env.TZ;

  beforeEach((): void => {
    process.env.TZ = 'America/Los_Angeles';
  });

  afterEach((): void => {
    if (originalTimeZone === undefined) {
      delete process.env.TZ;
    } else {
      process.env.TZ = originalTimeZone;
    }
  });

  it('keeps backend calendar dates stable west of UTC', (): void => {
    expect(formatDate('2026-01-02')).toBe('Jan 2, 2026');
    expect(formatDateRange('2026-01-02', '2026-01-15')).toBe('Jan 2 - 15, 2026');
  });

  it('keeps ISO timestamps as instants instead of treating them as calendar dates', (): void => {
    expect(formatDate('2026-01-02T01:00:00Z')).toBe('Jan 1, 2026');
  });
});

describe('Guam instant formatting', (): void => {
  const originalTimeZone = process.env.TZ;
  afterEach((): void => { if (originalTimeZone === undefined) delete process.env.TZ; else process.env.TZ = originalTimeZone; });
  it.each(['Pacific/Guam', 'America/Los_Angeles', 'UTC'])('uses the same Guam wall time and ChST label under %s', (timeZone): void => {
    process.env.TZ = timeZone;
    const instant = '2026-10-21T13:34:56Z';
    expect(formatGuamDateTime(instant)).toBe('Oct 21, 2026, 11:34:56 PM ChST');
    expect(formatGuamDateTimeShort(instant)).toBe('Oct 21, 11:34 PM ChST');
    expect(formatGuamDateTime(instant, { timeZone: 'UTC', timeZoneName: 'long', second: undefined })).toBe('Oct 21, 2026, 11:34 PM ChST');
  });
  it('retains missing-instant messages', (): void => {
    expect(formatGuamDateTime(null)).toBe('Not recorded');
    expect(formatGuamDateTimeShort(null)).toBe('Not processed');
  });
});
