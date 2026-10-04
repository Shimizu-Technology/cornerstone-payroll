// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import type { Employee, PayPeriod } from '@/types';
import { PayPeriodDetail } from './PayPeriodDetail';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  liabilities: vi.fn(),
  payrollFieldInputs: vi.fn(),
  employeesList: vi.fn(),
  runPayroll: vi.fn(),
  commit: vi.fn(),
}));

const componentMocks = vi.hoisted(() => ({
  timeTrackingImport: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  ApiError: class ApiError extends Error {},
  payPeriodsApi: {
    get: apiMocks.get,
    liabilities: apiMocks.liabilities,
    payrollFieldInputs: apiMocks.payrollFieldInputs,
    runPayroll: apiMocks.runPayroll,
    commit: apiMocks.commit,
  },
  employeesApi: { list: apiMocks.employeesList },
  payrollItemsApi: {},
}));

vi.mock('@/components/payroll/ChecksPanel', () => ({
  ChecksPanel: ({ refreshToken }: { refreshToken?: number }) => (
    <div data-testid="processing-check-list-refresh-token">{refreshToken}</div>
  ),
}));
vi.mock('@/components/checks/NonEmployeeChecksPanel', () => ({ NonEmployeeChecksPanel: () => null }));
vi.mock('@/components/reports/ReportsDownloadPanel', () => ({ ReportsDownloadPanel: () => null }));
vi.mock('@/components/payroll/PayrollFinalRecordPanel', () => ({ PayrollFinalRecordPanel: () => null }));
vi.mock('@/components/payroll/TimeTrackingImportModal', () => ({
  TimeTrackingImportModal: (props: { open: boolean; autoPreview?: boolean; initialSourceId?: number }) => {
    componentMocks.timeTrackingImport(props);
    return props.open ? (
      <div
        data-testid="time-tracking-import-modal"
        data-auto-preview={String(Boolean(props.autoPreview))}
        data-source-id={props.initialSourceId ?? ''}
      />
    ) : null;
  },
}));
vi.mock('@/components/payroll/AirePayrollRecordsDialog', () => ({ AirePayrollRecordsDialog: () => null }));
vi.mock('@/components/payroll/AirePaymentEvidenceHolds', () => ({ AirePaymentEvidenceHolds: () => null }));
vi.mock('@/components/payroll/AireManualPaymentReconciliation', () => ({ AireManualPaymentReconciliation: () => null }));
vi.mock('@/components/payroll/AirePayrollCockpit', () => ({
  AirePayrollCockpit: ({ onReviewFinalizedBatch }: { onReviewFinalizedBatch?: () => void }) => (
    <button type="button" onClick={onReviewFinalizedBatch}>Review verified AIRE batch</button>
  ),
}));
vi.mock('@/components/payroll/PayrollLiabilityPanel', () => ({ PayrollLiabilityPanel: () => null }));
vi.mock('@/components/checks/UnifiedCheckPrintDialog', () => ({ UnifiedCheckPrintDialog: () => null }));

const initialPayPeriod = {
  id: 12,
  company_id: 7,
  start_date: '2026-09-07',
  end_date: '2026-09-20',
  pay_date: '2026-09-24',
  status: 'committed',
  cycle: 'supplemental',
  run_purpose: 'regular',
  payroll_items: [],
  time_tracking: { active_source_types: [], linked_aire_records: [] },
} as unknown as PayPeriod;

afterEach(cleanup);

it('reserves the AIRE source preference for the guided verified-batch review', async () => {
  vi.clearAllMocks();
  apiMocks.employeesList.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  const payPeriod = {
    ...initialPayPeriod,
    status: 'draft',
    time_tracking: {
      active_source_types: ['custom', 'aire_services'],
      linked_aire_records: [],
      aire_calendar: {
        enabled: true,
        source_id: 12,
        source_name: 'AIRE Services',
        eligible: true,
        cutoff_state: 'scheduled',
        needs_revision: false,
        can_publish: false,
        can_retry: false,
      },
    },
  } as unknown as PayPeriod;

  render(
    <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
      <Routes>
        <Route path="/companies/:companyId/pay-runs/:id/:tab" element={
          <PayPeriodDetail initialPayPeriod={payPeriod} />
        } />
      </Routes>
    </MemoryRouter>
  );

  fireEvent.click(await screen.findByRole('button', { name: 'Import Time Tracking' }));

  const modal = await screen.findByTestId('time-tracking-import-modal');
  expect(modal.getAttribute('data-auto-preview')).toBe('false');
  expect(modal.getAttribute('data-source-id')).toBe('');

  fireEvent.click(screen.getByRole('button', { name: 'Review verified AIRE batch' }));
  await waitFor(() => {
    expect(modal.getAttribute('data-auto-preview')).toBe('true');
    expect(modal.getAttribute('data-source-id')).toBe('12');
  });
});

it('reloads processing data and its check list when a sibling tab changes checks', async () => {
  vi.clearAllMocks();
  const refreshedPayPeriod = { ...initialPayPeriod, notes: 'Latest check status' };
  apiMocks.get.mockResolvedValue({ pay_period: refreshedPayPeriod });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  apiMocks.employeesList.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
  const onPayPeriodChange = vi.fn();
  const view = (refreshToken: number) => (
    <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
      <Routes>
        <Route path="/companies/:companyId/pay-runs/:id/:tab" element={
          <PayPeriodDetail initialPayPeriod={initialPayPeriod} onPayPeriodChange={onPayPeriodChange} refreshToken={refreshToken} />
        } />
      </Routes>
    </MemoryRouter>
  );

  const { rerender } = render(view(0));
  expect(await screen.findByTestId('processing-check-list-refresh-token')).toBeTruthy();
  expect(apiMocks.get).not.toHaveBeenCalled();

  rerender(view(1));
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledWith(12));
  await waitFor(() => expect(onPayPeriodChange).toHaveBeenLastCalledWith(refreshedPayPeriod));
  expect(screen.getByTestId('processing-check-list-refresh-token').textContent).toBe('1');
});

it('finishes loading when a sibling refresh supersedes the initial request', async () => {
  vi.clearAllMocks();
  let resolveInitialEmployees!: (response: { data: []; meta: { total_pages: number } }) => void;
  apiMocks.employeesList
    .mockImplementationOnce(() => new Promise((resolve) => { resolveInitialEmployees = resolve; }))
    .mockResolvedValue({ data: [], meta: { total_pages: 1 } });
  apiMocks.get.mockResolvedValue({ pay_period: { ...initialPayPeriod, notes: 'Fresh processing data' } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  const view = (refreshToken: number) => (
    <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
      <Routes>
        <Route path="/companies/:companyId/pay-runs/:id/:tab" element={
          <PayPeriodDetail initialPayPeriod={initialPayPeriod} refreshToken={refreshToken} />
        } />
      </Routes>
    </MemoryRouter>
  );

  const { rerender } = render(view(0));
  await waitFor(() => expect(apiMocks.employeesList).toHaveBeenCalledTimes(1));
  rerender(view(1));
  expect(await screen.findByTestId('processing-check-list-refresh-token')).toBeTruthy();
  expect(screen.getByTestId('processing-check-list-refresh-token').textContent).toBe('1');
  await act(async () => { resolveInitialEmployees({ data: [], meta: { total_pages: 1 } }); });
  expect(screen.getByTestId('processing-check-list-refresh-token').textContent).toBe('1');
});

it('lets a phone user edit payroll hours and bonus in a draft run', async () => {
  vi.clearAllMocks();
  const employee = {
    id: 23,
    company_id: 7,
    first_name: 'Ana',
    last_name: 'Cruz',
    employment_type: 'hourly',
    pay_rate: 15,
    pay_frequency: 'biweekly',
    status: 'active',
  } as Employee;
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });

  render(
    <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
      <Routes>
        <Route path="/companies/:companyId/pay-runs/:id/:tab" element={
          <PayPeriodDetail initialPayPeriod={{ ...initialPayPeriod, status: 'draft' }} />
        } />
      </Routes>
    </MemoryRouter>
  );

  const card = await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  expect(apiMocks.employeesList).toHaveBeenCalledWith(expect.objectContaining({ eligible_pay_period_id: 12, page: 1 }));
  const regularHours = within(card).getByLabelText('Regular hours') as HTMLInputElement;
  const bonus = within(card).getByLabelText('Bonus this payroll for Ana Cruz') as HTMLInputElement;
  fireEvent.change(regularHours, { target: { value: '36' } });
  fireEvent.change(bonus, { target: { value: '75' } });

  expect(regularHours.value).toBe('36');
  expect(bonus.value).toBe('75.00');
});

it('keeps an unpaid active employee out of a calculated run while allowing pay entry', async () => {
  vi.clearAllMocks();
  const employee = {
    id: 29,
    company_id: 7,
    first_name: 'Noel',
    last_name: 'Cruz',
    employment_type: 'hourly',
    pay_rate: 15,
    pay_frequency: 'biweekly',
    status: 'active',
  } as Employee;
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });

  render(
    <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
      <Routes>
        <Route path="/companies/:companyId/pay-runs/:id/:tab" element={
          <PayPeriodDetail initialPayPeriod={{ ...initialPayPeriod, status: 'calculated' }} />
        } />
      </Routes>
    </MemoryRouter>
  );

  expect(await screen.findByText('No pay in this period for 1 eligible employee')).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: 'Enter pay' }));
  expect(await screen.findByRole('region', { name: 'Payroll entry for Noel Cruz' })).toBeTruthy();
});

it('calculates another employee while a variable-salary employee has no period pay', async () => {
  vi.clearAllMocks();
  const hourly = {
    id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz',
    employment_type: 'hourly', pay_rate: 15, pay_frequency: 'biweekly', status: 'active',
  } as Employee;
  const unpaidVariable = {
    id: 31, company_id: 7, first_name: 'Mia', last_name: 'Santos',
    employment_type: 'salary', salary_type: 'variable', pay_rate: 0,
    pay_frequency: 'biweekly', status: 'active',
  } as Employee;
  apiMocks.employeesList.mockResolvedValue({ data: [hourly, unpaidVariable], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  apiMocks.runPayroll.mockResolvedValue({
    pay_period: { ...initialPayPeriod, status: 'calculated' },
    results: { success: [{ employee_id: hourly.id }], skipped: [{ employee_id: unpaidVariable.id }], errors: [] },
  });

  render(
    <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
      <Routes>
        <Route path="/companies/:companyId/pay-runs/:id/:tab" element={
          <PayPeriodDetail initialPayPeriod={{ ...initialPayPeriod, status: 'draft' }} />
        } />
      </Routes>
    </MemoryRouter>
  );

  const card = await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  fireEvent.change(within(card).getByLabelText('Regular hours'), { target: { value: '8' } });
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));

  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].salary_overrides).toBeUndefined();
});

it('edits the selected active wage rate after an inactive rate', async () => {
  vi.clearAllMocks();
  const employee = {
    id: 24,
    company_id: 7,
    first_name: 'Mia',
    last_name: 'Santos',
    employment_type: 'hourly',
    pay_rate: 15,
    pay_frequency: 'biweekly',
    status: 'active',
    wage_rates: [
      { id: 1, label: 'Retired', rate: 10, is_primary: false, active: false },
      { id: 2, label: 'Server', rate: 15, is_primary: true, active: true },
      { id: 3, label: 'Trainer', rate: 20, is_primary: false, active: true },
    ],
  } as Employee;
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });

  render(
    <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
      <Routes>
        <Route path="/companies/:companyId/pay-runs/:id/:tab" element={
          <PayPeriodDetail initialPayPeriod={{ ...initialPayPeriod, status: 'draft' }} />
        } />
      </Routes>
    </MemoryRouter>
  );

  const card = await screen.findByRole('region', { name: 'Payroll entry for Mia Santos' });
  const server = within(card).getByText(/Server ·/).parentElement as HTMLElement;
  const trainer = within(card).getByText(/Trainer ·/).parentElement as HTMLElement;
  const serverHours = within(server).getByLabelText('Regular hours') as HTMLInputElement;
  const trainerHours = within(trainer).getByLabelText('Regular hours') as HTMLInputElement;

  fireEvent.change(trainerHours, { target: { value: '12' } });

  expect(trainerHours.value).toBe('12');
  expect(serverHours.value).toBe('0');
});

function approvedCommitView() {
  apiMocks.employeesList.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  return <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes>
    <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={{ ...initialPayPeriod, status: 'approved' }} />} />
  </Routes></MemoryRouter>;
}
it('requires explicit React confirmation and lets an operator cancel without an API write', async () => {
  vi.clearAllMocks(); render(approvedCommitView());
  fireEvent.click(await screen.findByRole('button', { name: 'Commit & Finalize' }));
  expect(await screen.findByRole('dialog', { name: 'Commit and finalize payroll?' })).toBeTruthy();
  expect(apiMocks.commit).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Keep reviewing' }));
  expect(screen.queryByRole('dialog')).toBeNull(); expect(apiMocks.commit).not.toHaveBeenCalled();
});
it('closes before the API completes, blocks duplicate writes and leaves a failed commit visible', async () => {
  vi.clearAllMocks();
  let rejectCommit!: (error: Error) => void;
  apiMocks.commit.mockReturnValue(new Promise((_resolve, reject) => { rejectCommit = reject; }));
  render(approvedCommitView());
  fireEvent.click(await screen.findByRole('button', { name: 'Commit & Finalize' }));
  const confirm = await screen.findByRole('button', { name: 'Confirm commit' });
  fireEvent.click(confirm); fireEvent.click(confirm);
  expect(apiMocks.commit).toHaveBeenCalledExactlyOnceWith(12);
  expect(screen.queryByRole('dialog')).toBeNull();
  expect((screen.getByRole('button', { name: 'Committing...' }) as HTMLButtonElement).disabled).toBe(true);
  await act(async () => rejectCommit(new Error('Commit rejected: stale approval')));
  expect(await screen.findByText('Commit rejected: stale approval')).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Commit & Finalize' }) as HTMLButtonElement).disabled).toBe(false);
});

it('drops an open confirmation when navigating to another approved run', async () => {
  vi.clearAllMocks(); approvedCommitView();
  apiMocks.get.mockResolvedValue({ pay_period: { ...initialPayPeriod, id: 13, status: 'approved' } });
  function NavigateRuns() {
    const navigate = useNavigate();
    return <><button onClick={() => navigate('/companies/7/pay-runs/13/work')}>Other run</button>
      <PayPeriodDetail initialPayPeriod={{ ...initialPayPeriod, status: 'approved' }} /></>;
  }
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes>
    <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<NavigateRuns />} />
  </Routes></MemoryRouter>);
  fireEvent.click(await screen.findByRole('button', { name: 'Commit & Finalize' }));
  expect(await screen.findByRole('dialog')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Other run' }));
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledWith(13));
  await screen.findByRole('button', { name: 'Commit & Finalize' });
  expect(screen.queryByRole('dialog')).toBeNull(); expect(apiMocks.commit).not.toHaveBeenCalled();
});
