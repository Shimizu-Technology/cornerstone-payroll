// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AireManualHoursReview } from './AireManualHoursReview';

const apiMocks = vi.hoisted(() => ({ manualReview: vi.fn(), link: vi.fn(), retry: vi.fn(), map: vi.fn() }));

vi.mock('@/services/api', () => ({
  payPeriodsApi: {
    airePayrollManualReview: apiMocks.manualReview,
    linkManualAireHours: apiMocks.link,
    retryManualAireHours: apiMocks.retry,
    mapAireEmployee: apiMocks.map,
  },
}));

const review = {
  start_date: '2026-08-16',
  end_date: '2026-08-31',
  generated_at: '2026-09-15T09:00:00+10:00',
  employees: [{
    source_user_id: '91',
    source_user_uuid: '282bf986-dd27-46fa-bd70-65ebbc9d9cea',
    display_name: 'Test Worker A',
    total_hours: 28.2,
    regular_hours: 27.2,
    overtime_hours: 1,
    adjustments: [
      { source_time_entry_id: '40', source_time_entry_version: 1, source_kind: 'current', original_work_date: '2026-08-22', category: { name: 'Flight Hours' }, total_hours: 22.1, regular_hours: 21.1, overtime_hours: 1 },
      { source_time_entry_id: '41', source_time_entry_version: 2, source_kind: 'carryover', original_work_date: '2026-08-15', category: { name: 'Flight Hours' }, total_hours: 6.1, regular_hours: 6.1, overtime_hours: 0 },
    ],
    cornerstone: { status: 'mapped', employee_id: 7, employee_name: 'Test Worker A' },
  }],
  exclusions: [{
    source_time_entry_id: '52',
    source_user_id: '92',
    display_name: 'Test Worker B',
    original_work_date: '2026-08-29',
    reason: 'pending_approval',
    held_total_hours: 2.5,
    cornerstone: { status: 'mapped', employee_id: 8, employee_name: 'Test Worker B' },
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
  apiMocks.link.mockResolvedValue({ manual_allocation: { last_sync_error: null } });
  apiMocks.retry.mockResolvedValue({});
  apiMocks.map.mockResolvedValue({});
});

afterEach(() => cleanup());

describe('AireManualHoursReview', () => {
  it('shows both identities before saving a permanent employee match', async () => {
    const user = userEvent.setup();
    apiMocks.manualReview.mockResolvedValue({
      ...review,
      employees: [{ ...review.employees[0], email: 'worker@aire.test', cornerstone: { status: 'unmapped', employee_id: null, employee_name: null } }],
    });
    render(<AireManualHoursReview
      payPeriodId={67}
      payPeriodStatus="draft"
      payrollHours={{}}
      employees={[{ id: 7, first_name: 'Test', last_name: 'Worker A', email: 'worker@payroll.test' } as import('@/types').Employee]}
      aireRecordLinked={false}
    />);

    await user.click(await screen.findByRole('button', { name: 'Match Test Worker A' }));
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByText('Person in AIRE')).toBeTruthy();
    expect(within(dialog).getByText('worker@aire.test')).toBeTruthy();
    expect(within(dialog).getByText(/AIRE ID: 282bf986/)).toBeTruthy();
    await user.selectOptions(within(dialog).getByRole('combobox', { name: 'Cornerstone employee' }), '7');
    expect(within(dialog).getByText(/worker@payroll.test/)).toBeTruthy();
    await user.click(within(dialog).getByRole('button', { name: 'Save match' }));
    await waitFor(() => expect(apiMocks.map).toHaveBeenCalledWith(67, { source_user_id: '91', employee_id: 7 }));
  });

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
    expect(screen.getByText('Test Worker B · 2.50 hrs')).toBeTruthy();
    expect(screen.getByText(/Commit payroll before linking manually entered AIRE hours/i)).toBeTruthy();
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

  it('separates payment-reported holds from verified paid hours', async () => {
    apiMocks.manualReview.mockResolvedValue({
      ...review,
      payment_attestations: [{
        id: '1', source_time_entry_id: '7001', source_user_uuid: review.employees[0].source_user_uuid,
        display_name: 'Casey Example', original_work_date: '2026-08-01', hours: 8,
        source_changed: false, cornerstone: { status: 'mapped', employee_id: 42, employee_name: 'Casey Example' },
      }],
    });
    render(<AireManualHoursReview payPeriodId={67} payPeriodStatus="draft" payrollHours={{}} aireRecordLinked={false} />);

    expect(await screen.findByText('Paid — owner attested; check details pending')).toBeTruthy();
    expect(screen.getByText('1 entry · 8.00 hours protected from repayment')).toBeTruthy();
    expect(screen.getByText(/recorded as paid from the owner statement/i)).toBeTruthy();
    expect(screen.getByText('Casey Example · 8.00 hrs')).toBeTruthy();
    expect(screen.getByText(/AIRE entry #7001/)).toBeTruthy();
    const attentionCard = screen.getByText('Needs attention').parentElement;
    expect(within(attentionCard as HTMLElement).getByText('2')).toBeTruthy();
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
    await screen.findByText(/Payment evidence updates the included AIRE hours/i);

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

  it('shows a recoverable error when AIRE returns an incomplete response', async () => {
    apiMocks.manualReview.mockResolvedValue({ data: [] });
    render(<AireManualHoursReview payPeriodId={67} payPeriodStatus="draft" payrollHours={{}} aireRecordLinked={false} />);

    expect(await screen.findByText('The manual check could not load.')).toBeTruthy();
    expect(screen.getByText(/AIRE returned an incomplete hours check/)).toBeTruthy();
  });

  it('links an exact carryover entry to a committed paycheck', async () => {
    const user = userEvent.setup();
    render(<AireManualHoursReview
      payPeriodId={67}
      payPeriodStatus="committed"
      payrollHours={{ '7': { regular: 27.2, overtime: 1 } }}
      payrollItems={[{ id: 200, employee_id: 7, hours_worked: 27.2, overtime_hours: 1, check_number: '01045', voided: false } as import('@/types').PayrollItem]}
      aireRecordLinked={false}
    />);

    expect(await screen.findAllByRole('button', { name: 'Link to paycheck' })).toHaveLength(2);
    await user.click(screen.getAllByRole('button', { name: 'Link to paycheck' })[1]);
    await user.click(screen.getByRole('button', { name: 'Confirm link' }));
    await waitFor(() => expect(apiMocks.link).toHaveBeenCalledWith(67, expect.objectContaining({
      payroll_item_id: 200,
      source_time_entry_id: '41',
      source_time_entry_version: 2,
      regular_hours: 6.1,
      overtime_hours: 0,
    })));
  });

  it('links direct-deposit hours while keeping them unpaid until bank evidence is recorded', async () => {
    const user = userEvent.setup();
    render(<AireManualHoursReview
      payPeriodId={67}
      payPeriodStatus="committed"
      payrollHours={{ '7': { regular: 27.2, overtime: 1 } }}
      payrollItems={[{ id: 200, employee_id: 7, hours_worked: 27.2, overtime_hours: 1,
        effective_payment_delivery_method: 'direct_deposit', voided: false } as import('@/types').PayrollItem]}
      aireRecordLinked={false}
    />);

    expect(await screen.findByText(/Linked hours become paid only after/)).toBeTruthy();
    const linkButtons = screen.getAllByRole('button', { name: 'Link to paycheck' });
    expect(linkButtons).toHaveLength(2);
    expect(linkButtons.every((button) => !button.hasAttribute('disabled'))).toBe(true);
    await user.click(linkButtons[0]);
    expect(screen.getByRole('option', { name: /Direct deposit/ })).toBeTruthy();
  });

  it('explains why an AIRE entry with missing identity cannot be linked', async () => {
    const user = userEvent.setup();
    apiMocks.manualReview.mockResolvedValue({
      ...review,
      employees: [{ ...review.employees[0], source_user_uuid: null }],
    });
    render(<AireManualHoursReview
      payPeriodId={67}
      payPeriodStatus="committed"
      payrollHours={{ '7': { regular: 27.2, overtime: 1 } }}
      payrollItems={[{ id: 200, employee_id: 7, hours_worked: 27.2, overtime_hours: 1, check_number: '01045', voided: false } as import('@/types').PayrollItem]}
      aireRecordLinked={false}
    />);

    await user.click((await screen.findAllByRole('button', { name: 'Link to paycheck' }))[0]);
    await user.click(screen.getByRole('button', { name: 'Confirm link' }));

    expect(screen.getByRole('alert').textContent).toContain('missing its permanent employee identity or version');
    expect(apiMocks.link).not.toHaveBeenCalled();
  });

  it('offers one confirmed action for multiple exact entries matching the remaining paycheck hours', async () => {
    const user = userEvent.setup();
    apiMocks.manualReview.mockResolvedValue({
      ...review,
      employees: [{
        ...review.employees[0], total_hours: 6.1, regular_hours: 6.1, overtime_hours: 0,
        adjustments: [
          { source_time_entry_id: '40', source_time_entry_version: 1, source_kind: 'current', original_work_date: '2026-08-11', category: { id: '2', name: 'Flight Hours' }, total_hours: 1, regular_hours: 1, overtime_hours: 0 },
          { source_time_entry_id: '41', source_time_entry_version: 2, source_kind: 'current', original_work_date: '2026-08-15', category: { id: '2', name: 'Flight Hours' }, total_hours: 5.1, regular_hours: 5.1, overtime_hours: 0 },
        ],
      }],
      summary: { ...review.summary, total_hours: 6.1, regular_hours: 6.1, overtime_hours: 0 },
    });
    render(<AireManualHoursReview
      payPeriodId={68}
      payPeriodStatus="committed"
      payrollHours={{ '7': { regular: 6.1, overtime: 0 } }}
      payrollItems={[{ id: 200, employee_id: 7, hours_worked: 6.1, overtime_hours: 0, check_number: '01045', voided: false } as import('@/types').PayrollItem]}
      aireRecordLinked={false}
    />);

    await user.click(await screen.findByRole('button', { name: 'Link 2 entries for Test Worker A' }));
    expect(screen.getByText(/does not mark them paid until check delivery/i)).toBeTruthy();
    await user.click(screen.getByRole('checkbox', { name: /checked the wage category, rate, and gross pay/i }));
    await user.click(screen.getByRole('button', { name: 'Confirm all links' }));
    await waitFor(() => expect(apiMocks.link).toHaveBeenCalledTimes(2));
    expect(apiMocks.link).toHaveBeenNthCalledWith(1, 68, expect.objectContaining({ source_time_entry_id: '40', regular_hours: 1 }));
    expect(apiMocks.link).toHaveBeenNthCalledWith(2, 68, expect.objectContaining({ source_time_entry_id: '41', regular_hours: 5.1 }));
  });

  it('links exact matches across multiple paychecks from one reviewed action', async () => {
    const user = userEvent.setup();
    const first = {
      ...review.employees[0], total_hours: 6, regular_hours: 6, overtime_hours: 0,
      adjustments: [
        { source_time_entry_id: '40', source_time_entry_version: 1, source_kind: 'current', original_work_date: '2026-08-11', category: { id: '2', name: 'Flight Hours' }, total_hours: 2, regular_hours: 2, overtime_hours: 0 },
        { source_time_entry_id: '41', source_time_entry_version: 2, source_kind: 'current', original_work_date: '2026-08-15', category: { id: '2', name: 'Flight Hours' }, total_hours: 4, regular_hours: 4, overtime_hours: 0 },
      ],
    };
    const second = {
      ...first, source_user_id: '92', source_user_uuid: '384bf986-dd27-46fa-bd70-65ebbc9d9cea',
      display_name: 'Test Worker B', cornerstone: { status: 'mapped', employee_id: 8, employee_name: 'Test Worker B' },
      adjustments: first.adjustments.map((entry, index) => ({ ...entry, source_time_entry_id: String(50 + index) })),
    };
    apiMocks.manualReview.mockResolvedValue({
      ...review, employees: [first, second],
      summary: { ...review.summary, employee_count: 2, adjustment_count: 4, total_hours: 12, regular_hours: 12, overtime_hours: 0 },
    });
    render(<AireManualHoursReview
      payPeriodId={68}
      payPeriodStatus="committed"
      payrollHours={{ '7': { regular: 6, overtime: 0 }, '8': { regular: 6, overtime: 0 } }}
      payrollItems={[
        { id: 200, employee_id: 7, hours_worked: 6, overtime_hours: 0, check_number: '01045', voided: false },
        { id: 201, employee_id: 8, hours_worked: 6, overtime_hours: 0, check_number: '01046', voided: false },
      ] as import('@/types').PayrollItem[]}
      aireRecordLinked={false}
    />);

    await user.click(await screen.findByRole('button', { name: 'Review and link 4 exact entries across 2 paychecks' }));
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByText(/Test Worker A · 2 entries/)).toBeTruthy();
    expect(within(dialog).getByText(/Test Worker B · 2 entries/)).toBeTruthy();
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(apiMocks.link).not.toHaveBeenCalled();
    await user.click(screen.getByRole('button', { name: 'Review and link 4 exact entries across 2 paychecks' }));
    const reopened = screen.getByRole('dialog');
    await user.click(within(reopened).getByRole('checkbox', { name: /checked the wage category, rate, and gross pay/i }));
    await user.click(within(reopened).getByRole('button', { name: 'Confirm all links' }));
    await waitFor(() => expect(apiMocks.link).toHaveBeenCalledTimes(4));
    expect(apiMocks.link).toHaveBeenNthCalledWith(3, 68, expect.objectContaining({ payroll_item_id: 201, source_time_entry_id: '50' }));
    expect((await screen.findByRole('status')).textContent).toContain('4 exact AIRE entries linked to 2 paychecks');

    await user.click(screen.getAllByRole('button', { name: 'Link to paycheck' })[0]);
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('offers a visible sync action when check delivery is recorded but AIRE has not confirmed payment', async () => {
    const user = userEvent.setup();
    apiMocks.manualReview.mockResolvedValue({
      ...review,
      cornerstone_manual_allocations: [{
        id: 15, payroll_item_id: 200, employee_id: 7, employee_name: 'Test Worker A',
        source_time_entry_id: '41', original_work_date: '2026-08-15',
        regular_hours: 6.1, overtime_hours: 0, status: 'committed',
        payroll_item_check_status: 'delivered', payment_method: 'paper_check',
      }],
    });
    render(<AireManualHoursReview payPeriodId={67} payPeriodStatus="committed" payrollHours={{}} aireRecordLinked={false} />);

    expect(await screen.findByText(/Check delivery is recorded in Cornerstone/)).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Sync now' }));
    await waitFor(() => expect(apiMocks.retry).toHaveBeenCalledWith(67, 15));
  });

  it('keeps committed but undelivered hours visible as payment not yet confirmed', async () => {
    apiMocks.manualReview.mockResolvedValue({
      ...review,
      employees: [],
      summary: { ...review.summary, total_hours: 0, regular_hours: 0, overtime_hours: 0 },
      manual_allocations: [{ id: '501', source_time_entry_id: '41', source_user_uuid: review.employees[0].source_user_uuid,
        display_name: 'Test Worker A', original_work_date: '2026-08-15', regular_hours: 6.1,
        overtime_hours: 0, status: 'committed', external_pay_period_id: '68', external_payroll_item_id: '200' }],
    });
    render(<AireManualHoursReview payPeriodId={68} payPeriodStatus="committed" payrollHours={{}} aireRecordLinked={false} />);

    const card = (await screen.findByText('Payment not yet confirmed')).parentElement;
    expect(within(card as HTMLElement).getByText('6.10 hrs')).toBeTruthy();
    expect(within(card as HTMLElement).getByText(/0.00 unlinked · 6.10 linked, awaiting payment evidence/)).toBeTruthy();
  });

  it('explains a historical regular/overtime difference without suggesting a second payment', async () => {
    apiMocks.manualReview.mockResolvedValue({
      ...review,
      historical_classification_reviews: [{
        id: 4, employee_id: 7, employee_name: 'Test Worker A', payroll_item_id: 200,
        source_entry_count: 5, source_regular_hours: 27.2, source_overtime_hours: 1,
        payroll_regular_hours: 28.2, payroll_overtime_hours: 0,
        gross_wage_difference: 5, check_number: '1062', payment_effective_on: '2026-09-15',
        status: 'complete', note: 'Historical classification difference',
      }],
    });
    render(<AireManualHoursReview payPeriodId={67} payPeriodStatus="committed" payrollHours={{}} aireRecordLinked={false} />);

    expect(await screen.findByText('Historical pay classification to review')).toBeTruthy();
    expect(screen.getByText('Test Worker A · check #1062')).toBeTruthy();
    expect(screen.getByText('Hours marked paid')).toBeTruthy();
    expect(screen.getByText('Historical classification difference')).toBeTruthy();
    expect(screen.getByText(/For review only; not automatically paid or deducted/)).toBeTruthy();
    expect(within(screen.getByText('Needs attention').parentElement as HTMLElement).getByText('2')).toBeTruthy();
  });

  it('does not offer a new paycheck link for offsetting classification corrections', async () => {
    apiMocks.manualReview.mockResolvedValue({
      ...review,
      employees: [{ ...review.employees[0], regular_hours: -0.1, overtime_hours: 0.1, total_hours: 0,
        adjustments: [{ ...review.employees[0].adjustments[0], source_kind: 'correction', total_hours: 0, regular_hours: -0.1, overtime_hours: 0.1 }] }],
      exclusions: [],
      summary: { ...review.summary, total_hours: 0, regular_hours: -0.1, overtime_hours: 0.1, correction_count: 1, exclusion_count: 0 },
    });
    render(<AireManualHoursReview payPeriodId={67} payPeriodStatus="committed" payrollHours={{}} aireRecordLinked={false} />);

    expect(await screen.findByText(/No additional total hours. Review the regular\/OT reclassification/)).toBeTruthy();
    expect(screen.getByText(/Offsetting correction; review the category or OT split/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Link to paycheck' })).toBeNull();
  });

  it('retries multiple failed AIRE links from one review action', async () => {
    const user = userEvent.setup();
    apiMocks.retry.mockResolvedValue({ manual_allocation: { last_sync_error: null } });
    apiMocks.manualReview.mockResolvedValue({
      ...review,
      cornerstone_manual_allocations: [41, 42].map((id) => ({
        id, payroll_item_id: 200, employee_id: 7, employee_name: 'Test Worker A',
        source_time_entry_id: String(id), original_work_date: '2026-08-15',
        regular_hours: 1, overtime_hours: 0, status: 'pending_commit',
        payroll_item_check_status: 'printed', payment_method: 'paper_check',
        last_sync_error: 'AIRE connection unavailable',
      })),
    });
    render(<AireManualHoursReview payPeriodId={68} payPeriodStatus="committed" payrollHours={{}} aireRecordLinked={false} />);

    await user.click(await screen.findByRole('button', { name: 'Sync all 2 pending AIRE updates' }));
    await waitFor(() => expect(apiMocks.retry).toHaveBeenCalledTimes(2));
    expect(apiMocks.retry).toHaveBeenNthCalledWith(1, 68, 41);
    expect(apiMocks.retry).toHaveBeenNthCalledWith(2, 68, 42);
  });
});
