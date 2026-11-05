// @vitest-environment jsdom

import { cleanup, render, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AirePayrollCalendarState, AirePayrollCockpitOverview, AirePayrollRecord } from '@/types';
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
    ['recorded_before_line_tracking', 'Time tracking hours are linked. This payroll was recorded before line-by-line payment tracking; its checks show payment.'],
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

it('uses person for a one-person locked batch', () => {
  render(<AireSourceCheckpointSummary {...props} calendar={{ ...calendar, finalized_batch: { ...batch, summary: { ...batch.summary!, employee_count: 1 } } }} />);
  expect(screen.getByText(/1 person$/)).toBeTruthy();
});

it('explains manual mode in the compact Hours checkpoint without a nominal-cutoff deadline', () => {
  render(<AireSourceCheckpointSummary {...props} calendar={{ ...calendar, lock_mode: 'manual', cutoff_state: 'manual' }} />);
  const checkpoint = screen.getByRole('region', { name: 'Source checkpoint' });
  expect(within(checkpoint).getByText('Lock manually when you are ready')).toBeTruthy();
  expect(within(checkpoint).queryByText(/Oct 22/)).toBeNull();
});

it('labels a manually locked batch while its verification is still pending', () => {
  render(<AireSourceCheckpointSummary {...props} calendar={{ ...calendar, lock_mode: 'manual', cutoff_state: 'batch_verifying', finalized_batch: { ...batch, verification_status: 'pending' } }} />);
  expect(within(screen.getByRole('region', { name: 'Source checkpoint' })).getByText('Locked manually')).toBeTruthy();
});

it('names the scheduled November cutoff plainly inside the compact checkpoint', () => {
  render(<AireSourceCheckpointSummary {...props} calendar={{ ...calendar, lock_mode: 'scheduled', cutoff_at: '2026-11-07T17:00:00+10:00' }} />);
  expect(within(screen.getByRole('region', { name: 'Source checkpoint' })).getByText('Locks automatically Nov 7, 5:00 p.m. ChST')).toBeTruthy();
});

describe('committed run with a linked record and no batch', () => {
  const earlierStatus = {
    ...linkedRecord.payable_line_status!, line_count: 134, total_hours: 599.06, regular_hours: 578.49, overtime_hours: 20.57,
    in_payroll: bucket(0), recorded_before_line_tracking: { line_count: 134, total_hours: 599.06, regular_hours: 578.49, overtime_hours: 20.57 },
    held: { entry_count: 10, total_hours: 6.1 },
  };
  const earlierRecord = { ...linkedRecord, payable_line_status: earlierStatus };
  const notEffective = { ...calendar, eligible: false, cutoff_at: null, cutoff_state: 'unpublished' as const, finalized_batch: null,
    eligibility_code: 'pay_schedule_not_effective' as const, eligibility_error: 'This pay period begins before the confirmed payroll setup takes effect.' };

  it('shows the record totals, held count and a neutral schedule note', () => {
    render(<AireSourceCheckpointSummary {...props} payPeriodStatus="committed" calendar={notEffective} aireRecord={earlierRecord} />);
    expect(screen.getByText('599.06 h linked to payroll')).toBeTruthy();
    expect(screen.getByText('578.49 regular + 20.57 OT · 134 lines')).toBeTruthy();
    expect(screen.getByText('10 held entries excluded').className).not.toContain('warning');
    expect(screen.getByText('6.10 h outside this payroll; see the linked time record.')).toBeTruthy();
    expect(screen.getByText(/^Source cutoff · /)).toBeTruthy();
    expect(screen.getByRole('status').className).toContain('text-neutral-700');
    expect(screen.getByRole('status').textContent).toBe(notEffective.eligibility_error);
    expect(screen.queryByText(/after batch verification|count unavailable|Cutoff not published/)).toBeNull();
    expect(screen.getByLabelText('Source checkpoint').querySelector('[class*="warning"]')).toBeNull();
  });

  it('keeps the schedule note as a warning without a linked record or with a batch', () => {
    const { unmount } = render(<AireSourceCheckpointSummary {...props} payPeriodStatus="committed" calendar={notEffective} aireRecord={null} />);
    expect(screen.getByRole('status').className).toContain('text-warning-900');
    unmount();
    render(<AireSourceCheckpointSummary {...props} payPeriodStatus="committed" calendar={{ ...notEffective, finalized_batch: batch }} aireRecord={earlierRecord} />);
    expect(screen.getByRole('status').className).toContain('text-warning-900');
  });

  it('does not explain the frozen held count with live approval counts', () => {
    const overview = { payroll_period: { lock_mode: 'manual' }, readiness: { held_entries: 3, eligible_hours: 40, pending_approvals: 3, pending_overtime: 1, missing_punches: 2 } } as unknown as AirePayrollCockpitOverview;
    render(<AireSourceCheckpointSummary {...props} overview={overview} payPeriodStatus="committed" calendar={notEffective} aireRecord={earlierRecord} />);
    expect(screen.getByText('6.10 h outside this payroll; see the linked time record.')).toBeTruthy();
    expect(screen.queryByText(/approval|missing punch/)).toBeNull();
  });

  it('keeps live missing payment evidence beside the frozen held hours', () => {
    const overview = { payroll_period: { lock_mode: 'manual' }, readiness: { held_entries: 3, pending_approvals: 3, payment_attested_pending_evidence_entries: 2 } } as unknown as AirePayrollCockpitOverview;
    render(<AireSourceCheckpointSummary {...props} overview={overview} payPeriodStatus="committed" calendar={notEffective} aireRecord={earlierRecord} />);
    expect(screen.getByText('6.10 h outside this payroll; see the linked time record. · 2 payment reports awaiting evidence')).toBeTruthy();
  });

  it('keeps live reasons on an editable run', () => {
    const overview = { payroll_period: { lock_mode: 'manual' }, readiness: { held_entries: 3, pending_approvals: 3 } } as unknown as AirePayrollCockpitOverview;
    render(<AireSourceCheckpointSummary {...props} overview={overview} payPeriodStatus="draft" calendar={notEffective} aireRecord={earlierRecord} />);
    expect(screen.getByText('3 approvals needed')).toBeTruthy();
  });

  it('notes signed totals when the record has accounting corrections', () => {
    const status = { ...earlierStatus, accounting_corrections: { line_count: 1, total_hours: -2, regular_hours: -2, overtime_hours: 0 } };
    render(<AireSourceCheckpointSummary {...props} payPeriodStatus="committed" calendar={notEffective} aireRecord={{ ...earlierRecord, payable_line_status: status }} />);
    expect(screen.getByText('Signed totals include accounting corrections.')).toBeTruthy();
  });

  it('does not present a live estimate as this run\'s held count', () => {
    const overview = { payroll_period: { lock_mode: 'manual' }, readiness: { held_entries: 3, eligible_hours: 40 } } as unknown as AirePayrollCockpitOverview;
    render(<AireSourceCheckpointSummary {...props} overview={overview} payPeriodStatus="committed" calendar={notEffective} aireRecord={earlierRecord} />);
    expect(screen.getByText('10 held entries excluded')).toBeTruthy();
    expect(screen.queryByText(/live estimate/)).toBeNull();
  });

  it.each([
    ['needs_attention', 'Time tracking payment needs attention. Review the payment history.'],
    ['payment_pending', 'Time tracking hours are linked; payment evidence is pending.'],
  ] as const)('keeps the %s warning', (state, message) => {
    const status = { ...earlierStatus, [state]: bucket(2), recorded_before_line_tracking: { ...earlierStatus.recorded_before_line_tracking, line_count: 132 } };
    render(<AireSourceCheckpointSummary {...props} payPeriodStatus="committed" calendar={notEffective} aireRecord={{ ...earlierRecord, payable_line_status: status }} />);
    expect(screen.getByText(message).className).toContain('text-warning-900');
  });

  it('still surfaces a connection error', () => {
    const publication = { id: 1, schedule_version: 1, publication_id: 'synthetic', delivery_status: 'failed' as const, delivery_attempts: 2, last_error: 'Connection unavailable' };
    render(<AireSourceCheckpointSummary {...props} payPeriodStatus="committed" calendar={{ ...notEffective, publication }} aireRecord={earlierRecord} />);
    expect(screen.getByRole('alert').textContent).toBe('Connection unavailable');
  });

  it('leaves a batch still being verified on its live wording', () => {
    const pending = { ...batch, verification_status: 'pending' as const };
    render(<AireSourceCheckpointSummary {...props} payPeriodStatus="committed" calendar={{ ...notEffective, finalized_batch: pending }} aireRecord={earlierRecord} />);
    expect(screen.getByText('Source hours linked to payroll')).toBeTruthy();
    expect(screen.getByText('Held entry count unavailable')).toBeTruthy();
  });

  it('does not say hours are linked when a completed payroll has no record', () => {
    render(<AireSourceCheckpointSummary {...props} payPeriodStatus="committed" calendar={notEffective} />);
    expect(screen.getByText('No time tracking record is linked to this completed payroll.')).toBeTruthy();
    expect(screen.queryByText(/after batch verification/)).toBeNull();
  });

  it.each(['draft', 'calculated', 'approved'] as const)('keeps the %s run warning and live wording', (payPeriodStatus) => {
    render(<AireSourceCheckpointSummary {...props} payPeriodStatus={payPeriodStatus} calendar={notEffective} aireRecord={earlierRecord} />);
    expect(screen.getByRole('status').className).toContain('text-warning-900');
    expect(screen.getByText('Regular / OT / people available after batch verification.')).toBeTruthy();
    expect(screen.getByText('Source hours linked to payroll')).toBeTruthy();
    expect(screen.getByText('Cutoff not published · cutoff time unavailable')).toBeTruthy();
    cleanup();
  });
});
