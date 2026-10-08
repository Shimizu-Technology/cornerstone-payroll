// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useState } from 'react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type {
  AirePayrollCalendarState,
  AirePayrollCockpitOverview,
  AirePayrollExceptionsResponse,
  AirePayrollSettlementCasesResponse,
  AirePayrollTimeEntriesResponse,
} from '@/types';
import { AirePayrollCockpit } from './AirePayrollCockpit';
import { AireManualPaymentReconciliation } from './AireManualPaymentReconciliation';

const apiMocks = vi.hoisted(() => ({
  overview: vi.fn(),
  manualReview: vi.fn(),
  entries: vi.fn(),
  exceptions: vi.fn(),
  settlements: vi.fn(),
  review: vi.fn(),
  reviewOvertime: vi.fn(),
  correct: vi.fn(),
  routeSettlement: vi.fn(),
  finalize: vi.fn(),
  publish: vi.fn(),
  retry: vi.fn(),
  confirmEmployeeMapping: vi.fn(),
}));

const routerMocks = vi.hoisted(() => ({
  locationState: null as { aireMappingNotice?: string } | null,
  navigate: vi.fn(),
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ isManager: true, hasCapability: () => true }),
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompanyId: 1 }),
}));

vi.mock('react-router', async () => {
  const actual = await vi.importActual<typeof import('react-router')>('react-router');
  return {
    ...actual,
    useLocation: () => ({ pathname: '/companies/1/pay-periods/17', search: '', hash: '', state: routerMocks.locationState, key: 'test' }),
    useNavigate: () => routerMocks.navigate,
  };
});

vi.mock('@/services/api', () => ({
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
  payPeriodsApi: {
    airePayrollCockpit: apiMocks.overview,
    airePayrollManualReview: apiMocks.manualReview,
    airePayrollTimeEntries: apiMocks.entries,
    airePayrollExceptions: apiMocks.exceptions,
    airePayrollSettlementCases: apiMocks.settlements,
    reviewAireTimeEntry: apiMocks.review,
    reviewAireOvertime: apiMocks.reviewOvertime,
    correctAireTimeEntry: apiMocks.correct,
    routeAireSettlementCase: apiMocks.routeSettlement,
    finalizeAirePayrollPeriod: apiMocks.finalize,
    publishAireCalendar: apiMocks.publish,
    retryAireCalendarDelivery: apiMocks.retry,
    confirmAireEmployeeMapping: apiMocks.confirmEmployeeMapping,
  },
}));

const calendar: AirePayrollCalendarState = {
  enabled: true,
  source_id: 1,
  source_name: 'time tracking Services',
  eligible: true,
  external_pay_period_id: '068f6f66-3b03-4ad0-9c90-042e408dac68',
  cutoff_at: '2026-10-18T17:00:00+10:00',
  cutoff_state: 'scheduled',
  needs_revision: false,
  can_publish: false,
  can_retry: false,
  publication: {
    id: 1,
    schedule_version: 1,
    publication_id: 'bd433326-9f2e-4bb2-a04b-9ab797720755',
    delivery_status: 'delivered',
    delivery_attempts: 1,
  },
};

const period = {
  external_pay_period_id: calendar.external_pay_period_id!,
  start_date: '2026-10-01',
  end_date: '2026-10-15',
  pay_date: '2026-10-25',
  cutoff_at: calendar.cutoff_at!,
  time_zone: 'Pacific/Guam',
  cutoff_days_before: 7,
  version: 2,
  schedule_version: 1,
  publication_id: 'bd433326-9f2e-4bb2-a04b-9ab797720755',
  status: 'scheduled' as const,
  cutoff_state: 'due' as const,
};

const timeEntry = {
  id: '42',
  version: 3,
  work_date: '2026-10-14',
  start_time: '08:04 AM',
  end_time: '05:09 PM',
  hours: 8.08,
  break_minutes: 60,
  breaks: [{ id: '9', start_time: '2026-10-14T02:00:00Z', end_time: '2026-10-14T03:00:00Z', duration_minutes: 60, active: false }],
  category: { id: '2', key: 'regular', name: 'Regular' },
  available_time_categories: [
    { id: '3', key: 'admin', name: 'Admin duties' },
    { id: '2', key: 'regular', name: 'Regular' },
  ],
  capture: { entry_method: 'manual', clock_source: null, ordinary: false, admin_override: true },
  state: {
    status: 'completed',
    missing_punch: false,
    approval_status: 'pending',
    overtime_status: 'none',
    payable_now: false,
    payroll_disposition: 'pending_approval',
    payroll_exclusion_reasons: ['pending_approval'],
    included_hours: 0,
  },
  employee: {
    id: '91',
    payroll_integration_id: '282bf986-dd27-46fa-bd70-65ebbc9d9cea',
    name: 'Malia Cruz',
    cornerstone: { status: 'mapped' as const, employee_id: 7, employee_name: 'Malia Cruz' },
  },
  lifecycle: { status: 'awaiting_approval', label: 'Awaiting approval' },
};

function fixtures(canCommand = true) {
  const overview: AirePayrollCockpitOverview = {
    payroll_period: period,
    readiness: {
      total_entries: 2,
      total_hours: 16.08,
      eligible_entries: 1,
      eligible_hours: 8,
      held_entries: 1,
      held_hours: 8.08,
      pending_approvals: 1,
      denied_entries: 0,
      missing_punches: 0,
      pending_overtime: 0,
      lifecycle_counts: { ready_for_cutoff: 1, awaiting_approval: 1 },
    },
    finalized_batch: null,
    processing_history: [],
    carryovers: { awaiting_approval_count: 0 },
    employees: [{
      id: '91',
      payroll_integration_id: timeEntry.employee.payroll_integration_id,
      full_name: 'Malia Cruz',
      email: 'malia@example.com',
      active: true,
      time_tracking_enabled: true,
      cornerstone: timeEntry.employee.cornerstone,
    }],
    employee_pagination: { current_page: 1, per_page: 100, total_count: 1, total_pages: 1, truncated: false },
    payroll_employee_options: [],
    command_access: { can_read: true, can_command: canCommand, can_manage_mappings: true, delegation_configured: canCommand },
    routing_options: [{
      external_pay_period_id: 'cb55b145-0dbc-4211-96d3-eb63fa7c5278',
      pay_period_id: 18,
      start_date: '2026-10-16',
      end_date: '2026-10-31',
      pay_date: '2026-11-10',
    }],
  };
  const entries: AirePayrollTimeEntriesResponse = {
    payroll_period: period,
    time_entries: [timeEntry],
    pagination: { current_page: 1, per_page: 250, total_count: 1, total_pages: 1, truncated: false },
  };
  const exceptions: AirePayrollExceptionsResponse = {
    payroll_period: period,
    time_exceptions: [timeEntry],
    time_exception_pagination: { current_page: 1, per_page: 250, total_count: 1, total_pages: 1, truncated: false },
    leave_exceptions: [],
    leave_exception_pagination: { current_page: 1, per_page: 100, total_count: 0, total_pages: 1, truncated: false },
    carryovers: { items: [], summary: {}, truncated: false },
  };
  const settlements: AirePayrollSettlementCasesResponse = {
    settlement_cases: [{
      id: '9a708e48-f04e-47e8-8e0c-7b727def25d4',
      version: 2,
      source_time_entry_version: 3,
      status: 'open',
      source_time_entry_id: '42',
      employee: { ...timeEntry.employee, email: 'malia@example.com' },
      time: {
        original_work_date: '2026-10-14',
        held_total_hours: 8.08,
        current_total_hours: 8.18,
        category: timeEntry.category,
        approval_status: 'pending',
        entry_status: 'completed',
      },
      origin: {
        reason: 'pending_approval',
        payroll_batch_id: 'time tracking-PAY-ORIGIN',
        payroll_period_id: calendar.external_pay_period_id,
        excluded_at: calendar.cutoff_at!,
      },
      routing: {
        destination_kind: 'unassigned',
        owner_role: 'aire_admins',
        action_due_on: '2026-10-25',
      },
      processing: null,
      events: [],
    }],
    pagination: { current_page: 1, per_page: 250, total_count: 1, total_pages: 1, truncated: false },
    summary: { open: 1, scheduled: 0, in_payroll: 0, settled: 0, attention_due: 1 },
  };
  return { overview, entries, exceptions, settlements };
}

function mockLoads(canCommand = true) {
  const data = fixtures(canCommand);
  apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });
  apiMocks.entries.mockResolvedValue(data.entries);
  apiMocks.exceptions.mockResolvedValue(data.exceptions);
  apiMocks.settlements.mockResolvedValue(data.settlements);
  apiMocks.manualReview.mockResolvedValue({
    start_date: period.start_date,
    end_date: period.end_date,
    generated_at: period.cutoff_at,
    employees: [],
    exclusions: [],
    issues: {
      missing_category_count: 0,
      negative_adjustment_count: 0,
      pending_approval_count: 0,
      denied_approval_count: 0,
      open_clock_count: 0,
      pending_overtime_count: 0,
      denied_overtime_count: 0,
    },
    summary: {
      employee_count: 0,
      adjustment_count: 0,
      total_hours: 0,
      regular_hours: 0,
      overtime_hours: 0,
      current_count: 0,
      carryover_count: 0,
      correction_count: 0,
      exclusion_count: 0,
    },
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  routerMocks.locationState = null;
  mockLoads();
  apiMocks.review.mockResolvedValue({ time_entry: { ...timeEntry, state: { ...timeEntry.state, approval_status: 'approved', payable_now: true } } });
  apiMocks.reviewOvertime.mockResolvedValue({ time_entry: { ...timeEntry, state: { ...timeEntry.state, overtime_status: 'approved', payable_now: true } } });
  apiMocks.correct.mockResolvedValue({ time_entry: { ...timeEntry, version: 4 } });
  apiMocks.routeSettlement.mockResolvedValue({ settlement_case: { ...fixtures().settlements.settlement_cases[0], status: 'scheduled', version: 3 } });
  apiMocks.finalize.mockResolvedValue({ result: { status: 'finalized', payroll_batch_id: 'time tracking-PAY-1' } });
  apiMocks.confirmEmployeeMapping.mockResolvedValue({
    employee_mapping: {
      source_user_id: '91',
      source_user_uuid: timeEntry.employee.payroll_integration_id,
      employee_id: 7,
      employee_name: 'Malia Cruz',
      status: 'mapped',
    },
  });
});

afterEach(() => cleanup());

describe('AirePayrollCockpit', () => {
  it('replaces the live preview with the verified batch action', async () => {
    const user = userEvent.setup();
    const onReviewFinalizedBatch = vi.fn();
    const verifiedCalendar: AirePayrollCalendarState = {
      ...calendar,
      cutoff_state: 'batch_verified',
      finalized_batch: {
        event_id: 'event-17',
        verification_status: 'verified',
        verification_attempts: 1,
        occurred_at: '2026-10-23T00:01:00+10:00',
        verified_at: '2026-10-23T00:01:10+10:00',
        payroll_batch_id: 'time tracking-PAY-17',
        payroll_batch_checksum: 'checksum',
        summary: {
          employee_count: 4,
          total_hours: 72.5,
          regular_hours: 68.5,
          overtime_hours: 4,
          exclusion_count: 2,
        },
      },
    };

    render(
      <AirePayrollCockpit
        payPeriodId={17}
        calendar={verifiedCalendar}
        onRefresh={vi.fn()}
        onReviewFinalizedBatch={onReviewFinalizedBatch}
      />
    );

    expect(await screen.findByText('Time tracking hours are ready to add')).toBeTruthy();
    expect(screen.queryByText('Live time tracking readiness')).toBeNull();
    await user.click(screen.getByRole('button', { name: 'Review and add time tracking hours' }));
    expect(onReviewFinalizedBatch).toHaveBeenCalledOnce();
    expect(apiMocks.manualReview).not.toHaveBeenCalled();
  });

  it('shows exact time tracking time, readiness, and mapping in one payroll workspace', async () => {
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);

    expect(await screen.findByText('Time tracking payroll workspace')).toBeTruthy();
    expect(screen.getByText('16.08 hrs')).toBeTruthy();
    expect(screen.getAllByText('8.08 hrs').length).toBe(2);
    expect(screen.getByText('08:04 AM – 05:09 PM')).toBeTruthy();
    expect(screen.getAllByText('Mapped').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Awaiting approval').length).toBeGreaterThan(0);
    expect(apiMocks.entries).toHaveBeenCalledWith(17, { page: 1 });
  });

  it('shows exact paid hours and batch events in a clear payment history', async () => {
    const user = userEvent.setup();
    const data = fixtures();
    data.overview.entry_processing_history = [
      {
        event_id: 'check-5001-line-1',
        status: 'payment_issued',
        occurred_at: '2026-10-23T00:01:00+10:00',
        source_time_entry_id: '42',
        total_hours: '8.00',
        payment_method: 'paper_check',
        payment_reference: '5001',
      },
      {
        event_id: 'check-5001-line-2',
        status: 'payment_issued',
        occurred_at: '2026-10-23T00:01:00+10:00',
        source_time_entry_id: '43',
        total_hours: '2.00',
        payment_method: 'paper_check',
        payment_reference: '5001',
      },
      {
        event_id: 'deposit-ach-77-line-1',
        status: 'payment_issued',
        occurred_at: '2026-10-22T15:05:00Z',
        source_time_entry_id: '44',
        total_hours: 'not-a-number',
        payment_reference: 'ACH-77',
      },
    ];
    data.overview.processing_history = [
      {
        event_id: 'batch-imported',
        status: 'imported',
        occurred_at: '2026-10-22T10:00:00Z',
        external_system: 'cornerstone_payroll',
      },
      {
        event_id: 'batch-committed',
        status: 'committed',
        occurred_at: '2026-10-22T18:00:00+10:00',
        external_system: 'cornerstone_payroll',
      },
    ];
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });

    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Time tracking payroll workspace');
    await user.click(screen.getByRole('button', { name: /Payment history 4/i }));

    const paymentSection = screen.getByRole('heading', { name: 'Hour and payment status' }).closest('section');
    expect(paymentSection).toBeTruthy();
    expect(within(paymentSection!).getAllByText('Check issued or deposit settled')).toHaveLength(2);
    expect(within(paymentSection!).getAllByText(/hrs across/)[0].textContent).toContain('0.00 hrs across 1 timecard line · Reference ACH-77');
    expect(screen.getByText('10.00 hrs across 2 timecard lines · Check 5001')).toBeTruthy();
    const batchSection = screen.getByRole('heading', { name: 'Batch history' }).closest('section');
    expect(batchSection).toBeTruthy();
    expect(within(batchSection!).getAllByText(/^(imported|committed)$/)[0].textContent).toBe('imported');
  });

  it('explains when no payment history exists yet', async () => {
    const user = userEvent.setup();
    const data = fixtures();
    data.overview.entry_processing_history = [];
    data.overview.processing_history = [];
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });

    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Time tracking payroll workspace');
    await user.click(screen.getByRole('button', { name: /Payment history 0/i }));

    expect(screen.getByText('Payment history will appear after the source’s hours are added to payroll.')).toBeTruthy();
  });

  it('shows an identity suggestion without auto-linking and saves only an explicit confirmation', async () => {
    const user = userEvent.setup();
    const onSourceChanged = vi.fn();
    const data = fixtures();
    data.overview.employees[0] = {
      ...data.overview.employees[0],
      cornerstone: {
        status: 'unmapped',
        employee_id: undefined,
        employee_name: undefined,
        suggestions: [{ employee_id: 7, employee_name: 'Malia Cruz', email: 'malia@example.com', basis: 'same_email_and_name' }],
      },
    };
    data.overview.payroll_employee_options = [{ employee_id: 7, employee_name: 'Malia Cruz', email: 'malia@example.com', employment_type: 'hourly' }];
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });

    render(
      <MemoryRouter>
        <AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} onSourceChanged={onSourceChanged} />
      </MemoryRouter>
    );
    await screen.findByText('Time tracking payroll workspace');
    await user.click(screen.getByRole('button', { name: /Team 1/i }));

    expect(screen.getByText('Not mapped')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Link payroll employee' }));
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByText(/Suggested:/)).toBeTruthy();
    expect((within(dialog).getByLabelText('Payroll employee') as HTMLSelectElement).value).toBe('7');

    await user.click(within(dialog).getByRole('button', { name: 'Confirm link' }));

    await waitFor(() => expect(apiMocks.confirmEmployeeMapping).toHaveBeenCalledWith(17, {
      source_user_id: '91',
      source_user_uuid: timeEntry.employee.payroll_integration_id,
      employee_id: 7,
    }));
    await waitFor(() => expect(onSourceChanged).toHaveBeenCalledOnce());
  });

  it('shows a payroll profile mapping failure after returning to the time tracking workspace', async () => {
    routerMocks.locationState = {
      aireMappingNotice: 'The payroll profile was created, but time tracking could not be linked. Link the new employee from the payroll team list.',
    };

    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);

    expect((await screen.findByRole('alert')).textContent).toContain('The payroll profile was created, but time tracking could not be linked.');
    expect(routerMocks.navigate).toHaveBeenCalledWith('/companies/1/pay-periods/17', { replace: true, state: null });
  });

  it('requires the operator to explain an approval and sends the source version', async () => {
    const user = userEvent.setup();
    const onSourceChanged = vi.fn();
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} onSourceChanged={onSourceChanged} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: 'Approve time' }));
    const submit = within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }) as HTMLButtonElement;
    expect(submit.disabled).toBe(true);
    // JSDOM has no layout; let the dialog finish its initial focus frame
    // before user-event focuses and types into the reason field.
    await act(async () => { await new Promise<void>((resolve) => requestAnimationFrame(() => resolve())); });
    await user.type(screen.getByRole('textbox', { name: /reason/i }), 'Verified against manager note');
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }));

    await waitFor(() => expect(apiMocks.review).toHaveBeenCalledWith(17, '42', expect.objectContaining({
      expected_version: 3,
      decision: 'approve',
      reason: 'Verified against manager note',
      command_id: expect.any(String),
    })));
    await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(onSourceChanged).toHaveBeenCalledOnce());
  });

  it('shows the payment hold when historical payment confirmation is pending', async () => {
    const data = fixtures();
    data.entries.time_entries = [{ ...timeEntry, state: { ...timeEntry.state,
      approval_status: 'approved', overtime_status: 'not_required', payable_now: false,
      payroll_disposition: 'pending_payment_attestation',
      payroll_exclusion_reasons: ['pending_payment_attestation'],
    } }];
    apiMocks.entries.mockResolvedValue(data.entries);
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    expect(await screen.findByText('Payment confirmation needed')).toBeTruthy();
  });

  it('reviews ordinary clock-entry overtime in time tracking without requiring a base-time approval', async () => {
    const user = userEvent.setup();
    const onSourceChanged = vi.fn();
    const data = fixtures();
    const overtimeEntry = {
      ...timeEntry,
      description: 'Customer installation',
      capture: { entry_method: 'clock', clock_source: 'kiosk', ordinary: true, admin_override: false },
      state: {
        ...timeEntry.state,
        approval_status: 'not_required',
        overtime_status: 'pending',
        payroll_disposition: 'pending_overtime',
        payroll_exclusion_reasons: ['pending_overtime'],
      },
    };
    data.overview.readiness.pending_approvals = 0;
    data.overview.readiness.pending_overtime = 1;
    data.entries.time_entries = [overtimeEntry];
    data.exceptions.time_exceptions = [overtimeEntry];
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });
    apiMocks.entries.mockResolvedValue(data.entries);
    apiMocks.exceptions.mockResolvedValue(data.exceptions);

    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} onSourceChanged={onSourceChanged} />);
    await screen.findByText('Overtime approval needed');

    expect(screen.getByText('60 min break · clock entry via kiosk')).toBeTruthy();
    expect(screen.getByText('Customer installation')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Approve time' })).toBeNull();
    await user.click(screen.getByRole('button', { name: 'Approve overtime' }));
    expect(screen.getByText(/Cornerstone will still calculate the legally required regular and overtime split/i)).toBeTruthy();
    fireEvent.change(screen.getByRole('textbox', { name: /reason/i }), {
      target: { value: 'Confirmed scheduled overtime' },
    });
    await waitFor(() => expect((within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve overtime' }) as HTMLButtonElement).disabled).toBe(false));
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve overtime' }));

    await waitFor(() => expect(apiMocks.reviewOvertime).toHaveBeenCalledWith(17, '42', expect.objectContaining({
      expected_version: 3,
      decision: 'approve',
      reason: 'Confirmed scheduled overtime',
      command_id: expect.any(String),
    })));
    expect(apiMocks.review).not.toHaveBeenCalled();
    expect(await screen.findByText('Overtime approved in time tracking and saved in both audit histories.')).toBeTruthy();
    await waitFor(() => expect(onSourceChanged).toHaveBeenCalledOnce());
  });

  it('shows who approved time and overtime, when, and why', async () => {
    const data = fixtures();
    const reviewedEntry = {
      ...timeEntry,
      capture: { entry_method: 'clock', clock_source: 'mobile', ordinary: true, admin_override: false },
      state: { ...timeEntry.state, approval_status: 'approved', overtime_status: 'approved', payable_now: true },
      approval: { actor: { name: 'time tracking Admin' }, occurred_at: '2026-10-15T08:00:00+10:00', note: 'Matched the schedule' },
      overtime_approval: { actor: { name: 'Chels Shimizu' }, occurred_at: '2026-10-15T08:05:00+10:00', note: 'Authorized overtime' },
    };
    data.entries.time_entries = [reviewedEntry];
    apiMocks.entries.mockResolvedValue(data.entries);

    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);

    expect(await screen.findByText(/Time approved by time tracking Admin/)).toBeTruthy();
    expect(screen.getByText(/Oct 15, 2026, 8:00:00 AM/)).toBeTruthy();
    expect(screen.getByText(/Matched the schedule/)).toBeTruthy();
    expect(screen.getByText(/Overtime approved by Chels Shimizu/)).toBeTruthy();
    expect(screen.getByText(/Oct 15, 2026, 8:05:00 AM/)).toBeTruthy();
    expect(screen.getByText(/Authorized overtime/)).toBeTruthy();
  });

  it('corrects a manual timecard in time tracking and makes the new approval requirement explicit', async () => {
    const user = userEvent.setup();
    const onSourceChanged = vi.fn();
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} onSourceChanged={onSourceChanged} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: 'Correct' }));
    expect((screen.getByLabelText('Start time') as HTMLInputElement).value).toBe('08:04');
    expect((screen.getByLabelText('End time') as HTMLInputElement).value).toBe('17:09');
    expect((screen.getByLabelText('Break 1 start') as HTMLInputElement).value).toBe('12:00');
    expect((screen.getByLabelText('Break 1 end') as HTMLInputElement).value).toBe('13:00');
    await user.clear(screen.getByLabelText('End time'));
    fireEvent.change(screen.getByLabelText('End time'), { target: { value: '17:15' } });
    await user.type(screen.getByLabelText('Correction reason'), 'Employee confirmed the missed punch');
    await user.click(screen.getByRole('button', { name: 'Save correction' }));

    await waitFor(() => expect(apiMocks.correct).toHaveBeenCalledWith(17, '42', expect.objectContaining({
      expected_version: 3,
      reason: 'Employee confirmed the missed punch',
      work_date: '2026-10-14',
      start_time: '08:04',
      end_time: '17:15',
      time_category_id: '2',
      breaks: [{ start_time: '12:00', end_time: '13:00' }],
      command_id: expect.any(String),
    })));
    expect(await screen.findByText(/now needs administrator approval/i)).toBeTruthy();
    await waitFor(() => expect(onSourceChanged).toHaveBeenCalledOnce());
  });

  it('uses categories carried by the time entry when its employee is outside the current team page', async () => {
    const user = userEvent.setup();
    const data = fixtures();
    data.overview.employees = [];
    data.overview.employee_pagination = {
      current_page: 1,
      per_page: 100,
      total_count: 101,
      total_pages: 2,
      truncated: false,
    };
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });

    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: 'Correct' }));
    const category = screen.getByLabelText('Time category') as HTMLSelectElement;
    expect(Array.from(category.options, (option) => option.textContent)).toEqual([
      'Choose category',
      'Admin duties',
      'Regular',
    ]);
    expect(category.value).toBe('2');
    expect((screen.getByRole('button', { name: 'Save correction' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('preserves legacy aggregate break minutes when exact break times are unavailable', async () => {
    const user = userEvent.setup();
    apiMocks.entries.mockResolvedValueOnce({
      ...fixtures().entries,
      time_entries: [{
        ...timeEntry,
        breaks: [],
        state: { ...timeEntry.state, approval_status: 'approved', overtime_status: 'pending' },
      }],
    });
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');
    expect(screen.getByText('Overtime approval needed')).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Correct' }));
    expect(screen.getByText(/time tracking has 60 total break minutes but no exact break times/i)).toBeTruthy();
    fireEvent.change(screen.getByLabelText('Correction reason'), { target: { value: 'Correcting the description only' } });
    const save = screen.getByRole('button', { name: 'Save correction' }) as HTMLButtonElement;
    expect(save.disabled).toBe(false);
    await user.click(save);

    await waitFor(() => expect(apiMocks.correct).toHaveBeenCalled());
    const payload = apiMocks.correct.mock.calls[0]?.[2];
    expect(payload).not.toHaveProperty('breaks');
  });

  it('shows the held-time evidence and routes it to a published future payroll', async () => {
    const user = userEvent.setup();
    const onSourceChanged = vi.fn();
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} onSourceChanged={onSourceChanged} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: /Held time 1/i }));
    expect(screen.getByText('8.08 held hours')).toBeTruthy();
    expect(screen.getByText(/Current corrected time is 8.18 hours/i)).toBeTruthy();
    expect(screen.getByText(/No payment has been recorded/)).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Choose destination' }));
    expect(screen.getByText(/8.18 current corrected hours \(originally held 8.08\)/i)).toBeTruthy();
    expect((screen.getByLabelText('Regular payroll') as HTMLSelectElement).value).toBe('cb55b145-0dbc-4211-96d3-eb63fa7c5278');
    fireEvent.change(screen.getByLabelText('Routing reason'), { target: { value: 'Pay in the next available regular payroll' } });
    const submit = screen.getByRole('button', { name: 'Route to payroll' }) as HTMLButtonElement;
    await waitFor(() => expect(submit.disabled).toBe(false));
    await user.click(submit);

    await waitFor(() => expect(apiMocks.routeSettlement).toHaveBeenCalledWith(
      17,
      '9a708e48-f04e-47e8-8e0c-7b727def25d4',
      expect.objectContaining({
        expected_version: 2,
        destination_kind: 'regular',
        target_external_pay_period_id: 'cb55b145-0dbc-4211-96d3-eb63fa7c5278',
        reason: 'Pay in the next available regular payroll',
      })
    ));
    await waitFor(() => expect(onSourceChanged).toHaveBeenCalledOnce());
  });

  it('requires an explicit reason before marking held hours not payable', async () => {
    const user = userEvent.setup();
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: /Held time 1/i }));
    await user.click(screen.getByRole('button', { name: 'Choose destination' }));
    await user.click(screen.getByRole('radio', { name: /Mark not payable/i }));
    const submit = screen.getByRole('button', { name: 'Mark not payable' }) as HTMLButtonElement;
    expect(submit.disabled).toBe(true);
    await user.type(screen.getByLabelText('Routing reason'), 'Confirmed duplicate time entry');
    await user.click(submit);

    await waitFor(() => expect(apiMocks.routeSettlement).toHaveBeenCalledWith(
      17,
      '9a708e48-f04e-47e8-8e0c-7b727def25d4',
      expect.objectContaining({
        destination_kind: 'not_payable',
        reason: 'Confirmed duplicate time entry',
      })
    ));
    expect(apiMocks.routeSettlement.mock.calls[0][2]).not.toHaveProperty('target_external_pay_period_id');
  });

  it('keeps the workspace readable but disables commands without a time tracking account connection', async () => {
    mockLoads(false);
    render(
      <MemoryRouter>
        <AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />
      </MemoryRouter>
    );
    await screen.findByText(/actions need your time tracking access/i);

    expect((screen.getByRole('button', { name: 'Approve time' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: /lock time tracking cutoff/i }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByRole('link', { name: /connect my time tracking account/i }).getAttribute('href'))
      .toBe('/app/aire-account-connection?source_id=1&return_to=%2Fcompanies%2F1%2Fpay-periods%2F17');
  });

  it('does not let an older refresh overwrite a newer payroll view', async () => {
    const stale = fixtures();
    const current = fixtures();
    current.overview.employees[0] = { ...current.overview.employees[0], full_name: 'Current Employee' };
    current.entries.time_entries[0] = {
      ...current.entries.time_entries[0],
      employee: { ...current.entries.time_entries[0].employee, name: 'Current Employee' },
    };
    let releaseStale: (() => void) | undefined;
    const staleGate = new Promise<void>((resolve) => { releaseStale = resolve; });
    apiMocks.overview
      .mockImplementationOnce(async () => { await staleGate; return { aire_payroll_cockpit: stale.overview }; })
      .mockResolvedValue({ aire_payroll_cockpit: current.overview });
    apiMocks.entries
      .mockImplementationOnce(async () => { await staleGate; return stale.entries; })
      .mockResolvedValue(current.entries);
    apiMocks.exceptions
      .mockImplementationOnce(async () => { await staleGate; return stale.exceptions; })
      .mockResolvedValue(current.exceptions);
    apiMocks.settlements
      .mockImplementationOnce(async () => { await staleGate; return stale.settlements; })
      .mockResolvedValue(current.settlements);

    const view = render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(1));
    view.rerender(<AirePayrollCockpit payPeriodId={18} calendar={calendar} onRefresh={vi.fn()} />);
    expect(await screen.findByText('Current Employee')).toBeTruthy();

    await act(async () => { releaseStale?.(); });
    await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(2));
    expect(screen.getByText('Current Employee')).toBeTruthy();
    expect(screen.queryByText('Malia Cruz')).toBeNull();
  });

  it('closes commands from the prior payroll when the operator navigates to another period', async () => {
    const user = userEvent.setup();
    const view = render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');
    await user.click(screen.getByRole('button', { name: 'Correct' }));
    expect(screen.getByRole('heading', { name: 'Correct time in time tracking' })).toBeTruthy();

    view.rerender(<AirePayrollCockpit payPeriodId={18} calendar={calendar} onRefresh={vi.fn()} />);

    await waitFor(() => expect(screen.queryByRole('heading', { name: 'Correct time in time tracking' })).toBeNull());
    expect(apiMocks.correct).not.toHaveBeenCalled();
  });

  it('locks a due period only after confirmation and refreshes both systems', async () => {
    const user = userEvent.setup();
    const onRefresh = vi.fn().mockResolvedValue(undefined);
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={onRefresh} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: /lock time tracking cutoff/i }));
    await user.click(screen.getByRole('button', { name: /lock eligible time/i }));

    await waitFor(() => expect(apiMocks.finalize).toHaveBeenCalledWith(17, expect.objectContaining({
      expected_version: 2,
      reason: 'Reviewed time tracking readiness and confirmed eligible time for cutoff',
      command_id: expect.any(String),
    })));
    await waitFor(() => expect(onRefresh).toHaveBeenCalledOnce());
  });

  it('keeps a command failure visible after reloading the latest time tracking details', async () => {
    const user = userEvent.setup();
    apiMocks.review.mockRejectedValueOnce(new Error('time tracking could not record this approval'));
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: 'Approve time' }));
    const submit = within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }) as HTMLButtonElement;
    fireEvent.change(screen.getByRole('textbox', { name: /reason/i }), {
      target: { value: 'Verified against manager note' },
    });
    await waitFor(() => expect(submit.disabled).toBe(false));
    await user.click(submit);

    await waitFor(() => expect(apiMocks.review).toHaveBeenCalledOnce());
    await waitFor(() => expect(document.body.textContent).toContain('time tracking could not record this approval'));
    expect(screen.getAllByRole('alert', { hidden: true }).some((alert) => (
      alert.textContent?.includes('time tracking could not record this approval')
    ))).toBe(true);
    await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(2));

    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }));
    await waitFor(() => expect(apiMocks.review).toHaveBeenCalledTimes(2));
    expect(apiMocks.review.mock.calls[1][2].command_id).toBe(apiMocks.review.mock.calls[0][2].command_id);
  });

  it('reports a post-lock Cornerstone refresh failure separately from the successful time tracking command', async () => {
    const user = userEvent.setup();
    const onRefresh = vi.fn().mockRejectedValue(new Error('pay period reload failed'));
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={onRefresh} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: /lock time tracking cutoff/i }));
    await user.click(screen.getByRole('button', { name: /lock eligible time/i }));

    expect((await screen.findByRole('alert')).textContent).toContain(
      'Time tracking was locked, but Cornerstone could not refresh: pay period reload failed'
    );
    expect(apiMocks.finalize).toHaveBeenCalledOnce();
  });
});


it('updates the live manual readiness and reconciliation exclusions after approving source time', async () => {
  const user = userEvent.setup();
  const data = fixtures();
  let manual = {
    start_date: period.start_date, end_date: period.end_date, generated_at: period.cutoff_at,
    employees: [], command_access: { can_manage_manual_allocations: true },
    exclusions: ['42', '99'].map(id => ({ source_time_entry_id: id, source_user_id: '91', display_name: 'Malia Cruz', original_work_date: '2026-10-10', reason: 'pending_approval', held_total_hours: id === '42' ? 6 : 4, cornerstone: { status: 'mapped', employee_id: 7, employee_name: 'Malia Cruz' } })),
    issues: { missing_category_count: 0, negative_adjustment_count: 0, pending_approval_count: 2, denied_approval_count: 0, open_clock_count: 0, pending_overtime_count: 0, denied_overtime_count: 0 },
    summary: { employee_count: 0, adjustment_count: 0, total_hours: 8, regular_hours: 8, overtime_hours: 0, current_count: 0, carryover_count: 0, correction_count: 0, exclusion_count: 2 },
  };
  apiMocks.manualReview.mockImplementation(async () => manual);
  apiMocks.review.mockImplementation(async () => {
    manual = { ...manual, exclusions: manual.exclusions.slice(1), issues: { ...manual.issues, pending_approval_count: 1 }, summary: { ...manual.summary, total_hours: 14, regular_hours: 14, exclusion_count: 1 } };
    data.overview.readiness = { ...data.overview.readiness, eligible_hours: 14, held_entries: 1, held_hours: 4 };
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });
    return { time_entry: timeEntry };
  });
  function SourcePanels() {
    const [refreshToken, setRefreshToken] = useState(0);
    const invalidate = () => setRefreshToken(token => token + 1);
    return <MemoryRouter><AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} refreshToken={refreshToken} onSourceChanged={invalidate} />
      <AireManualPaymentReconciliation payPeriodId={17} payPeriodStatus="draft" payPeriodVoided={false} payrollItems={[]} refreshToken={refreshToken} onChanged={invalidate} /></MemoryRouter>;
  }
  render(<SourcePanels />);
  expect(await screen.findByText('8.00 regular · 0.00 OT')).toBeTruthy();
  expect(screen.getByText(/2 held entries remain outside/)).toBeTruthy();
  await user.click(screen.getByRole('button', { name: 'Approve time' }));
  await act(async () => { await new Promise<void>(resolve => requestAnimationFrame(() => resolve())); });
  await user.type(screen.getByRole('textbox', { name: /reason/i }), 'Verified source approval');
  await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }));
  expect(await screen.findByText('14.00 regular · 0.00 OT')).toBeTruthy();
  expect(await screen.findByText(/1 held entries remain outside/)).toBeTruthy();
  expect(screen.queryByText(/2 held entries remain outside/)).toBeNull();
});

it('disables source commands when a same-period refresh fails', async () => {
  const view = render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
  await screen.findByRole('button', { name: 'Approve time' });
  apiMocks.overview.mockRejectedValueOnce(new Error('Source unavailable'));
  view.rerender(<AirePayrollCockpit payPeriodId={17} calendar={calendar} refreshToken={1} onRefresh={vi.fn()} />);
  expect(await screen.findByText('Source unavailable')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Approve time' }).hasAttribute('disabled')).toBe(true);
});


it.each([false, true])('settles a pending cockpit approval only for its current period (navigate=%s)', async (navigate) => {
  const user = userEvent.setup(); const onSourceChanged = vi.fn();
  let resolveReview!: () => void;
  apiMocks.review.mockImplementationOnce(() => new Promise<void>(resolve => { resolveReview = resolve; }));
  const view = render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} onSourceChanged={onSourceChanged} />);
  await user.click(await screen.findByRole('button', { name: 'Approve time' }));
  await act(async () => { await new Promise<void>(resolve => requestAnimationFrame(() => resolve())); });
  await user.type(screen.getByRole('textbox', { name: /reason/i }), 'Verified source approval');
  await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }));
  view.rerender(<AirePayrollCockpit payPeriodId={navigate ? 18 : 17} calendar={calendar} refreshToken={1} onRefresh={vi.fn()} onSourceChanged={onSourceChanged} />);
  await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(2));
  await act(async () => resolveReview());
  if (navigate) {
    expect(onSourceChanged).not.toHaveBeenCalled();
    expect(screen.queryByText(/Time approved in time tracking/)).toBeNull();
    expect(screen.queryByRole('dialog')).toBeNull();
  } else {
    expect(await screen.findByText(/Time approved in time tracking/)).toBeTruthy();
    expect(onSourceChanged).toHaveBeenCalledOnce();
    expect(screen.queryByRole('dialog')).toBeNull();
  }
});
