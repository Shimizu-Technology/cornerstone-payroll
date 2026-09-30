// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AireFinalizedBatchAction } from './AireFinalizedBatchAction';

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

afterEach(() => cleanup());

describe('AireFinalizedBatchAction', () => {
  it('gives an editable payroll one clear review-and-add action', async () => {
    const onReview = vi.fn();
    const user = userEvent.setup();
    render(
      <AireFinalizedBatchAction
        batch={batch}
        payPeriodStatus="draft"
        aireRecordLinked={false}
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
        aireRecordLinked={false}
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
        aireRecordLinked
        onReview={vi.fn()}
      />
    );

    expect(screen.getByText('AIRE hours are in this payroll')).toBeTruthy();
    expect(screen.queryByRole('button')).toBeNull();
    expect(screen.getByText(/Next: select Calculate Payroll/i)).toBeTruthy();
  });
});
