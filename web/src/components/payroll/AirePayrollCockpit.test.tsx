// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
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

const apiMocks = vi.hoisted(() => ({
  overview: vi.fn(),
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
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ isManager: true }),
}));

vi.mock('@/services/api', () => ({
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
  payPeriodsApi: {
    airePayrollCockpit: apiMocks.overview,
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
  },
}));

const calendar: AirePayrollCalendarState = {
  enabled: true,
  source_id: 1,
  source_name: 'AIRE Services',
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
    command_access: { can_read: true, can_command: canCommand, delegation_configured: canCommand },
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
        payroll_batch_id: 'AIRE-PAY-ORIGIN',
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
}

beforeEach(() => {
  vi.clearAllMocks();
  mockLoads();
  apiMocks.review.mockResolvedValue({ time_entry: { ...timeEntry, state: { ...timeEntry.state, approval_status: 'approved', payable_now: true } } });
  apiMocks.reviewOvertime.mockResolvedValue({ time_entry: { ...timeEntry, state: { ...timeEntry.state, overtime_status: 'approved', payable_now: true } } });
  apiMocks.correct.mockResolvedValue({ time_entry: { ...timeEntry, version: 4 } });
  apiMocks.routeSettlement.mockResolvedValue({ settlement_case: { ...fixtures().settlements.settlement_cases[0], status: 'scheduled', version: 3 } });
  apiMocks.finalize.mockResolvedValue({ result: { status: 'finalized', payroll_batch_id: 'AIRE-PAY-1' } });
});

afterEach(() => cleanup());

describe('AirePayrollCockpit', () => {
  it('shows exact AIRE time, readiness, and mapping in one payroll workspace', async () => {
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);

    expect(await screen.findByText('AIRE payroll workspace')).toBeTruthy();
    expect(screen.getByText('16.08 hrs')).toBeTruthy();
    expect(screen.getAllByText('8.08 hrs').length).toBe(2);
    expect(screen.getByText('08:04 AM – 05:09 PM')).toBeTruthy();
    expect(screen.getAllByText('Mapped').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Awaiting approval').length).toBeGreaterThan(0);
    expect(apiMocks.entries).toHaveBeenCalledWith(17, { page: 1 });
  });

  it('requires the operator to explain an approval and sends the source version', async () => {
    const user = userEvent.setup();
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: 'Approve time' }));
    const submit = within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }) as HTMLButtonElement;
    expect(submit.disabled).toBe(true);
    await user.type(screen.getByRole('textbox', { name: /reason/i }), 'Verified against manager note');
    await user.click(submit);

    await waitFor(() => expect(apiMocks.review).toHaveBeenCalledWith(17, '42', expect.objectContaining({
      expected_version: 3,
      decision: 'approve',
      reason: 'Verified against manager note',
      command_id: expect.any(String),
    })));
    await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(2));
  });

  it('reviews ordinary clock-entry overtime in AIRE without requiring a base-time approval', async () => {
    const user = userEvent.setup();
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

    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
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
    expect(await screen.findByText('Overtime approved in AIRE and saved in both audit histories.')).toBeTruthy();
  });

  it('shows who approved time and overtime, when, and why', async () => {
    const data = fixtures();
    const reviewedEntry = {
      ...timeEntry,
      capture: { entry_method: 'clock', clock_source: 'mobile', ordinary: true, admin_override: false },
      state: { ...timeEntry.state, approval_status: 'approved', overtime_status: 'approved', payable_now: true },
      approval: { actor: { name: 'AIRE Admin' }, occurred_at: '2026-10-15T08:00:00+10:00', note: 'Matched the schedule' },
      overtime_approval: { actor: { name: 'Chels Shimizu' }, occurred_at: '2026-10-15T08:05:00+10:00', note: 'Authorized overtime' },
    };
    data.entries.time_entries = [reviewedEntry];
    apiMocks.entries.mockResolvedValue(data.entries);

    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);

    expect(await screen.findByText(/Time approved by AIRE Admin/)).toBeTruthy();
    expect(screen.getByText(/Oct 15, 2026, 8:00:00 AM/)).toBeTruthy();
    expect(screen.getByText(/Matched the schedule/)).toBeTruthy();
    expect(screen.getByText(/Overtime approved by Chels Shimizu/)).toBeTruthy();
    expect(screen.getByText(/Oct 15, 2026, 8:05:00 AM/)).toBeTruthy();
    expect(screen.getByText(/Authorized overtime/)).toBeTruthy();
  });

  it('corrects a manual timecard in AIRE and makes the new approval requirement explicit', async () => {
    const user = userEvent.setup();
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
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
    expect(screen.getByText(/AIRE has 60 total break minutes but no exact break times/i)).toBeTruthy();
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
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
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

  it('keeps the workspace readable but disables commands without an AIRE account connection', async () => {
    mockLoads(false);
    render(
      <MemoryRouter>
        <AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />
      </MemoryRouter>
    );
    await screen.findByText(/actions need your AIRE access/i);

    expect((screen.getByRole('button', { name: 'Approve time' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: /lock AIRE cutoff/i }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByRole('link', { name: /connect my AIRE account/i }).getAttribute('href'))
      .toBe('/time-tracking-sources?source_id=1');
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
    expect(screen.getByRole('heading', { name: 'Correct time in AIRE' })).toBeTruthy();

    view.rerender(<AirePayrollCockpit payPeriodId={18} calendar={calendar} onRefresh={vi.fn()} />);

    await waitFor(() => expect(screen.queryByRole('heading', { name: 'Correct time in AIRE' })).toBeNull());
    expect(apiMocks.correct).not.toHaveBeenCalled();
  });

  it('locks a due period only after confirmation and refreshes both systems', async () => {
    const user = userEvent.setup();
    const onRefresh = vi.fn().mockResolvedValue(undefined);
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={onRefresh} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: /lock AIRE cutoff/i }));
    await user.click(screen.getByRole('button', { name: /lock eligible time/i }));

    await waitFor(() => expect(apiMocks.finalize).toHaveBeenCalledWith(17, expect.objectContaining({
      expected_version: 2,
      reason: 'Reviewed AIRE readiness and confirmed eligible time for cutoff',
      command_id: expect.any(String),
    })));
    await waitFor(() => expect(onRefresh).toHaveBeenCalledOnce());
  });

  it('keeps a command failure visible after reloading the latest AIRE details', async () => {
    const user = userEvent.setup();
    apiMocks.review.mockRejectedValueOnce(new Error('AIRE could not record this approval'));
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
    await waitFor(() => expect(document.body.textContent).toContain('AIRE could not record this approval'));
    expect(screen.getAllByRole('alert', { hidden: true }).some((alert) => (
      alert.textContent?.includes('AIRE could not record this approval')
    ))).toBe(true);
    await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(2));

    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }));
    await waitFor(() => expect(apiMocks.review).toHaveBeenCalledTimes(2));
    expect(apiMocks.review.mock.calls[1][2].command_id).toBe(apiMocks.review.mock.calls[0][2].command_id);
  });

  it('reports a post-lock Cornerstone refresh failure separately from the successful AIRE command', async () => {
    const user = userEvent.setup();
    const onRefresh = vi.fn().mockRejectedValue(new Error('pay period reload failed'));
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={onRefresh} />);
    await screen.findByText('Malia Cruz');

    await user.click(screen.getByRole('button', { name: /lock AIRE cutoff/i }));
    await user.click(screen.getByRole('button', { name: /lock eligible time/i }));

    expect((await screen.findByRole('alert')).textContent).toContain(
      'AIRE was locked, but Cornerstone could not refresh: pay period reload failed'
    );
    expect(apiMocks.finalize).toHaveBeenCalledOnce();
  });
});
