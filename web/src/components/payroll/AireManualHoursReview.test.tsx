// @vitest-environment jsdom

import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react';
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
  it('shows exact time tracking regular, overtime, carryover, and the Payroll correction to make', async () => {
    render(
      <AireManualHoursReview
        payPeriodId={67}
        payPeriodStatus="draft"
        payrollHours={{ '7': { regular: 21.1, overtime: 1 } }}
        aireRecordLinked={false}
      />
    );

    expect(await screen.findByText('Live time tracking readiness')).toBeTruthy();
    expect(screen.getAllByText('Includes 6.10 carryover')).toHaveLength(2);
    expect(screen.getAllByText('The verified batch will replace manual entry after cutoff.')).toHaveLength(2);
    expect(screen.getByText('Malia Cruz · 2.50 hrs')).toBeTruthy();
    expect(screen.getByText(/carries its exact entry links through calculation/i)).toBeTruthy();
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
    expect(screen.getAllByText('The verified batch will replace manual entry after cutoff.')).toHaveLength(2);
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

  it('refreshes live time tracking totals and explains automatic paid-state sync for a linked run', async () => {
    const user = userEvent.setup();
    render(
      <AireManualHoursReview
        payPeriodId={67}
        payPeriodStatus="committed"
        payrollHours={{ '7': { regular: 27.2, overtime: 1 } }}
        aireRecordLinked
      />
    );
    await screen.findByText(/reports check preparation and delivery back to time tracking/i);

    await user.click(screen.getByRole('button', { name: 'Refresh check' }));
    await waitFor(() => expect(apiMocks.manualReview).toHaveBeenCalledTimes(2));
  });

  it('keeps manual payroll available when time tracking cannot be reached', async () => {
    apiMocks.manualReview.mockRejectedValue(new Error('time tracking is temporarily unavailable'));
    render(
      <AireManualHoursReview
        payPeriodId={67}
        payPeriodStatus="draft"
        payrollHours={{}}
        aireRecordLinked={false}
      />
    );

    expect(await screen.findByText('The live time tracking preview could not load.')).toBeTruthy();
    expect(screen.getByText(/Refresh before using time tracking hours for payroll/i)).toBeTruthy();
  });
});

it('shows historical evidence and wage differences without claiming another payment', async () => {
  apiMocks.manualReview.mockResolvedValue({
    ...review,
    cornerstone_manual_allocations: [{ id: 1, employee_name: 'Example Worker', source_time_entry_id: '301',
      original_work_date: '2026-08-20', regular_hours: 4, overtime_hours: 0, status: 'issued' }],
    historical_classification_reviews: [{ id: 1, employee_name: 'Example Worker', check_number: '2001',
      source_entry_count: 1, source_regular_hours: 3, source_overtime_hours: 1,
      payroll_regular_hours: 4, payroll_overtime_hours: 0, gross_wage_difference: 5,
      status: 'complete', note: 'Owner confirmed historical check; wage split still needs review' }],
  });
  render(<AireManualHoursReview payPeriodId={9} payPeriodStatus="committed" payrollHours={{}} aireRecordLinked={false} />);
  await screen.findByRole('region', { name: 'Historical payment reconciliation' });
  expect(screen.getByText(/does not create another paycheck/)).toBeTruthy();
  expect(screen.getByText(/Gross wage difference: \+\$5.00/)).toBeTruthy();
  expect(screen.getByText(/wage split still needs review/)).toBeTruthy();
});

it('shows the direction when issued check wages exceed the source estimate', async () => {
  apiMocks.manualReview.mockResolvedValue({ ...review, historical_classification_reviews: [{
    id: 2, employee_name: 'Example Worker', check_number: '2002', source_entry_count: 1,
    source_regular_hours: 4, source_overtime_hours: 0, payroll_regular_hours: 3, payroll_overtime_hours: 1,
    gross_wage_difference: -5, status: 'complete', note: 'Retained for review',
  }] });
  render(<AireManualHoursReview payPeriodId={9} payPeriodStatus="committed" payrollHours={{}} aireRecordLinked={false} />);
  expect(await screen.findByText(/Gross wage difference: −\$5.00 \(issued check wages exceed time tracking estimate\)/)).toBeTruthy();
});

it('keeps owner-reported historical payments visibly held pending check evidence', async () => {
  apiMocks.manualReview.mockResolvedValue({ ...review, payment_attestations: [{
    id: 1, source_time_entry_id: '501', source_user_uuid: 'example', hours: 4,
    original_work_date: '2026-08-20', status: 'pending_evidence', attested_at: '2026-09-01',
    source_changed: true, evidence_needed: 'Supply the issued check and delivery record',
  }] });
  render(<AireManualHoursReview payPeriodId={9} payPeriodStatus="committed" payrollHours={{}} aireRecordLinked={false} />);
  await screen.findByRole('region', { name: 'Payment evidence pending' });
  expect(screen.getByText(/excluded from payable hours/)).toBeTruthy();
  expect(screen.getByText(/Supply the issued check/)).toBeTruthy();
  expect(screen.getByText(/source changed after/)).toBeTruthy();
});


it('retains the read-only snapshot and payroll values during same-period source refresh', async () => {
  const props = { payPeriodId: 67, payPeriodStatus: 'draft' as const, payrollHours: { '7': { regular: 7.25, overtime: 1 } }, aireRecordLinked: false };
  const view = render(<AireManualHoursReview {...props} />);
  const retained = (await screen.findAllByText('Includes 6.10 carryover'))[0];
  let resolveRefresh!: (value: typeof review) => void;
  apiMocks.manualReview.mockImplementationOnce(() => new Promise(resolve => { resolveRefresh = resolve; }));
  view.rerender(<AireManualHoursReview {...props} refreshToken={1} />);
  expect(screen.getByRole('status').textContent).toContain('Refreshing live time tracking readiness');
  expect(screen.queryByText(/Comparing time tracking with the hours entered/)).toBeNull();
  expect(screen.getAllByText('Includes 6.10 carryover')[0]).toBe(retained);
  expect(screen.getAllByText('7.25 regular · 1.00 OT')).toHaveLength(2);
  await act(async () => resolveRefresh({ ...review, summary: { ...review.summary, total_hours: 34.2, regular_hours: 33.2 } }));
  expect(await screen.findByText('33.20 regular · 1.00 OT')).toBeTruthy();
  expect(screen.getAllByText('7.25 regular · 1.00 OT')).toHaveLength(2);
  expect(screen.queryByRole('status')).toBeNull();
});

it('clears the retained snapshot on period change and ignores the old-period response', async () => {
  const props = { payPeriodId: 67, payPeriodStatus: 'draft' as const, payrollHours: {}, aireRecordLinked: false };
  const view = render(<AireManualHoursReview {...props} />);
  await screen.findAllByText('Traven Cruz');
  let resolveOld!: (value: typeof review) => void;
  apiMocks.manualReview.mockImplementationOnce(() => new Promise(resolve => { resolveOld = resolve; }));
  view.rerender(<AireManualHoursReview {...props} refreshToken={1} />);
  apiMocks.manualReview.mockResolvedValue({ ...review, employees: [] });
  view.rerender(<AireManualHoursReview {...props} payPeriodId={68} refreshToken={1} />);
  expect(screen.queryAllByText('Traven Cruz')).toHaveLength(0);
  await waitFor(() => expect(apiMocks.manualReview).toHaveBeenCalledTimes(3));
  await act(async () => resolveOld(review));
  expect(screen.queryAllByText('Traven Cruz')).toHaveLength(0);
});
