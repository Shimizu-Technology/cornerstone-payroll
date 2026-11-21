import { describe, expect, it } from 'vitest';
import { nextRecurrenceStart, termsDueDays } from './invoice-recurrence';

describe('nextRecurrenceStart', () => {
  const november = { invoice_date: '2026-11-30', service_period_start: '2026-11-01' };

  it('starts the period after the source invoice, not today', () => {
    expect(nextRecurrenceStart(november, 'month', 1, '2026-11-21')).toBe('2026-12-01');
    expect(nextRecurrenceStart(november, 'month', 3, '2026-11-21')).toBe('2027-02-01');
    expect(nextRecurrenceStart(november, 'week', 1, '2026-11-01')).toBe('2026-11-08');
    expect(nextRecurrenceStart(november, 'week', 2, '2026-11-01')).toBe('2026-11-15');
  });

  it('uses the invoice date without a service period and keeps month ends like the server', () => {
    expect(nextRecurrenceStart({ invoice_date: '2026-01-31' }, 'month', 1, '2026-01-31')).toBe('2026-02-28');
  });

  it('moves forward whole intervals when the next period is already past', () => {
    expect(nextRecurrenceStart({ invoice_date: '2026-05-02', service_period_start: '2026-05-01' }, 'month', 1, '2026-11-21')).toBe('2026-12-01');
    expect(nextRecurrenceStart(november, 'week', 1, '2026-11-21')).toBe('2026-11-22');
    expect(nextRecurrenceStart(november, 'week', 1, '2026-11-23')).toBe('2026-11-29');
  });

  it('reaches today from a very old anchor, never returning a past date', () => {
    // 2000-01-03 is a Monday; 2026-11-21 is a Saturday, so the next Monday is 2026-11-23.
    expect(nextRecurrenceStart({ invoice_date: '2000-01-03' }, 'week', 1, '2026-11-21')).toBe('2026-11-23');
    expect(nextRecurrenceStart({ invoice_date: '2000-01-03' }, 'week', 3, '2026-11-21') >= '2026-11-21').toBe(true);
    expect(nextRecurrenceStart({ invoice_date: '1990-01-31', service_period_start: '1990-01-31' }, 'month', 1, '2026-11-21')).toBe('2026-11-30');
    expect(nextRecurrenceStart({ invoice_date: '1990-03-15' }, 'month', 12, '2026-11-21')).toBe('2027-03-15');
    expect(nextRecurrenceStart({ invoice_date: '2026-11-21' }, 'month', 1, '2026-11-21')).toBe('2026-12-21');
  });
});

describe('termsDueDays', () => {
  it('reads Net N and Due on receipt, and nothing else', () => {
    expect(termsDueDays('Net 15')).toBe(15);
    expect(termsDueDays(' net 30 ')).toBe(30);
    expect(termsDueDays('Due on receipt')).toBe(0);
    expect(termsDueDays('15th of next month')).toBeNull();
    expect(termsDueDays(null)).toBeNull();
  });
});
