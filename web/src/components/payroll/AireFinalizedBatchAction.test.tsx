// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AireFinalizedBatchAction } from './AireFinalizedBatchAction';
import type { AirePayrollRecord, PayPeriodStatus } from '@/types';

const batch = {
  event_id: 'event-1',
  verification_status: 'verified' as const,
  verification_attempts: 1,
  occurred_at: '2026-09-23T09:00:00+10:00',
  verified_at: '2026-09-23T09:01:00+10:00',
  payroll_batch_id: 'time tracking-PAY-20260915',
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
  source_name: 'time tracking Services',
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

    expect(screen.getByText('Time tracking hours are ready to add')).toBeTruthy();
    expect(screen.getByText('72.50 hrs')).toBeTruthy();
    expect(screen.getByText('69.00 hrs')).toBeTruthy();
    expect(screen.getByText('3.50 hrs')).toBeTruthy();
    expect(screen.getByText('1 held entry tracked for later')).toBeTruthy();

    await user.click(screen.getByRole('button', { name: /review and add time tracking hours/i }));
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

    expect(screen.getByRole('button', { name: /review and link time tracking record/i })).toBeTruthy();
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

    expect(screen.getByText('Time tracking hours are in this payroll')).toBeTruthy();
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

    expect(screen.getByText('Time tracking hours are linked; payment evidence is pending')).toBeTruthy();
    expect(screen.getByText('Payment pending')).toBeTruthy();
    expect(screen.getByText('72.50 hrs', { selector: '.font-display.text-lg' })).toBeTruthy();
    expect(screen.getByText(/Added to payroll; payment not yet recorded/i)).toBeTruthy();
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

    expect(screen.getByText('Time tracking hours are paid')).toBeTruthy();
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

    expect(screen.getByText('time tracking payment needs attention')).toBeTruthy();
    expect(screen.getByText('Needs attention')).toBeTruthy();
    expect(screen.getByText(/failed and voided payments require an explicit follow-up/i)).toBeTruthy();
  });
});


it.each([
  ['draft', 'Next: select Calculate Payroll.'],
  ['calculated', 'Next: review the calculated payroll, then select Approve when ready.'],
  ['approved', 'Next: select Commit & Finalize when the approved payroll is ready.'],
] as const)('gives an added batch the next action for the actual %s payroll status', (status, nextAction) => {
  const onReview = vi.fn();
  render(<AireFinalizedBatchAction batch={batch} payPeriodStatus={status} aireRecord={linkedRecord()} onReview={onReview} />);
  expect(screen.getByText(nextAction, { exact: false })).toBeTruthy();
  if (status !== 'draft') expect(screen.queryByText(/Next: select Calculate Payroll/)).toBeNull();
  expect(screen.getByText(/Adding the batch records hours in payroll; it does not mark anyone paid/)).toBeTruthy();
  expect(screen.queryByRole('button')).toBeNull();
  expect(onReview).not.toHaveBeenCalled();
});

it('updates guidance through calculation, approval, rollback and commit without treating those stages as payment', () => {
  const onReview = vi.fn();
  const view = render(<AireFinalizedBatchAction batch={batch} payPeriodStatus="draft" aireRecord={linkedRecord()} onReview={onReview} />);
  for (const status of ['calculated', 'approved', 'calculated', 'draft', 'committed'] as PayPeriodStatus[]) {
    view.rerender(<AireFinalizedBatchAction batch={batch} payPeriodStatus={status} aireRecord={linkedRecord()} onReview={onReview} />);
    if (status === 'calculated') expect(screen.getByText(/Next: review the calculated payroll, then select Approve when ready/)).toBeTruthy();
    else if (status === 'approved') expect(screen.getByText(/Next: select Commit & Finalize when the approved payroll is ready/)).toBeTruthy();
    else if (status === 'draft') expect(screen.getByText(/Next: select Calculate Payroll/)).toBeTruthy();
    else {
      expect(screen.queryByText(/Next:/)).toBeNull();
      expect(screen.getByText('Time tracking hours are linked; payment evidence is pending')).toBeTruthy();
      expect(screen.getByText(/Delivery or settlement establishes paid status/)).toBeTruthy();
    }
    expect(screen.queryByText('Time tracking hours are paid')).toBeNull();
    expect(screen.queryByRole('button')).toBeNull();
  }
  expect(onReview).not.toHaveBeenCalled();
});
