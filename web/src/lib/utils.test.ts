import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { formatDate, formatDateRange } from './utils';

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
});
