// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AireManualHoursReview } from './AireManualHoursReview';

const apiMocks = vi.hoisted(() => ({ manualReview: vi.fn() }));

vi.mock('@/services/api', () => ({
  payPeriodsApi: { airePayrollManualReview: apiMocks.manualReview },
}));

const review = {
  start_date: '2026-08-16',
  end_date: '2026-08-31',
  generated_at: '2026-09-15T09:00:00+10:00',
  employees: [{
    source_user_id: '91',
    source_user_uuid: '282bf986-dd27-46fa-bd70-65ebbc9d9cea',
    display_name: 'Traven Cruz',
    total_hours: 28.2,
    regular_hours: 27.2,
    overtime_hours: 1,
    adjustments: [
      { source_time_entry_id: '40', source_kind: 'current', original_work_date: '2026-08-22', category: { name: 'Flight Hours' }, total_hours: 22.1, regular_hours: 21.1, overtime_hours: 1 },
      { source_time_entry_id: '41', source_kind: 'carryover', original_work_date: '2026-08-15', category: { name: 'Flight Hours' }, total_hours: 6.1, regular_hours: 6.1, overtime_hours: 0 },
    ],
    cornerstone: { status: 'mapped', employee_id: 7, employee_name: 'Traven Cruz' },
  }],
  exclusions: [{
    source_time_entry_id: '52',
    source_user_id: '92',
    display_name: 'Malia Cruz',
    original_work_date: '2026-08-29',
    reason: 'pending_approval',
    held_total_hours: 2.5,
    cornerstone: { status: 'mapped', employee_id: 8, employee_name: 'Malia Cruz' },
  }],
  issues: {
    missing_category_count: 0,
    negative_adjustment_count: 0,
    pending_approval_count: 1,
    denied_approval_count: 0,
    open_clock_count: 0,
    pending_overtime_count: 0,
    denied_overtime_count: 0,
  },
  summary: {
    employee_count: 1,
    adjustment_count: 2,
    total_hours: 28.2,
    regular_hours: 27.2,
    overtime_hours: 1,
    current_count: 1,
    carryover_count: 1,
    correction_count: 0,
    exclusion_count: 1,
  },
};

beforeEach(() => {
  vi.clearAllMocks();
  apiMocks.manualReview.mockResolvedValue(review);
});

afterEach(() => cleanup());

describe('AireManualHoursReview', () => {
  it('shows exact AIRE regular, overtime, carryover, and the Payroll correction to make', async () => {
    render(
      <AireManualHoursReview
        payPeriodId={67}
        payPeriodStatus="draft"
        payrollHours={{ '7': { regular: 21.1, overtime: 1 } }}
        aireRecordLinked={false}
      />
    );

    expect(await screen.findByText('Manual AIRE hours check')).toBeTruthy();
    expect(screen.getAllByText('Includes 6.10 carryover')).toHaveLength(2);
    expect(screen.getByText('Enter 27.20 regular and 1.00 OT in the payroll table.')).toBeTruthy();
    expect(screen.getByText('Malia Cruz · 2.50 hrs')).toBeTruthy();
    expect(screen.getByText(/there is no separate “mark paid” step in AIRE/i)).toBeTruthy();
  });

  it('updates the match result immediately as Payroll hours change', async () => {
    const view = render(
      <AireManualHoursReview
        payPeriodId={67}
        payPeriodStatus="draft"
        payrollHours={{ '7': { regular: 21.1, overtime: 1 } }}
        aireRecordLinked={false}
      />
    );
    await screen.findByText('Update needed');

    view.rerender(
      <AireManualHoursReview
        payPeriodId={67}
        payPeriodStatus="draft"
        payrollHours={{ '7': { regular: 27.2, overtime: 1 } }}
        aireRecordLinked={false}
      />
    );

    expect(screen.getAllByText('Matches')).toHaveLength(2);
    expect(screen.getByText('Regular and OT totals match')).toBeTruthy();
  });

  it('requires an exact hundredth-hour match', async () => {
    render(
      <AireManualHoursReview
        payPeriodId={67}
        payPeriodStatus="draft"
        payrollHours={{ '7': { regular: 27.19, overtime: 1 } }}
        aireRecordLinked={false}
      />
    );

    expect(await screen.findByText('Update needed')).toBeTruthy();
    expect(screen.getByText('Enter 27.20 regular and 1.00 OT in the payroll table.')).toBeTruthy();
  });

  it('counts negative corrections that need attention without double-counting exclusions', async () => {
    apiMocks.manualReview.mockResolvedValue({
      ...review,
      exclusions: [],
      issues: { ...review.issues, pending_approval_count: 0, negative_adjustment_count: 1 },
      summary: { ...review.summary, exclusion_count: 0 },
    });
    render(
      <AireManualHoursReview
        payPeriodId={67}
        payPeriodStatus="draft"
        payrollHours={{ '7': { regular: 27.2, overtime: 1 } }}
        aireRecordLinked={false}
      />
    );

    const attentionCard = (await screen.findByText('Needs attention')).parentElement;
    expect(attentionCard).not.toBeNull();
    expect(within(attentionCard as HTMLElement).getByText('1')).toBeTruthy();
  });

  it('refreshes live AIRE totals and explains automatic paid-state sync for a linked run', async () => {
    const user = userEvent.setup();
    render(
      <AireManualHoursReview
        payPeriodId={67}
        payPeriodStatus="committed"
        payrollHours={{ '7': { regular: 27.2, overtime: 1 } }}
        aireRecordLinked
      />
    );
    await screen.findByText(/Recording each check as issued automatically marks/i);

    await user.click(screen.getByRole('button', { name: 'Refresh check' }));
    await waitFor(() => expect(apiMocks.manualReview).toHaveBeenCalledTimes(2));
  });

  it('keeps manual payroll available when AIRE cannot be reached', async () => {
    apiMocks.manualReview.mockRejectedValue(new Error('AIRE is temporarily unavailable'));
    render(
      <AireManualHoursReview
        payPeriodId={67}
        payPeriodStatus="draft"
        payrollHours={{}}
        aireRecordLinked={false}
      />
    );

    expect(await screen.findByText('The manual check could not load.')).toBeTruthy();
    expect(screen.getByText(/You can still process payroll manually/i)).toBeTruthy();
  });
});
