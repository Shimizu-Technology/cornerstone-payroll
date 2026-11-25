/** @vitest-environment node */
import { describe, expect, it } from 'vitest';
import { formatDate, formatDateRange, parseDay } from './display-date';

describe('formatDate', () => {
  it('keeps ISO date-only values on the same calendar day', () => {
    expect(formatDate('2026-11-27')).toBe('Nov 27, 2026');
    expect(parseDay('2026-11-27')?.toISOString()).toBe('2026-11-27T00:00:00.000Z');
  });

  it('keeps the written day of a calendar date supplied as an ISO datetime', () => {
    expect(formatDate('2026-11-27T00:30:00+10:00')).toBe('Nov 27, 2026');
    expect(formatDate('2026-11-27T23:30:00-08:00')).toBe('Nov 27, 2026');
  });

  it('can include an abbreviated weekday', () => {
    expect(formatDate('2026-11-20', { includeWeekday: true })).toBe('Fri, Nov 20, 2026');
  });

  it('accepts a valid leap day', () => {
    expect(formatDate('2028-02-29')).toBe('Feb 29, 2028');
  });

  it.each([null, undefined, '', 'not a date', '11/27/2026', '2026-13-01', '2026-02-29', '2026-11-27Tinvalid', '2026-11-27-extra'])(
    'returns an empty label for %j',
    (value) => expect(formatDate(value)).toBe(''),
  );
});

describe('formatDateRange', () => {
  it.each([
    ['2026-11-21', '2026-11-21', 'Nov 21, 2026'],
    ['2026-11-08', '2026-11-21', 'Nov 8 – 21, 2026'],
    ['2026-10-25', '2026-11-07', 'Oct 25 – Nov 7, 2026'],
    ['2026-12-27', '2027-01-09', 'Dec 27, 2026 – Jan 9, 2027'],
    ['2026-11-08', '2027-11-21', 'Nov 8, 2026 – Nov 21, 2027'],
  ])('formats %s through %s', (start, end, expected) => {
    expect(formatDateRange(start, end)).toBe(expected);
  });

  it('returns an empty label when either endpoint is missing or invalid', () => {
    expect(formatDateRange(null, '2026-11-21')).toBe('');
    expect(formatDateRange('2026-11-08', undefined)).toBe('');
    expect(formatDateRange('2026-11-08', '2026-11-31')).toBe('');
  });
});
