import { describe, expect, it } from 'vitest';
import { needsSourceCoverageAcknowledgement } from './payroll-source-coverage';
import type { PayPeriod } from '@/types';
const period = { status: 'draft', run_purpose: 'regular', time_tracking: { aire_calendar: { enabled: true, cutoff_at: '2026-10-22T07:00:00Z' }, linked_aire_records: [] } } as unknown as PayPeriod;
describe('scheduled source coverage', () => {
  it('requires acknowledgement before calculating without imported hours, including a verified batch awaiting import', () => {
    expect(needsSourceCoverageAcknowledgement(period)).toBe(true);
    expect(needsSourceCoverageAcknowledgement({ ...period, status: 'approved' })).toBe(true);
    expect(needsSourceCoverageAcknowledgement({ ...period, time_tracking: { ...period.time_tracking!, aire_calendar: { ...period.time_tracking!.aire_calendar!, cutoff_state: 'batch_verified' } } })).toBe(true);
  });
  it('leaves imported, manual, special and committed workflows alone', () => {
    expect(needsSourceCoverageAcknowledgement({ ...period, time_tracking: { ...period.time_tracking!, linked_aire_records: [{ id: 1 }] as never } })).toBe(false);
    expect(needsSourceCoverageAcknowledgement({ ...period, time_tracking: undefined })).toBe(false);
    expect(needsSourceCoverageAcknowledgement({ ...period, run_purpose: 'adjustment' })).toBe(false);
    expect(needsSourceCoverageAcknowledgement({ ...period, status: 'committed' })).toBe(false);
  });
});
