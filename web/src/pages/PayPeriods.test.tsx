// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';

import { PayPeriods } from './PayPeriods';
import type { PayrollHistoryRecord } from '@/services/api';

const apiMocks = vi.hoisted(() => ({
  activeCompany: {} as Record<string, unknown>,
  payrollHistoryList: vi.fn(),
  companyGet: vi.fn(),
  payScheduleGet: vi.fn(),
  payPeriodCreate: vi.fn(),
  payPeriodUpdate: vi.fn(),
  payPeriodDelete: vi.fn(),
  runPayroll: vi.fn(),
  approve: vi.fn(),
  commit: vi.fn(),
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({
    activeCompanyId: 11,
    activeCompany: apiMocks.activeCompany,
  }),
}));

vi.mock('@/services/api', () => ({
  ApiError: class ApiError extends Error {},
  companiesApi: { get: apiMocks.companyGet },
  payrollHistoryApi: { list: apiMocks.payrollHistoryList },
  payScheduleSettingsApi: { get: apiMocks.payScheduleGet },
  payPeriodsApi: {
    create: apiMocks.payPeriodCreate,
    update: apiMocks.payPeriodUpdate,
    delete: apiMocks.payPeriodDelete,
    runPayroll: apiMocks.runPayroll,
    approve: apiMocks.approve,
    commit: apiMocks.commit,
  },
}));

const editablePeriod: PayrollHistoryRecord = {
  key: 'native:12',
  record_type: 'native' as const,
  id: 12,
  company_id: 11,
  start_date: '2026-08-24',
  end_date: '2026-09-06',
  pay_date: '2026-09-10',
  status: 'calculated' as const,
  run_purpose: 'regular' as const,
  includes_base_salary: true,
  includes_recurring_items: true,
  correction_status: null,
  notes: null,
  compliance_warnings: [],
  parallel_run: true,
  test_workspace_role: 'practice' as const,
  employee_count: 2,
  total_gross: 3086.25,
  total_net: 2636.7,
  processed_at: null,
  processed_by_name: null,
  source: { system: 'cornerstone', label: 'Cornerstone', detail: 'Cornerstone', locked: false },
  capabilities: {
    view: true,
    edit: true,
    delete: true,
    enter_hours: true,
    run: true,
    approve: true,
    commit: true,
  },
};

const historyResponse = (data: PayrollHistoryRecord[]) => ({
  data,
  meta: {
    current_page: 1,
    per_page: 50,
    total_count: data.length,
    total_pages: 1,
    statuses: { calculated: data.length },
    sources: { cornerstone: data.length },
    years: [2026],
  },
});

afterEach(() => cleanup());

describe('PayPeriods test workspaces', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('guides training replays oldest-first without offering extra pay periods', async () => {
    apiMocks.activeCompany = { id: 11, test_workspace_purpose: 'training_replay' };
    apiMocks.payrollHistoryList.mockResolvedValue(historyResponse([
      { ...editablePeriod, id: 10, key: 'native:10', status: 'approved', test_workspace_role: 'baseline' },
      editablePeriod,
    ]));

    render(<MemoryRouter initialEntries={['/companies/11/pay-runs']}><PayPeriods /></MemoryRouter>);

    expect(await screen.findByText('Complete the practice payrolls from oldest to newest')).toBeTruthy();
    expect(screen.getByText('Complete Practice 1')).toBeTruthy();
    expect(screen.getByText('Complete Practice 2')).toBeTruthy();
    expect(screen.getByText(/Training payrolls are never committed/i)).toBeTruthy();
    expect(screen.queryByText('Payroll Workflow')).toBeNull();
    await waitFor(() => expect(apiMocks.payrollHistoryList).toHaveBeenCalledWith(
      expect.objectContaining({ direction: 'asc', sort: 'pay_period' }),
      11,
    ));
    expect(screen.queryByRole('button', { name: 'New Pay Period' })).toBeNull();
    expect(screen.getAllByText('Locked baseline')).toHaveLength(2);
    expect(screen.getAllByText('Practice payroll')).toHaveLength(2);
    expect(screen.getAllByRole('button', { name: 'Edit' })).toHaveLength(2);
    expect(screen.getAllByRole('button', { name: 'Delete' })).toHaveLength(2);
    expect(screen.getAllByRole('button', { name: /enter hours/i })).toHaveLength(2);
    expect(screen.queryByRole('button', { name: 'Commit' })).toBeNull();
  });

  it('suppresses every mutation action in both read-only row layouts', async () => {
    apiMocks.activeCompany = {
      id: 11,
      test_workspace_purpose: 'backup_snapshot',
      test_workspace_sealed_at: '2026-09-22T00:00:00Z',
    };
    apiMocks.payrollHistoryList.mockResolvedValue(historyResponse([editablePeriod]));

    render(<MemoryRouter initialEntries={['/companies/11/pay-runs']}><PayPeriods /></MemoryRouter>);

    expect((await screen.findAllByText('Read only')).length).toBe(2);
    expect(screen.getAllByRole('button', { name: 'View' })).toHaveLength(2);
    for (const action of ['New Pay Period', 'Edit', 'Delete', 'Enter Hours', 'Recalculate', 'Approve', 'Commit']) {
      expect(screen.queryByRole('button', { name: action })).toBeNull();
    }
    expect(screen.queryByText('Payroll Workflow')).toBeNull();
  });
});
