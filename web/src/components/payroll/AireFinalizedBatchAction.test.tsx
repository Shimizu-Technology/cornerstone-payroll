// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AireFinalizedBatchAction } from './AireFinalizedBatchAction';
import type { AirePayrollRecord } from '@/types';

const batch = {
  event_id: 'event-1',
  verification_status: 'verified' as const,
  verification_attempts: 1,
  occurred_at: '2026-09-23T09:00:00+10:00',
  verified_at: '2026-09-23T09:01:00+10:00',
  payroll_batch_id: 'AIRE-PAY-20260915',
  payroll_batch_checksum: 'a'.repeat(64),
  summary: {
    employee_count: 2,
    exclusion_count: 1,
    total_hours: 72.5,
    regular_hours: 69,
    overtime_hours: 3.5,
  },
};

const bucket = (lineCount: number, totalHours: number) => ({
  line_count: lineCount,
  total_hours: totalHours,
  regular_hours: totalHours,
  overtime_hours: 0,
});

const linkedRecord = (overrides: Partial<NonNullable<AirePayrollRecord['payable_line_status']>> = {}): AirePayrollRecord => ({
  id: 9,
  source_name: 'AIRE Services',
  source_active: true,
  external_batch_id: batch.payroll_batch_id,
  external_batch_checksum: batch.payroll_batch_checksum,
  contract_version: '2.0',
  source_cutoff_at: batch.occurred_at,
  payable_line_status: {
    line_count: 2,
    total_hours: 72.5,
    regular_hours: 69,
    overtime_hours: 3.5,
    in_payroll: bucket(2, 72.5),
    payment_pending: bucket(0, 0),
    paid: bucket(0, 0),
    needs_attention: bucket(0, 0),
    held: { entry_count: 1, total_hours: 4 },
    synchronization: { pending_event_count: 0, failed_event_count: 0, last_confirmed_at: null },
    ...overrides,
  },
});

afterEach(() => cleanup());

describe('AireFinalizedBatchAction', () => {
  it('gives an editable payroll one clear review-and-add action', async () => {
    const onReview = vi.fn();
    const user = userEvent.setup();
    render(
      <AireFinalizedBatchAction
        batch={batch}
        payPeriodStatus="draft"
        onReview={onReview}
      />
    );

    expect(screen.getByText('AIRE hours are ready to add')).toBeTruthy();
    expect(screen.getByText('72.50 hrs')).toBeTruthy();
    expect(screen.getByText('69.00 hrs')).toBeTruthy();
    expect(screen.getByText('3.50 hrs')).toBeTruthy();
    expect(screen.getByText('1 held entry tracked for later')).toBeTruthy();

    await user.click(screen.getByRole('button', { name: /review and add AIRE hours/i }));
    expect(onReview).toHaveBeenCalledTimes(1);
  });

  it('shows the historical link action without implying payroll will change', () => {
    render(
      <AireFinalizedBatchAction
        batch={batch}
        payPeriodStatus="committed"
        onReview={vi.fn()}
      />
    );

    expect(screen.getByRole('button', { name: /review and link AIRE record/i })).toBeTruthy();
    expect(screen.getByText(/without changing the payroll/i)).toBeTruthy();
  });

  it('shows the calculation and payment handoff after the batch is linked', () => {
    render(
      <AireFinalizedBatchAction
        batch={batch}
        payPeriodStatus="draft"
        aireRecord={linkedRecord()}
        onReview={vi.fn()}
      />
    );

    expect(screen.getByText('AIRE hours are in this payroll')).toBeTruthy();
    expect(screen.queryByRole('button')).toBeNull();
    expect(screen.getByText(/Next: select Calculate Payroll/i)).toBeTruthy();
  });

  it('shows committed lines without delivery evidence as payment pending', () => {
    render(
      <AireFinalizedBatchAction
        batch={batch}
        payPeriodStatus="committed"
        aireRecord={linkedRecord()}
        onReview={vi.fn()}
      />
    );

    expect(screen.getByText('AIRE hours are linked; payment evidence is pending')).toBeTruthy();
    expect(screen.getByText('Payment pending')).toBeTruthy();
    expect(screen.getByText('72.50 hrs', { selector: '.font-display.text-lg' })).toBeTruthy();
    expect(screen.getByText(/committed payroll records remain unpaid/i)).toBeTruthy();
  });

  it('calls hours paid only when every payable line has issuance evidence', () => {
    render(
      <AireFinalizedBatchAction
        batch={batch}
        payPeriodStatus="committed"
        aireRecord={linkedRecord({
          in_payroll: bucket(0, 0),
          paid: bucket(2, 72.5),
        })}
        onReview={vi.fn()}
      />
    );

    expect(screen.getByText('AIRE hours are paid')).toBeTruthy();
    expect(screen.getByText(/delivery or settlement evidence for every linked payable line/i)).toBeTruthy();
  });

  it('surfaces failed, voided, or missing payment evidence', () => {
    render(
      <AireFinalizedBatchAction
        batch={batch}
        payPeriodStatus="committed"
        aireRecord={linkedRecord({
          line_count: 3,
          total_hours: 74.5,
          in_payroll: bucket(2, 72.5),
          needs_attention: bucket(1, 2),
        })}
        onReview={vi.fn()}
      />
    );

    expect(screen.getByText('AIRE payment needs attention')).toBeTruthy();
    expect(screen.getByText('Needs attention')).toBeTruthy();
    expect(screen.getByText(/failed and voided payments require an explicit follow-up/i)).toBeTruthy();
  });
});
