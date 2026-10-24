// @vitest-environment jsdom

import { cleanup, render, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AirePayrollCalendarState, AirePayrollRecord } from '@/types';
import { AireSourceCheckpointSummary } from './AireSourceCheckpointSummary';

const calendar: AirePayrollCalendarState = {
  enabled: true, source_id: 1, source_name: 'Time tracking', eligible: true,
  cutoff_at: '2026-10-22T17:00:00+10:00', cutoff_state: 'scheduled',
  needs_revision: false, can_publish: false, can_retry: false,
};
const batch: NonNullable<AirePayrollCalendarState['finalized_batch']> = {
  event_id: 'frozen-event', verification_status: 'verified', verification_attempts: 1,
  occurred_at: calendar.cutoff_at!, payroll_batch_id: 'batch', payroll_batch_checksum: 'checksum',
  summary: { total_hours: 81, regular_hours: 76, overtime_hours: 5, employee_count: 4, exclusion_count: 2 },
  issues: { pending_approval_count: 1, pending_overtime_count: 1 },
};
const props = {
  calendar, overview: null, aireRecord: null, payPeriodStatus: 'draft' as const,
  sourceCoverageRequired: false, canReviewTimecards: false, loading: false,
  onReview: vi.fn(), onReviewTimecards: vi.fn(), onReviewSource: vi.fn(),
};
const bucket = (count: number) => ({ line_count: count, total_hours: count * 8, regular_hours: count * 8, overtime_hours: 0 });
const linkedRecord: AirePayrollRecord = {
  id: 1, source_name: 'Time tracking', source_active: true, external_batch_id: 'batch',
  external_batch_checksum: 'checksum', contract_version: '2.0', source_cutoff_at: calendar.cutoff_at!,
  payable_line_status: { line_count: 1, total_hours: 8, regular_hours: 8, overtime_hours: 0,
    in_payroll: bucket(1), payment_pending: bucket(0), paid: bucket(0), needs_attention: bucket(0),
    held: { entry_count: 0, total_hours: 0 },
    synchronization: { pending_event_count: 0, failed_event_count: 0 },
  },
};

afterEach(cleanup);

describe('AireSourceCheckpointSummary', () => {
  it('does not label frozen after-cutoff exclusions as approvals still needed', () => {
    render(<AireSourceCheckpointSummary {...props} calendar={{ ...calendar, finalized_batch: {
      ...batch, issues: { ...batch.issues, missing_category_count: 1 },
    } }} />);
    expect(screen.getByText('1 awaiting approval or submitted/approved after cutoff · 1 overtime pending or approved after cutoff')).toBeTruthy();
    expect(screen.queryByText(/missing category/)).toBeNull();
  });

  it('keeps missing totals and held counts unknown rather than claiming zero hours', () => {
    render(<AireSourceCheckpointSummary {...props} calendar={{ ...calendar, finalized_batch: { ...batch, summary: undefined, issues: undefined } }} />);
    expect(screen.getByText('— regular + — OT · — people')).toBeTruthy();
    expect(screen.getByText('Held entry count unavailable')).toBeTruthy();
    expect(screen.queryByText(/0\.00/)).toBeNull();
  });

  it.each([
    ['in_payroll', 'Time tracking hours are linked; payment evidence is pending.'],
    ['payment_pending', 'Time tracking hours are linked; payment evidence is pending.'],
    ['needs_attention', 'Time tracking payment needs attention. Review the payment history.'],
    ['paid', 'Time tracking hours are paid; delivery or settlement is recorded.'],
  ] as const)('preserves committed %s payment meaning without offering import again', (state, label) => {
    const status = { ...linkedRecord.payable_line_status!, in_payroll: bucket(0), [state]: bucket(1) };
    render(<AireSourceCheckpointSummary {...props} payPeriodStatus="committed" aireRecord={{ ...linkedRecord, payable_line_status: status }} calendar={{ ...calendar, finalized_batch: batch }} />);
    expect(screen.getByText(label)).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Review and (add|link)/ })).toBeNull();
  });

  it('calls signed corrections batch totals and keeps their review action', () => {
    render(<AireSourceCheckpointSummary {...props} calendar={{ ...calendar, finalized_batch: { ...batch,
      summary: { ...batch.summary, total_hours: -1, regular_hours: -1, overtime_hours: 0, correction_count: 1 },
    } }} />);
    expect(screen.getByText(/Signed batch totals include corrections/)).toBeTruthy();
    expect(screen.getByText('-1.00 h in locked batch')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Review time tracking corrections' })).toBeTruthy();
  });

  it.each([
    ['scheduled', 'Locks'], ['cutoff_due', 'Due — waiting for time tracking'],
    ['batch_verifying', 'Locked — verifying batch'], ['batch_rejected', 'Locked — batch needs review'],
  ] as const)('shows the authoritative %s cutoff state and plain ChST time', (state, label) => {
    render(<AireSourceCheckpointSummary {...props} calendar={{ ...calendar, cutoff_state: state }} />);
    const region = screen.getByRole('region', { name: 'Source checkpoint' });
    expect(within(region).getByText(`${label} · Oct 22, 2026, 5:00 PM ChST`)).toBeTruthy();
    expect(within(region).getByText('No locked batch added')).toBeTruthy();
  });
});
