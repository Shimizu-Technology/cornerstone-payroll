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
import { FeedbackProvider } from '@/components/ui/action-feedback';
import { ApiError } from '@/services/api';

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
      payment_attested_pending_evidence_entries: 0,
      payment_attested_pending_evidence_hours: 0,
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

afterEach(() => { cleanup(); vi.resetAllMocks(); });

describe('AirePayrollCockpit', () => {
  it.each([false, true])('keeps a batch-only connection usable with published=%s without requesting optional live features', async (published) => {
    render(<AirePayrollCockpit payPeriodId={17} calendar={{
      ...calendar,
      source_name: 'Neutral Weekly Time',
      source_capabilities: ['time_summary_v1', 'payroll_calendar_v2', 'finalized_batch_v2', 'exact_line_receipts_v2'],
      publication: published ? calendar.publication : null,
    }} onRefresh={vi.fn()} />);

    expect(screen.getByText('Payroll uses verified time batches')).toBeTruthy();
    expect(screen.getByText(/Neutral Weekly Time provides cutoff batches/)).toBeTruthy();
    expect(screen.queryByText('Hours ready for payroll')).toBeNull();
    expect(screen.queryByText('Time tracking payroll workspace')).toBeNull();
    await act(async () => { await Promise.resolve(); });
    for (const api of [apiMocks.manualReview, apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
      expect(api).not.toHaveBeenCalled();
    }
  });

  it('replaces the live preview with the verified batch action', async () => {
    const user = userEvent.setup();
    const onReviewFinalizedBatch = vi.fn();
    const verifiedCalendar: AirePayrollCalendarState = {
      ...calendar,
      source_capabilities: ['time_summary_v1', 'payroll_calendar_v2', 'finalized_batch_v2', 'exact_line_receipts_v2'],
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
    expect(screen.queryByText('Hours ready for payroll')).toBeNull();
    await user.click(screen.getByRole('button', { name: 'Review and add time tracking hours' }));
    expect(onReviewFinalizedBatch).toHaveBeenCalledOnce();
    expect(apiMocks.manualReview).not.toHaveBeenCalled();
    for (const api of [apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
      expect(api).not.toHaveBeenCalled();
    }
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

  it.each([
    { total: 6, eligible: 0, held: 0, heldEntries: 0 },
    { total: 20, eligible: 8, held: 6, heldEntries: 1 },
  ])('keeps reported-payment evidence separate from eligible and other held hours ($total total)', async ({ total, eligible, held, heldEntries }) => {
    const user = userEvent.setup();
    const data = fixtures();
    data.overview.readiness = { ...data.overview.readiness,
      total_hours: total, total_entries: total === 6 ? 1 : 3,
      eligible_hours: eligible, eligible_entries: eligible > 0 ? 1 : 0,
      held_hours: held, held_entries: heldEntries,
      pending_approvals: 0,
      payment_attested_pending_evidence_hours: 6,
      payment_attested_pending_evidence_entries: 1,
    };
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);

    const reported = await screen.findByRole('group', { name: 'Payment reported' });
    expect(within(reported).getByText('6.00 hrs')).toBeTruthy();
    expect(within(reported).getByText('1 timecard · evidence pending · not included')).toBeTruthy();
    expect(within(screen.getByRole('group', { name: 'Ready this payroll' })).getByText(`${eligible.toFixed(2)} hrs`)).toBeTruthy();
    expect(within(screen.getByRole('group', { name: 'Other held time' })).getByText(`${held.toFixed(2)} hrs`)).toBeTruthy();
    expect(within(screen.getByRole('group', { name: 'Total time' })).getByText(`${total.toFixed(2)} hrs`)).toBeTruthy();

    await user.click(screen.getByRole('button', { name: /lock time tracking cutoff/i }));
    expect(within(screen.getByRole('dialog')).getByText(new RegExp(`${held.toFixed(2)} other held hours remain outside this payroll for review`))).toBeTruthy();
    expect(within(screen.getByRole('dialog')).getByText(/6.00 reported-payment hours remain excluded while payment evidence is pending; reporting payment does not verify it/)).toBeTruthy();
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }));
    expect(apiMocks.finalize).not.toHaveBeenCalled();
    expect(apiMocks.review).not.toHaveBeenCalled();
  });

  it('refreshes approved hours into the canonical reported-payment bucket without changing time or payroll', async () => {
    const data = fixtures();
    data.overview.readiness = { ...data.overview.readiness,
      total_entries: 1, total_hours: 6, eligible_entries: 1, eligible_hours: 6,
      held_entries: 0, held_hours: 0,
      pending_approvals: 0,
      payment_attested_pending_evidence_entries: 0, payment_attested_pending_evidence_hours: 0,
    };
    apiMocks.overview.mockResolvedValueOnce({ aire_payroll_cockpit: data.overview });
    const view = render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} refreshToken={0} onRefresh={vi.fn()} />);
    await screen.findByRole('group', { name: 'Payment reported' });
    expect(within(screen.getByRole('group', { name: 'Ready this payroll' })).getByText('6.00 hrs')).toBeTruthy();

    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: { ...data.overview, readiness: { ...data.overview.readiness,
      eligible_entries: 0, eligible_hours: 0,
      payment_attested_pending_evidence_entries: 1, payment_attested_pending_evidence_hours: 6,
    } } });
    view.rerender(<AirePayrollCockpit payPeriodId={17} calendar={calendar} refreshToken={1} onRefresh={vi.fn()} />);
    await waitFor(() => expect(within(screen.getByRole('group', { name: 'Payment reported' })).getByText('6.00 hrs')).toBeTruthy());
    expect(within(screen.getByRole('group', { name: 'Payment reported' })).getByText('1 timecard · evidence pending · not included')).toBeTruthy();
    expect(within(screen.getByRole('group', { name: 'Ready this payroll' })).getByText('0.00 hrs')).toBeTruthy();
    expect(within(screen.getByRole('group', { name: 'Other held time' })).getByText('0.00 hrs')).toBeTruthy();
    expect(apiMocks.finalize).not.toHaveBeenCalled();
    expect(apiMocks.review).not.toHaveBeenCalled();
    expect(apiMocks.correct).not.toHaveBeenCalled();
  });

  it('keeps missing optional source counters unavailable instead of inventing zero or deriving held hours', async () => {
    const user = userEvent.setup();
    const data = fixtures();
    data.overview.readiness = { ...data.overview.readiness,
      total_hours: 6, eligible_hours: 0, eligible_entries: 0,
      held_hours: undefined, held_entries: undefined,
      payment_attested_pending_evidence_hours: undefined,
      payment_attested_pending_evidence_entries: undefined,
    };
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    for (const name of ['Other held time', 'Payment reported']) {
      const metric = await screen.findByRole('group', { name });
      expect(within(metric).getByText('—')).toBeTruthy();
      expect(within(metric).getByText(/Timecard count unavailable · hours unavailable/)).toBeTruthy();
      expect(within(metric).queryByText('0.00 hrs')).toBeNull();
      expect(within(metric).queryByText('6.00 hrs')).toBeNull();
    }
    await user.click(screen.getByRole('button', { name: /lock time tracking cutoff/i }));
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByText(/Other held hours are unavailable; review source details separately/)).toBeTruthy();
    expect(within(dialog).getByText(/Reported-payment hours are unavailable; review payment evidence separately/)).toBeTruthy();
    expect(within(dialog).queryByText(/0.00 other held hours|0.00 reported-payment hours|6.00 other held hours/)).toBeNull();
    expect((within(dialog).getByRole('button', { name: 'Lock eligible time' }) as HTMLButtonElement).disabled).toBe(false);
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }));
    expect(apiMocks.finalize).not.toHaveBeenCalled();
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
    await user.click(screen.getByText(/Review timecards, held hours and team/));
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

  it.each(['not_required', 'approved'])('offers correction after cutoff for ordinary completed time without redundant %s approval', async (approvalStatus) => {
    const user = userEvent.setup();
    const data = fixtures();
    data.overview.payroll_period = { ...period, status: 'finalized', cutoff_state: 'finalized' };
    data.overview.readiness.pending_approvals = 0;
    data.entries.time_entries = [{
      ...timeEntry,
      capture: { entry_method: 'clock', clock_source: 'kiosk', ordinary: true, admin_override: false },
      state: { ...timeEntry.state, approval_status: approvalStatus, payable_now: true, payroll_disposition: 'eligible', payroll_exclusion_reasons: [], included_hours: 8.08 },
      lifecycle: { status: 'ready_for_cutoff', label: 'Ready for cutoff' },
    }];
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });
    apiMocks.entries.mockResolvedValue(data.entries);
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);

    await screen.findByText('Malia Cruz');
    expect(screen.queryByRole('button', { name: 'Approve time' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Deny time' })).toBeNull();
    await user.click(screen.getByRole('button', { name: 'Correct' }));
    expect(screen.getByRole('heading', { name: 'Correct time in time tracking' })).toBeTruthy();
    expect((screen.getByLabelText('Start time') as HTMLInputElement).value).toBe('08:04');
    expect((screen.getByLabelText('End time') as HTMLInputElement).value).toBe('17:09');
    expect((screen.getByRole('button', { name: 'Save correction' }) as HTMLButtonElement).disabled).toBe(true);
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(apiMocks.correct).not.toHaveBeenCalled();
    expect(apiMocks.review).not.toHaveBeenCalled();
  });

  it('corrects ordinary completed time and reviews its renewed pending approval at the new source version', async () => {
    const user = userEvent.setup();
    const onSourceChanged = vi.fn();
    const data = fixtures();
    const ordinaryEntry = {
      ...timeEntry,
      capture: { entry_method: 'clock', clock_source: 'mobile', ordinary: true, admin_override: false },
      state: { ...timeEntry.state, approval_status: 'not_required', payable_now: true, payroll_disposition: 'eligible', payroll_exclusion_reasons: [], included_hours: 8.08 },
      lifecycle: { status: 'ready_for_cutoff', label: 'Ready for cutoff' },
    };
    const correctedEntry = { ...ordinaryEntry, version: 4, description: 'Confirmed ordinary shift description',
      state: { ...ordinaryEntry.state, approval_status: 'pending', payable_now: false, payroll_disposition: 'pending_approval', payroll_exclusion_reasons: ['pending_approval'], included_hours: 0 },
      lifecycle: { status: 'awaiting_approval', label: 'Awaiting approval' },
    };
    const approvedEntry = { ...correctedEntry, version: 5, state: { ...ordinaryEntry.state, approval_status: 'approved' }, lifecycle: ordinaryEntry.lifecycle };
    data.overview.readiness.pending_approvals = 0;
    apiMocks.overview
      .mockResolvedValueOnce({ aire_payroll_cockpit: data.overview })
      .mockResolvedValueOnce({ aire_payroll_cockpit: { ...data.overview, readiness: { ...data.overview.readiness, pending_approvals: 1 } } })
      .mockResolvedValue({ aire_payroll_cockpit: data.overview });
    apiMocks.entries
      .mockResolvedValueOnce({ ...data.entries, time_entries: [ordinaryEntry] })
      .mockResolvedValueOnce({ ...data.entries, time_entries: [correctedEntry] })
      .mockResolvedValue({ ...data.entries, time_entries: [approvedEntry] });
    apiMocks.correct.mockResolvedValue({ time_entry: correctedEntry });
    apiMocks.review.mockResolvedValue({ time_entry: approvedEntry });
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} onSourceChanged={onSourceChanged} />);

    await screen.findByText('Malia Cruz');
    expect(screen.queryByRole('button', { name: 'Approve time' })).toBeNull();
    await user.click(screen.getByRole('button', { name: 'Correct' }));
    const description = screen.getByLabelText('Description');
    await user.clear(description);
    await user.type(description, 'Confirmed ordinary shift description');
    await user.type(screen.getByLabelText('Correction reason'), 'Verified the clock entry with the employee');
    await user.click(screen.getByRole('button', { name: 'Save correction' }));
    await waitFor(() => expect(apiMocks.correct).toHaveBeenCalledWith(17, '42', expect.objectContaining({
      expected_version: 3,
      command_id: expect.any(String),
      reason: 'Verified the clock entry with the employee',
      description: 'Confirmed ordinary shift description',
    })));
    for (const field of ['work_date', 'start_time', 'end_time', 'time_category_id', 'breaks']) {
      expect(apiMocks.correct.mock.calls[0][2]).not.toHaveProperty(field);
    }
    await waitFor(() => expect(onSourceChanged).toHaveBeenCalledOnce());
    expect(await screen.findByText(/now needs administrator approval/i)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Deny time' })).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Approve time' }));
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByRole('heading', { name: 'Approve time' })).toBeTruthy();
    const approve = within(dialog).getByRole('button', { name: 'Approve time' }) as HTMLButtonElement;
    expect(approve.disabled).toBe(true);
    await user.type(within(dialog).getByRole('textbox', { name: /reason/i }), 'Manager verified the corrected ordinary shift');
    await user.click(approve);
    await waitFor(() => expect(apiMocks.review).toHaveBeenCalledWith(17, '42', expect.objectContaining({
      expected_version: 4,
      command_id: expect.any(String),
      decision: 'approve',
      reason: 'Manager verified the corrected ordinary shift',
    })));
    await waitFor(() => expect(onSourceChanged).toHaveBeenCalledTimes(2));
    expect(screen.queryByRole('button', { name: 'Approve time' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Deny time' })).toBeNull();
    expect(apiMocks.reviewOvertime).not.toHaveBeenCalled();
  });

  it('keeps correction and pending ordinary-time review disabled without command permission', async () => {
    const user = userEvent.setup();
    const data = fixtures(false);
    data.entries.time_entries = [{
      ...timeEntry,
      capture: { entry_method: 'clock', clock_source: 'kiosk', ordinary: true, admin_override: false },
    }];
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });
    apiMocks.entries.mockResolvedValue(data.entries);
    render(
      <MemoryRouter>
        <AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />
      </MemoryRouter>
    );

    await screen.findByText('Malia Cruz');
    for (const name of ['Correct', 'Approve time', 'Deny time']) {
      const button = screen.getByRole('button', { name }) as HTMLButtonElement;
      expect(button.disabled).toBe(true);
      await user.click(button);
    }
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(apiMocks.correct).not.toHaveBeenCalled();
    expect(apiMocks.review).not.toHaveBeenCalled();
    expect(apiMocks.reviewOvertime).not.toHaveBeenCalled();
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
      end_time: '17:15',
      command_id: expect.any(String),
    })));
    expect(await screen.findByText(/now needs administrator approval/i)).toBeTruthy();
    await waitFor(() => expect(onSourceChanged).toHaveBeenCalledOnce());
  });

  it.each([
    ['Start time', '13:45', { start_time: '13:45' }],
    ['End time', '14:15', { end_time: '14:15' }],
    ['Work date', '2026-10-15', { work_date: '2026-10-15' }],
    ['Time category', '3', { time_category_id: '3' }],
  ] as const)('sends only changed %s and leaves exact punches and breaks to the source', async (label, value, fields) => {
    const user = userEvent.setup();
    const preciseEntry = {
      ...timeEntry,
      start_time: '01:59 PM', end_time: '02:00 PM',
      clock_in_at: '2026-10-14T03:59:19.427187Z',
      clock_out_at: '2026-10-14T04:00:32.935086Z',
      capture: { entry_method: 'clock', clock_source: 'mobile', ordinary: true, admin_override: false },
      breaks: [{ id: '9', start_time: '2026-10-14T03:59:30.123456Z', end_time: '2026-10-14T03:59:40.987654Z', active: false }],
    };
    apiMocks.entries.mockResolvedValue({ ...fixtures().entries, time_entries: [preciseEntry] });
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');
    await user.click(screen.getByRole('button', { name: 'Correct' }));
    if (label === 'Time category') await user.selectOptions(screen.getByLabelText(label), value);
    else fireEvent.change(screen.getByLabelText(label), { target: { value } });
    await user.type(screen.getByLabelText('Correction reason'), 'Verified the changed field with the employee');
    await user.click(screen.getByRole('button', { name: 'Save correction' }));
    await waitFor(() => expect(apiMocks.correct).toHaveBeenCalledExactlyOnceWith(17, '42', {
      command_id: expect.any(String), expected_version: 3,
      reason: 'Verified the changed field with the employee', ...fields,
    }));
  });

  it('does not submit a reason-only correction or fields changed back to their original display values', async () => {
    const user = userEvent.setup();
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');
    await user.click(screen.getByRole('button', { name: 'Correct' }));
    await user.type(screen.getByLabelText('Correction reason'), 'Checked the original record');
    const save = screen.getByRole('button', { name: 'Save correction' });
    expect((save as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByLabelText('Start time'), { target: { value: '08:00' } });
    expect((save as HTMLButtonElement).disabled).toBe(false);
    fireEvent.change(screen.getByLabelText('Start time'), { target: { value: '08:04' } });
    expect((save as HTMLButtonElement).disabled).toBe(true);
    await user.click(save);
    expect(apiMocks.correct).not.toHaveBeenCalled();
  });

  it('completes a missing clock-out without resubmitting its original punch, date or breaks', async () => {
    const user = userEvent.setup();
    apiMocks.entries.mockResolvedValue({ ...fixtures().entries, time_entries: [{
      ...timeEntry, end_time: null, clock_in_at: '2026-10-14T08:04:19.123456+10:00', clock_out_at: null,
      capture: { entry_method: 'clock', clock_source: 'mobile', ordinary: true, admin_override: false },
      state: { ...timeEntry.state, status: 'active', missing_punch: true },
    }] });
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');
    await user.click(screen.getByRole('button', { name: 'Correct' }));
    fireEvent.change(screen.getByLabelText('End time'), { target: { value: '17:15' } });
    await user.type(screen.getByLabelText('Correction reason'), 'Confirmed the missing clock-out');
    await user.click(screen.getByRole('button', { name: 'Save correction' }));
    await waitFor(() => expect(apiMocks.correct).toHaveBeenCalledExactlyOnceWith(17, '42', {
      command_id: expect.any(String), expected_version: 3, reason: 'Confirmed the missing clock-out', end_time: '17:15',
    }));
  });

  it.each(['edit', 'remove', 'add', 'remove all'] as const)('preserves raw endpoints of retained breaks during %s', async (operation) => {
    const user = userEvent.setup();
    const first = { id: '9', start_time: '2026-10-14T02:00:12.123456Z', end_time: '2026-10-14T02:15:32.987654Z', active: false };
    const second = { id: '10', start_time: '2026-10-14T14:00:19.111222+10:00', end_time: '2026-10-14T14:15:27.333444+10:00', active: false };
    apiMocks.entries.mockResolvedValue({ ...fixtures().entries, time_entries: [{ ...timeEntry, breaks: [first, second] }] });
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');
    await user.click(screen.getByRole('button', { name: 'Correct' }));
    if (operation === 'edit') fireEvent.change(screen.getByLabelText('Break 1 end'), { target: { value: '12:20' } });
    else if (operation === 'add') {
      await user.click(screen.getByRole('button', { name: 'Add break' }));
      fireEvent.change(screen.getByLabelText('Break 3 start'), { target: { value: '15:00' } });
      fireEvent.change(screen.getByLabelText('Break 3 end'), { target: { value: '15:10' } });
    } else {
      await user.click(screen.getByRole('button', { name: 'Remove break 1' }));
      if (operation === 'remove all') await user.click(screen.getByRole('button', { name: 'Remove break 1' }));
    }
    await user.type(screen.getByLabelText('Correction reason'), 'Verified the complete corrected break list');
    await user.click(screen.getByRole('button', { name: 'Save correction' }));
    const rawFirst = { start_time: first.start_time, end_time: first.end_time };
    const rawSecond = { start_time: second.start_time, end_time: second.end_time };
    const breaks = operation === 'edit' ? [{ ...rawFirst, end_time: '12:20' }, rawSecond]
      : operation === 'remove' ? [rawSecond]
      : operation === 'add' ? [rawFirst, rawSecond, { start_time: '15:00', end_time: '15:10' }] : [];
    await waitFor(() => expect(apiMocks.correct).toHaveBeenCalledExactlyOnceWith(17, '42', {
      command_id: expect.any(String), expected_version: 3,
      reason: 'Verified the complete corrected break list', breaks,
    }));
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
    await user.type(screen.getByLabelText('Description'), 'Corrected description');
    await user.type(screen.getByLabelText('Correction reason'), 'Correcting the description only');
    const save = screen.getByRole('button', { name: 'Save correction' }) as HTMLButtonElement;
    expect(save.disabled).toBe(false);
    await user.click(save);

    await waitFor(() => expect(apiMocks.correct).toHaveBeenCalled());
    const payload = apiMocks.correct.mock.calls[0]?.[2];
    expect(payload).not.toHaveProperty('breaks');
  });

  it('distinguishes batch inclusion from a recorded payment when processing is absent', async (): Promise<void> => {
    const user = userEvent.setup();
    const data = fixtures();
    data.settlements.settlement_cases[0].included_payroll_batch_id = 'included-batch';
    apiMocks.settlements.mockResolvedValue(data.settlements);
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');
    await user.click(screen.getByRole('button', { name: /Held time 1/i }));
    expect(screen.getByText('Included in payroll batch')).toBeTruthy();
    expect(screen.getByText('No payment has been recorded')).toBeTruthy();
    expect(screen.queryByText('Not imported into payroll')).toBeNull();
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
    expect(screen.queryByText('Time changes require Client management, a Payroll manager, or an admin')).toBeNull();

    expect((screen.getByRole('button', { name: 'Approve time' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: /lock time tracking cutoff/i }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByRole('link', { name: /connect my time tracking account/i }).getAttribute('href'))
      .toBe('/app/aire-account-connection?source_id=1&return_to=%2Fcompanies%2F1%2Fpay-periods%2F17');
  });

  it('explains role-disabled commands when time tracking access is already configured', async () => {
    mockLoads(false);
    const data = fixtures(false);
    data.overview.command_access.delegation_configured = true;
    apiMocks.overview.mockResolvedValue({ aire_payroll_cockpit: data.overview });
    const user = userEvent.setup();
    render(<MemoryRouter><AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} /></MemoryRouter>);

    await screen.findByText('Time changes require Client management, a Payroll manager, or an admin');
    expect(screen.getByText('Ask an administrator to grant Client management for this client. You can still review time and payroll evidence.')).toBeTruthy();
    expect(screen.queryByRole('link', { name: /connect my time tracking account/i })).toBeNull();
    expect(screen.getByText('Malia Cruz')).toBeTruthy();
    const approve = screen.getByRole('button', { name: 'Approve time' }) as HTMLButtonElement;
    const correct = screen.getByRole('button', { name: 'Correct' }) as HTMLButtonElement;
    expect(approve.disabled).toBe(true);
    expect(correct.disabled).toBe(true);
    await user.click(approve);
    await user.click(correct);
    expect(apiMocks.review).not.toHaveBeenCalled();
    expect(apiMocks.correct).not.toHaveBeenCalled();
    await user.click(screen.getByRole('button', { name: /Held time 1/i }));
    expect((screen.getByRole('button', { name: 'Choose destination' }) as HTMLButtonElement).disabled).toBe(true);
    expect(apiMocks.routeSettlement).not.toHaveBeenCalled();
  });

  it('does not describe a role restriction for authorized commands temporarily disabled during refresh', async () => {
    const user = userEvent.setup();
    render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');
    expect(screen.queryByText('Time changes require Client management, a Payroll manager, or an admin')).toBeNull();
    let finish!: (value: { aire_payroll_cockpit: AirePayrollCockpitOverview }) => void;
    apiMocks.overview.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
    await user.click(screen.getByRole('button', { name: 'Refresh time tracking' }));
    expect((screen.getByRole('button', { name: 'Approve time' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.queryByText('Time changes require Client management, a Payroll manager, or an admin')).toBeNull();
    await act(async () => finish({ aire_payroll_cockpit: fixtures().overview }));
    await waitFor(() => expect((screen.getByRole('button', { name: 'Approve time' }) as HTMLButtonElement).disabled).toBe(false));
    expect(screen.queryByText('Time changes require Client management, a Payroll manager, or an admin')).toBeNull();
  });

  it.each([{ payPeriodId: 18, sourceId: 1 }, { payPeriodId: 17, sourceId: 2 }])('does not let an older refresh overwrite period $payPeriodId/source $sourceId', async ({ payPeriodId, sourceId }) => {
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
    view.rerender(<AirePayrollCockpit payPeriodId={payPeriodId} calendar={{ ...calendar, source_id: sourceId }} onRefresh={vi.fn()} />);
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

  it('clears prior-source details and open commands while a replacement source loads for the same period', async () => {
    const user = userEvent.setup();
    const view = render(<MemoryRouter><AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} /></MemoryRouter>);
    await screen.findByText('Malia Cruz');
    await user.click(screen.getByRole('button', { name: 'Correct' }));
    expect(screen.getByRole('heading', { name: 'Correct time in time tracking' })).toBeTruthy();

    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const next = fixtures(false);
    next.overview.employees = [];
    next.entries.time_entries = [];
    next.exceptions.time_exceptions = [];
    apiMocks.overview.mockImplementationOnce(async () => { await gate; return { aire_payroll_cockpit: next.overview }; });
    apiMocks.entries.mockImplementationOnce(async () => { await gate; return next.entries; });
    apiMocks.exceptions.mockImplementationOnce(async () => { await gate; return next.exceptions; });
    apiMocks.settlements.mockImplementationOnce(async () => { await gate; return next.settlements; });
    view.rerender(<MemoryRouter><AirePayrollCockpit payPeriodId={17} calendar={{ ...calendar, source_id: 2 }} onRefresh={vi.fn()} /></MemoryRouter>);

    expect(screen.queryByText('Malia Cruz')).toBeNull();
    expect(screen.queryByRole('heading', { name: 'Correct time in time tracking' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Approve time' })).toBeNull();
    expect(apiMocks.correct).not.toHaveBeenCalled();
    await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(2));
    await act(async () => { release(); });
    expect(screen.queryByText('Malia Cruz')).toBeNull();
  });

  it('closes live commands when the same source stops advertising the cockpit', async () => {
    const user = userEvent.setup();
    const view = render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
    await screen.findByText('Malia Cruz');
    await user.click(screen.getByRole('button', { name: 'Correct' }));
    view.rerender(<AirePayrollCockpit payPeriodId={17} calendar={{ ...calendar,
      source_capabilities: ['time_summary_v1', 'payroll_calendar_v2', 'finalized_batch_v2', 'exact_line_receipts_v2'],
    }} onRefresh={vi.fn()} />);
    expect(screen.getByText('Payroll uses verified time batches')).toBeTruthy();
    expect(screen.queryByRole('heading', { name: 'Correct time in time tracking' })).toBeNull();
    expect(screen.queryByText('Malia Cruz')).toBeNull();
    await act(async () => { await Promise.resolve(); });
    for (const api of [apiMocks.manualReview, apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
      expect(api).toHaveBeenCalledTimes(1);
    }
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

  it('publishes one stale-review notification and reannounces one identical retry with the refreshed version', async () => {
    const user = userEvent.setup();
    apiMocks.review.mockRejectedValue(new ApiError('Entry version changed', 409));
    const view = render(<FeedbackProvider><AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} /></FeedbackProvider>);
    await user.click(await screen.findByRole('button', { name: 'Approve time' }));
    fireEvent.change(screen.getByRole('textbox', { name: /reason/i }), { target: { value: 'Verified source review' } });
    const latest = fixtures();
    latest.entries.time_entries = latest.entries.time_entries.map(entry => ({ ...entry, version: 4 }));
    latest.exceptions.time_exceptions = latest.exceptions.time_exceptions.map(entry => ({ ...entry, version: 4 }));
    apiMocks.entries.mockResolvedValue(latest.entries);
    apiMocks.exceptions.mockResolvedValue(latest.exceptions);
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }));
    const notifications = within(document.querySelector('[data-feedback-portal]') as HTMLElement);
    await waitFor(() => expect(notifications.getAllByRole('alert')).toHaveLength(1));
    expect(apiMocks.review).toHaveBeenCalledOnce();
    expect(apiMocks.review.mock.calls[0][2].expected_version).toBe(3);
    expect(notifications.getByRole('alert').textContent).toContain('review it again before deciding');
    await waitFor(() => expect(apiMocks.entries).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }).hasAttribute('disabled')).toBe(false));
    await user.click(notifications.getByRole('button', { name: /Dismiss notification/ }));
    expect(notifications.queryByRole('alert')).toBeNull();
    expect(screen.getByRole('dialog')).toBeTruthy();
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }));
    await waitFor(() => expect(notifications.getAllByRole('alert')).toHaveLength(1));
    expect(apiMocks.review).toHaveBeenCalledTimes(2);
    expect(apiMocks.review.mock.calls[1][2].expected_version).toBe(4);
    expect(apiMocks.review.mock.calls[1][2].command_id).not.toBe(apiMocks.review.mock.calls[0][2].command_id);
    await waitFor(() => expect(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }).hasAttribute('disabled')).toBe(false));
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(notifications.getAllByRole('alert')).toHaveLength(1);
    expect(apiMocks.review).toHaveBeenCalledTimes(2);
    view.rerender(<FeedbackProvider><AirePayrollCockpit payPeriodId={18} calendar={calendar} onRefresh={vi.fn()} /></FeedbackProvider>);
    await waitFor(() => expect(notifications.queryByRole('alert')).toBeNull());
    expect(apiMocks.review).toHaveBeenCalledTimes(2);
  });

  it('does not publish a late stale-review error after leaving its pay period', async () => {
    const user = userEvent.setup();
    let reject!: (error: Error) => void;
    apiMocks.review.mockImplementationOnce(() => new Promise<void>((_, fail) => { reject = fail; }));
    const view = render(<FeedbackProvider><AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} /></FeedbackProvider>);
    await user.click(await screen.findByRole('button', { name: 'Approve time' }));
    fireEvent.change(screen.getByRole('textbox', { name: /reason/i }), { target: { value: 'Verified source review' } });
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve time' }));
    view.rerender(<FeedbackProvider><AirePayrollCockpit payPeriodId={18} calendar={calendar} onRefresh={vi.fn()} /></FeedbackProvider>);
    await act(async () => { reject(new ApiError('Entry version changed', 409)); });
    expect(within(document.querySelector('[data-feedback-portal]') as HTMLElement).queryByRole('alert')).toBeNull();
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(apiMocks.review).toHaveBeenCalledOnce();
    expect(apiMocks.review.mock.calls[0][0]).toBe(17);
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
    const invalidate = () => { setRefreshToken(token => token + 1); return true; };
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
  for (const endpoint of [apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
    expect(endpoint).toHaveBeenCalledTimes(2);
  }
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
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  } else {
    expect(await screen.findByText(/Time approved in time tracking/)).toBeTruthy();
    expect(onSourceChanged).toHaveBeenCalledOnce();
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  }
});


it('uses one host-driven endpoint round and keeps commands disabled until it settles', async () => {
  const user = userEvent.setup();
  function Host() {
    const [refreshToken, setRefreshToken] = useState(0);
    return <AirePayrollCockpit payPeriodId={17} calendar={calendar} refreshToken={refreshToken} onRefresh={vi.fn()}
      onSourceChanged={() => { setRefreshToken(token => token + 1); return true; }} />;
  }
  render(<Host />);
  await screen.findByRole('button', { name: 'Approve time' });
  let resolveOverview!: (value: { aire_payroll_cockpit: AirePayrollCockpitOverview }) => void;
  apiMocks.overview.mockImplementationOnce(() => new Promise(resolve => { resolveOverview = resolve; }));
  await user.click(screen.getByRole('button', { name: 'Refresh time tracking' }));
  expect(screen.getByRole('button', { name: 'Approve time' }).hasAttribute('disabled')).toBe(true);
  for (const endpoint of [apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
    expect(endpoint).toHaveBeenCalledTimes(2);
  }
  await act(async () => resolveOverview({ aire_payroll_cockpit: fixtures().overview }));
  await waitFor(() => expect(screen.getByRole('button', { name: 'Approve time' }).hasAttribute('disabled')).toBe(false));
  for (const endpoint of [apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
    expect(endpoint).toHaveBeenCalledTimes(2);
  }
});

it.each([false, true])('falls back to local refresh for notification-only callbacks (callback=%s)', async (provided) => {
  const user = userEvent.setup(); const onSourceChanged = vi.fn();
  render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} onSourceChanged={provided ? onSourceChanged : undefined} />);
  await screen.findByRole('button', { name: 'Approve time' });
  await user.click(screen.getByRole('button', { name: 'Refresh time tracking' }));
  await waitFor(() => expect(screen.getByRole('button', { name: 'Approve time' }).hasAttribute('disabled')).toBe(false));
  for (const endpoint of [apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
    expect(endpoint).toHaveBeenCalledTimes(2);
  }
  expect(onSourceChanged).toHaveBeenCalledTimes(provided ? 1 : 0);
});


it('keeps the delivered-state fetch when a host calendar refresh settles after new props arrive', async () => {
  const user = userEvent.setup();
  let finishHost!: () => void;
  let finishOverview!: (value: { aire_payroll_cockpit: AirePayrollCockpitOverview }) => void;
  const pendingCalendar: AirePayrollCalendarState = { ...calendar, external_pay_period_id: null,
    publication: { ...calendar.publication!, delivery_status: 'pending' } };
  const onRefresh = vi.fn(() => new Promise<boolean>(resolve => { finishHost = () => resolve(true); }));
  apiMocks.overview.mockImplementationOnce(() => new Promise(resolve => { finishOverview = resolve; }));
  const view = render(<AirePayrollCockpit payPeriodId={17} calendar={pendingCalendar} onRefresh={onRefresh} />);
  await user.click(screen.getByRole('button', { name: 'Refresh' }));
  expect(onRefresh).toHaveBeenCalledOnce();
  view.rerender(<AirePayrollCockpit payPeriodId={17} calendar={calendar} refreshToken={1} onRefresh={onRefresh} />);
  await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledOnce());
  await act(async () => finishHost());
  await act(async () => finishOverview({ aire_payroll_cockpit: fixtures().overview }));
  await waitFor(() => expect(screen.getByRole('button', { name: 'Approve time' }).hasAttribute('disabled')).toBe(false));
  expect(await screen.findByText('Malia Cruz')).toBeTruthy();
  for (const endpoint of [apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
    expect(endpoint).toHaveBeenCalledExactlyOnceWith(17, expect.any(Object));
  }
});

it('uses one endpoint round when the host reloads the same finalized event as a fresh object', async () => {
  const user = userEvent.setup();
  const onRefresh = vi.fn();
  let finishHost!: () => void;
  const finalizedCalendar: AirePayrollCalendarState = { ...calendar, finalized_batch: {
    event_id: 'event-17', verification_status: 'pending', verification_attempts: 0,
    occurred_at: '2026-10-23T00:01:00+10:00', payroll_batch_id: 'batch-17', payroll_batch_checksum: 'checksum',
  } };
  function Host() {
    const [refreshToken, setRefreshToken] = useState(0);
    const [currentCalendar, setCalendar] = useState(finalizedCalendar);
    return <AirePayrollCockpit payPeriodId={17} calendar={currentCalendar} refreshToken={refreshToken} onRefresh={async () => {
      onRefresh(); setRefreshToken(token => token + 1);
      await new Promise<void>(resolve => { finishHost = () => {
        setCalendar({ ...finalizedCalendar, finalized_batch: { ...finalizedCalendar.finalized_batch! } });
        resolve();
      }; });
      return true;
    }} />;
  }
  render(<Host />);
  await screen.findByRole('button', { name: 'Approve time' });
  await user.click(screen.getByRole('button', { name: 'Refresh' }));
  await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(2));
  await act(async () => finishHost());
  await waitFor(() => expect(screen.getByRole('button', { name: 'Approve time' }).hasAttribute('disabled')).toBe(false));
  expect(onRefresh).toHaveBeenCalledOnce();
  for (const endpoint of [apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
    expect(endpoint).toHaveBeenCalledTimes(2);
  }
});

it.each([undefined, false])('retains the local calendar refresh fallback when the host returns %s', async (ownership) => {
  const user = userEvent.setup();
  const onRefresh = vi.fn().mockResolvedValue(ownership);
  render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={onRefresh} />);
  await screen.findByRole('button', { name: 'Approve time' });
  await user.click(screen.getByRole('button', { name: 'Refresh' }));
  await waitFor(() => expect(apiMocks.overview).toHaveBeenCalledTimes(2));
  expect(onRefresh).toHaveBeenCalledOnce();
  for (const endpoint of [apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
    expect(endpoint).toHaveBeenCalledTimes(2);
  }
});

it('keeps the due-period preview neutral until a locked batch is verified', async () => {
  render(<AirePayrollCockpit payPeriodId={17} calendar={{ ...calendar, cutoff_state: 'cutoff_due' }} onRefresh={vi.fn()} />);
  expect(await screen.findByText('Live preview')).toBeTruthy();
  expect(screen.queryByText('Before cutoff')).toBeNull();
  expect(await screen.findByRole('button', { name: /lock time tracking cutoff/i })).toBeTruthy();
});


it.each(['new event', 'verified status'])('refreshes source state after a meaningful %s change', async variation => {
  const initial: AirePayrollCalendarState = { ...calendar, finalized_batch: {
    event_id: 'event-17', verification_status: 'pending', verification_attempts: 0,
    occurred_at: '2026-10-23T00:01:00+10:00', payroll_batch_id: 'batch-17', payroll_batch_checksum: 'checksum',
  } };
  const view = render(<AirePayrollCockpit payPeriodId={17} calendar={initial} onRefresh={vi.fn()} />);
  await screen.findByText('Malia Cruz');
  const fresh = fixtures();
  fresh.entries.time_entries[0] = { ...fresh.entries.time_entries[0], employee: {
    ...fresh.entries.time_entries[0].employee, name: 'Fresh source entry',
  } };
  apiMocks.entries.mockResolvedValue(fresh.entries);
  view.rerender(<AirePayrollCockpit payPeriodId={17} calendar={{ ...initial, finalized_batch: {
    ...initial.finalized_batch!, event_id: variation === 'new event' ? 'event-18' : 'event-17',
    verification_status: variation === 'verified status' ? 'verified' : 'pending',
  } }} onRefresh={vi.fn()} />);
  expect(await screen.findByText('Fresh source entry')).toBeTruthy();
  for (const endpoint of [apiMocks.overview, apiMocks.entries, apiMocks.exceptions, apiMocks.settlements]) {
    expect(endpoint).toHaveBeenCalledTimes(2);
  }
});

function mockCorrectionCase(currentHours: number | null = 3, reason = 'changed_after_cutoff') {
  const data = fixtures();
  const original = data.settlements.settlement_cases[0];
  data.settlements.settlement_cases = [{ ...original, origin: { ...original.origin, reason },
    time: { ...original.time, held_total_hours: 1, current_total_hours: currentHours },
  }];
  apiMocks.settlements.mockResolvedValue(data.settlements);
  // Overall source history can be paid even while this correction has no
  // acknowledgment. Its latest label must not be reused as correction evidence.
  apiMocks.entries.mockResolvedValue({ ...data.entries, time_entries: [{ ...timeEntry,
    hours: currentHours ?? 0, state: { ...timeEntry.state, approval_status: 'approved', payable_now: true },
    lifecycle: { status: 'payment_issued', label: 'Paid', payment_reference: 'ORIGINAL-CHECK',
      settlements: [{ batch_id: original.origin.payroll_batch_id, total_hours: 4, status: 'payment_issued' }] },
  }] });
  return data.settlements.settlement_cases[0];
}

it.each([3, 1])('keeps correction magnitude and current source %sh separate without inferring sign or baseline', async currentHours => {
  const user = userEvent.setup();
  mockCorrectionCase(currentHours);
  render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
  await screen.findByText('Paid');
  await user.click(screen.getByRole('button', { name: /Held time 1/i }));
  const card = screen.getByText('Correction magnitude: 1.00 hours').closest('article')!;
  expect(within(card).getByText(`Current source time is ${currentHours.toFixed(2)} hours. Review the signed change against the original batch before applying a payroll adjustment.`)).toBeTruthy();
  expect(within(card).getByText('Correction processing')).toBeTruthy();
  expect(within(card).getByText('No processing acknowledgment for this correction yet')).toBeTruthy();
  expect(within(card).getByText('Review original payment evidence in the source history.')).toBeTruthy();
  expect(within(card).queryByText(/original cutoff record|originally held|Not imported into payroll|No payment has been recorded|1.00 held hours/)).toBeNull();
  expect(within(card).queryByText(/decrease|increase|4.00|ORIGINAL-CHECK/)).toBeNull();
  expect(apiMocks.routeSettlement).not.toHaveBeenCalled();
});

it('does not invent current hours or a baseline for a deleted correction source', async () => {
  const user = userEvent.setup();
  mockCorrectionCase(null, 'deleted_after_cutoff');
  const data = fixtures();
  apiMocks.entries.mockResolvedValue({ ...data.entries, time_entries: [] });
  apiMocks.exceptions.mockResolvedValue({ ...data.exceptions, time_exceptions: [] });
  render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
  await user.click(await screen.findByRole('button', { name: /Held time 1/i }));
  const card = screen.getByText('Correction magnitude: 1.00 hours').closest('article')!;
  expect(within(card).getByText('Current source time is unavailable. Review the original batch and signed correction before applying a payroll adjustment.')).toBeTruthy();
  expect(within(card).queryByText(/Current source time is 0|original cutoff record/)).toBeNull();
  await user.click(within(card).getByRole('button', { name: 'Choose destination' }));
  expect(within(screen.getByRole('dialog')).queryByText(/current source time: 0|originally held/)).toBeNull();
});

it.each(['regular', 'not_payable'] as const)('scopes correction routing copy without changing the %s command', async destination => {
  const user = userEvent.setup();
  const correctionCase = mockCorrectionCase();
  render(<AirePayrollCockpit payPeriodId={17} calendar={calendar} onRefresh={vi.fn()} />);
  await user.click(await screen.findByRole('button', { name: /Held time 1/i }));
  await user.click(screen.getByRole('button', { name: 'Choose destination' }));
  const dialog = screen.getByRole('dialog');
  expect(within(dialog).getByRole('heading', { name: 'Choose where to review this correction' })).toBeTruthy();
  expect(within(dialog).getByText(/Correction magnitude: 1.00 hours · current source time: 3.00 hours/)).toBeTruthy();
  expect(within(dialog).getByText("Review the signed change in that payroll's cutoff batch. Routing does not record a payment.")).toBeTruthy();
  expect(within(dialog).queryByText(/originally held|will be included automatically|should never be paid/)).toBeNull();
  if (destination === 'not_payable') await user.click(within(dialog).getByRole('radio', { name: /Do not apply this correction/ }));
  await user.type(within(dialog).getByLabelText('Routing reason'), 'Reviewed the signed correction and preserved original payment evidence');
  await user.click(within(dialog).getByRole('button', { name: destination === 'regular' ? 'Route to payroll' : 'Do not apply correction' }));
  await waitFor(() => expect(apiMocks.routeSettlement).toHaveBeenCalledExactlyOnceWith(17, correctionCase.id, expect.objectContaining({
    expected_version: correctionCase.version, destination_kind: destination,
    reason: 'Reviewed the signed correction and preserved original payment evidence', command_id: expect.any(String),
    ...(destination === 'regular' ? { target_external_pay_period_id: fixtures().overview.routing_options[0].external_pay_period_id } : {}),
  })));
  if (destination === 'not_payable') expect(apiMocks.routeSettlement.mock.calls[0][2]).not.toHaveProperty('target_external_pay_period_id');
  await screen.findByText(destination === 'regular'
    ? 'Correction routed to the selected payroll for review. The original payment remains unchanged.'
    : 'Correction marked not applied with your review reason. The original payment remains unchanged.');
  expect(apiMocks.correct).not.toHaveBeenCalled();
  expect(apiMocks.finalize).not.toHaveBeenCalled();
});

it('keeps source failures visible outside a collapsed verified timecard disclosure', async () => {
  apiMocks.overview.mockRejectedValueOnce(new Error('Source unavailable'));
  const verified: AirePayrollCalendarState = { ...calendar, cutoff_state: 'batch_verified', finalized_batch: {
    event_id: 'failure-event', verification_status: 'verified', verification_attempts: 1, occurred_at: '2026-10-23T00:01:00+10:00',
    payroll_batch_id: 'synthetic-verified', payroll_batch_checksum: 'checksum',
    summary: { employee_count: 1, total_hours: 4, regular_hours: 4, overtime_hours: 0, exclusion_count: 0 },
  } };
  render(<AirePayrollCockpit payPeriodId={17} calendar={verified} onRefresh={vi.fn()} onReviewFinalizedBatch={vi.fn()} />);
  const alert = await screen.findByText('Source unavailable');
  expect(alert.closest('details')).toBeNull();
  expect(screen.getByText('Review timecards, held hours and team').closest('details')?.open).toBe(false);
});
