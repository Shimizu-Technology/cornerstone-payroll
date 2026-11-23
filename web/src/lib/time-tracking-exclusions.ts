import type { PayPeriod, TimeTrackingExclusionCategory, TimeTrackingExclusionCounts } from '@/types';

export const exclusionCategoryLabels: Record<TimeTrackingExclusionCategory, string> = {
  needs_action: 'Needs action',
  not_paid_by_decision: 'Not paid by decision',
  next_payroll: 'Next payroll',
  payment_evidence_pending: 'Payment evidence pending',
};

export function exclusionCountMessages(counts: TimeTrackingExclusionCounts) {
  const { needs_action: action = 0, not_paid_by_decision: denied = 0, next_payroll: next = 0, payment_evidence_pending: evidence = 0 } = counts;
  return {
    action: action === 0 ? null : action === 1 ? '1 time entry needs action' : `${action} time entries need action`,
    information: [
      denied === 0 ? null : `${denied} denied ${denied === 1 ? 'entry' : 'entries'}, not paid`,
      next === 0 ? null : next === 1 ? '1 entry moves to the next payroll' : `${next} entries move to the next payroll`,
      evidence === 0 ? null : `${evidence} ${evidence === 1 ? 'entry awaits' : 'entries await'} payment evidence`,
    ].filter((message): message is string => message !== null),
  };
}

export function payRunExclusionCounts(timeTracking: PayPeriod['time_tracking']): TimeTrackingExclusionCounts {
  const counts: TimeTrackingExclusionCounts = {};
  for (const record of timeTracking?.linked_source_records ?? timeTracking?.linked_aire_records ?? []) {
    for (const [category, bucket] of Object.entries(record.payable_line_status?.held.by_category ?? {})) {
      const key = category as TimeTrackingExclusionCategory;
      counts[key] = (counts[key] ?? 0) + bucket.entry_count;
    }
  }
  return counts;
}

// Older payloads carry only totals; their entries can't be classified, so
// the header still points staff at them instead of hiding them.
export function payRunUnclassifiedExclusionCount(timeTracking: PayPeriod['time_tracking']) {
  return (timeTracking?.linked_source_records ?? timeTracking?.linked_aire_records ?? [])
    .reduce((sum, record) => {
      const held = record.payable_line_status?.held;
      return held && !held.by_category ? sum + held.entry_count : sum;
    }, 0);
}

export function countExcludedEntries(entries: { exclusion_category?: TimeTrackingExclusionCategory; held_total_hours: number }[]): TimeTrackingExclusionCounts {
  const counts: TimeTrackingExclusionCounts = {};
  for (const entry of entries) {
    const category = entry.exclusion_category;
    if (!category || !(Number(entry.held_total_hours) > 0)) continue;
    counts[category] = (counts[category] ?? 0) + 1;
  }
  return counts;
}

export function linkedExclusionMessages(held: NonNullable<import('@/types').AirePayrollRecord['payable_line_status']>['held']) {
  if (!held.by_category) return held.entry_count > 0 ? ['Review entries outside this payroll'] : [];
  const counts = Object.fromEntries(Object.entries(held.by_category).map(([category, bucket]) => [category, bucket.entry_count]));
  const { action, information } = exclusionCountMessages(counts);
  return action ? [action, ...information] : information;
}
