// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type {
  AirePayrollCalendarState,
  AirePayrollCockpitOverview,
  AirePayrollExceptionsResponse,
  AirePayrollTimeEntriesResponse,
} from '@/types';
import { AirePayrollCockpit } from './AirePayrollCockpit';

const apiMocks = vi.hoisted(() => ({
  overview: vi.fn(),
  entries: vi.fn(),
  exceptions: vi.fn(),
  review: vi.fn(),
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
    reviewAireTimeEntry: apiMocks.review,
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
  category: { id: '2', key: 'regular', name: 'Regular' },
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
  return { overview, entries, exceptions };
}

function mockLoads(canCommand = true) {
  const data = fixtures(canCommand);
  apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });
  apiMocks.entries.mockResolvedValue(data.entries);
  apiMocks.exceptions.mockResolvedValue(data.exceptions);
}

beforeEach(() => {
  vi.clearAllMocks();
  mockLoads();
  apiMocks.review.mockResolvedValue({ time_entry: { ...timeEntry, state: { ...timeEntry.state, approval_status: 'approved', payable_now: true } } });
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

    await user.click(screen.getByRole('button', { name: 'Approve' }));
    const submit = screen.getByRole('button', { name: 'Approve time' }) as HTMLButtonElement;
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

  it('keeps the workspace readable but disables commands without a personal delegation', async () => {
    mockLoads(false);
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText(/actions need your AIRE delegation/i);

    expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: /lock AIRE cutoff/i }) as HTMLButtonElement).disabled).toBe(true);
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

    const view = render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(1));
    view.rerender(<AirePayrollCockpit payPeriodId={18} calendar={calendar} onRefresh={vi.fn()} />);
    expect(await screen.findByText('Current Employee')).toBeTruthy();

    await act(async () => { releaseStale?.(); });
    await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(2));
    expect(screen.getByText('Current Employee')).toBeTruthy();
    expect(screen.queryByText('Malia Cruz')).toBeNull();
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

    await user.click(screen.getByRole('button', { name: 'Approve' }));
    const submit = screen.getByRole('button', { name: 'Approve time' }) as HTMLButtonElement;
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

    await user.click(screen.getByRole('button', { name: 'Approve time' }));
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
