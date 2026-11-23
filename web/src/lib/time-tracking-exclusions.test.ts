import { describe, expect, it } from 'vitest';
import type { PayPeriod } from '@/types';
import { exclusionCountMessages, payRunExclusionCounts, payRunUnclassifiedExclusionCount } from './time-tracking-exclusions';

const bucket = (entry_count: number) => ({ entry_count, total_hours: entry_count });

function timeTracking(...held: object[]) {
  return { linked_aire_records: held.map(h => ({ payable_line_status: { held: h } })) } as unknown as PayPeriod['time_tracking'];
}

describe('pay-run exclusion counts', () => {
  it('sums classified buckets across linked records', () => {
    const tracking = timeTracking(
      { entry_count: 2, total_hours: 1, by_category: { not_paid_by_decision: bucket(1), needs_action: bucket(0) } },
      { entry_count: 1, total_hours: 3, by_category: { needs_action: bucket(1) } },
    );
    expect(payRunExclusionCounts(tracking)).toEqual({ not_paid_by_decision: 1, needs_action: 1 });
    expect(payRunUnclassifiedExclusionCount(tracking)).toBe(0);
    expect(exclusionCountMessages(payRunExclusionCounts(tracking))).toEqual({
      action: '1 time entry needs action', information: ['1 denied entry, not paid'],
    });
  });

  it('keeps older totals-only payloads visible instead of dropping them', () => {
    const tracking = timeTracking({ entry_count: 2, total_hours: 4 }, { entry_count: 1, total_hours: 1, by_category: { next_payroll: bucket(1) } });
    expect(payRunExclusionCounts(tracking)).toEqual({ next_payroll: 1 });
    expect(payRunUnclassifiedExclusionCount(tracking)).toBe(2);
  });

  it('reports nothing when no records are linked', () => {
    expect(payRunUnclassifiedExclusionCount(undefined)).toBe(0);
    expect(exclusionCountMessages(payRunExclusionCounts(undefined))).toEqual({ action: null, information: [] });
  });
});
