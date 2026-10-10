// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import type { Employee, PayPeriod } from '@/types';
import { PayPeriodDetail } from './PayPeriodDetail';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  liabilities: vi.fn(),
  payrollFieldInputs: vi.fn(),
  employeesList: vi.fn(),
  runPayroll: vi.fn(),
  refreshSetup: vi.fn(),
  comparison: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  ApiError: class ApiError extends Error {},
  payPeriodsApi: {
    get: apiMocks.get,
    liabilities: apiMocks.liabilities,
    payrollFieldInputs: apiMocks.payrollFieldInputs,
    runPayroll: apiMocks.runPayroll,
    refreshSetup: apiMocks.refreshSetup,
    comparison: apiMocks.comparison,
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
vi.mock('@/components/payroll/TimeTrackingImportModal', () => ({ TimeTrackingImportModal: () => null }));
vi.mock('@/components/payroll/AirePayrollRecordsDialog', () => ({ AirePayrollRecordsDialog: () => null }));
vi.mock('@/components/payroll/AirePayrollCockpit', () => ({ AirePayrollCockpit: () => null }));
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

async function renderCappedFieldWorksheet() {
  vi.clearAllMocks();
  const employee = { id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: 'hourly', pay_rate: 15, pay_frequency: 'biweekly', status: 'active' } as Employee;
  const field = { id: 8, company_id: 7, name: '401(k) supplemental', kind: 'deduction', tax_treatment: 'pre_tax_deduction', category: 'retirement', amount_type: 'fixed', active: true, show_in_payroll_grid: true, sort_order: 0 };
  const assignment = { employee_id: 30, payroll_field_definition_id: 8, amount_type: 'fixed', current_amount: 0, requested_amount: 1070, suggested_amount: 0, overridden: true, editable: true };
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [field], assignments: [assignment], retained_manual_entries: [{ employee_id: 30, field_id: 9, label: 'Previous manual retirement', requested_amount: 1070, applied_amount: 93.04, source: 'manual' }] } });
  apiMocks.runPayroll.mockResolvedValue({ pay_period: { ...initialPayPeriod, status: 'calculated' }, results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } });
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={{ ...initialPayPeriod, status: 'draft' }} />} /></Routes></MemoryRouter>);
  const input = await screen.findByLabelText('401(k) supplemental');
  const card = await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  fireEvent.change(within(card).getByLabelText('Regular hours'), { target: { value: '8' } });
  return input;
}

it('keeps a capped request through an unrelated worksheet calculation and surfaces retained manual entries', async () => {
  const input = await renderCappedFieldWorksheet();
  expect((input as HTMLInputElement).value).toBe('1070.00');
  expect(screen.getByRole('region', { name: 'Retained manual retirement entries' })).toHaveProperty('textContent', expect.stringContaining('Previous manual retirement'));
  expect(screen.getAllByText(/Last applied \$0.00 after limits/).length).toBeGreaterThan(0);
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].payroll_field_inputs['30']['8']).toEqual({ mode: 'override', amount: 1070 });
});

it('marks an intentional zero request even when the prior applied amount was already zero', async () => {
  const input = await renderCappedFieldWorksheet();
  fireEvent.change(input, { target: { value: '0' } });
  fireEvent.blur(input);
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].payroll_field_inputs['30']['8']).toEqual({ mode: 'override', amount: 0, replace_request: true });
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

it('shows partial calculation failures by employee and keeps failed worksheet hours', async () => {
  await renderCappedFieldWorksheet();
  apiMocks.runPayroll.mockResolvedValue({
    pay_period: { ...initialPayPeriod, status: 'draft' },
    results: { success: [], skipped: [], errors: [{ employee_id: 30, name: 'Ana Cruz', error: 'Review the applied historical 401(k) classification.' }] },
  });
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await screen.findByText('Calculated 0 employees. 1 employee needs attention before approval.');
  expect(screen.getByRole('heading', { name: 'Resolve these employees before approval' })).toBeTruthy();
  const link = screen.getByRole('link', { name: 'Review 2026 retirement checks' });
  expect(link.getAttribute('href')).toContain('/companies/7/employees/30/pay-setup?');
  expect(link.getAttribute('href')).toContain('retirement_year=2026#retirement-year-evidence');
  const card = screen.getByRole('region', { name: 'Payroll entry for Ana Cruz' });
  expect((within(card).getByLabelText('Regular hours') as HTMLInputElement).value).toBe('8');
  expect(screen.getByRole('button', { name: 'Review affected employees' })).toBeTruthy();
});


async function renderLoanWorksheet(status: 'draft' | 'calculated' | 'approved' = 'calculated', comparisonResponse?: unknown) {
  vi.clearAllMocks();
  const employee = { id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: 'hourly', pay_rate: 16, pay_frequency: 'semimonthly', status: 'active' } as Employee;
  const other = { ...employee, id: 31, first_name: 'Other' } as Employee;
  const item = { id: 1, employee_id: 30, employment_type: 'hourly', pay_rate: 16, hours_worked: 80.3, overtime_hours: 14, gross_pay: 1620.8, net_pay: 1393.15, loan_deduction: 0 };
  const period = { ...initialPayPeriod, status, run_purpose: 'correction', includes_recurring_items: false, includes_base_salary: false, payroll_items: [item], ...(comparisonResponse ? { cycle: 'regular' } : {}) } as unknown as PayPeriod;
  const options = [{ employee_id: 30, loan_id: 2, name: 'Employee Loan', tracking_mode: 'balance_tracked', current_balance: 3259.97, scheduled_amount: 300, current_amount: 0, eligible: true, mode: 'default' }];
  apiMocks.employeesList.mockResolvedValue({ data: [employee, other], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [], named_loan_options: options } });
  apiMocks.get.mockResolvedValue({ pay_period: { ...period, status: 'calculated' } });
  apiMocks.runPayroll.mockResolvedValue({ pay_period: { ...period, status: 'calculated' }, results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } });
  apiMocks.comparison.mockResolvedValue(comparisonResponse);
  apiMocks.refreshSetup.mockResolvedValue({ pay_period: { ...period, status: 'calculated' }, results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } });
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={period} />} /></Routes></MemoryRouter>);
  if (status === 'approved') { await screen.findByRole('button', { name: 'Refresh current setup' }); return null; }
  return await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
}

it('recalculates exactly the selected correction employee with a named loan repayment', async () => {
  const card = await renderLoanWorksheet();
  fireEvent.change(within(card!).getByLabelText('Employee Loan repayment choice'), { target: { value: 'override' } });
  expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: 'Recalculate' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  const payload = apiMocks.runPayroll.mock.calls[0][1];
  expect(payload.employee_ids).toEqual([30]);
  expect(Object.keys(payload.hours)).toEqual(['30']);
  expect(payload.named_loan_payments).toEqual({ '30': { '2': { mode: 'override', amount: 300 } } });
  expect(payload.hours['30']).toEqual({ regular: 80.3, overtime: 14 });
});

it('withdraws approval and refreshes saved setup without asking the user to recreate payroll', async () => {
  await renderLoanWorksheet('approved');
  fireEvent.click(screen.getByRole('button', { name: 'Refresh current setup' }));
  const dialog = screen.getByRole('dialog');
  expect(within(dialog).getByText(/Existing approval and client review will be withdrawn/)).toBeTruthy();
  fireEvent.click(within(dialog).getByLabelText('Include recurring employee setup'));
  fireEvent.click(within(dialog).getByRole('button', { name: 'Refresh and recalculate' }));
  await waitFor(() => expect(apiMocks.refreshSetup).toHaveBeenCalledWith(12, { includes_recurring_items: true, includes_base_salary: false }));
  expect(await screen.findByRole('button', { name: 'Recalculate' })).toBeTruthy();
});

it('protects unsaved hours in a saved draft from being overwritten by setup refresh', async () => {
  const card = await renderLoanWorksheet('draft');
  fireEvent.change(within(card!).getByLabelText('Regular hours'), { target: { value: '81' } });
  const refresh = screen.getByRole('button', { name: 'Refresh current setup' }) as HTMLButtonElement;
  expect(refresh.disabled).toBe(true);
  expect(refresh.title).toMatch(/Calculate your worksheet edits first/);
  expect(apiMocks.refreshSetup).not.toHaveBeenCalled();
});

it('keeps a setup refresh failure visible without discarding the existing approved payroll', async () => {
  await renderLoanWorksheet('approved');
  apiMocks.refreshSetup.mockRejectedValue(new Error('Employee setup is invalid; correct the saved schedule.'));
  fireEvent.click(screen.getByRole('button', { name: 'Refresh current setup' }));
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Refresh and recalculate' }));
  expect(await within(screen.getByRole('dialog')).findByText('Employee setup is invalid; correct the saved schedule.')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Commit & Finalize' })).toBeTruthy();
});


it('retains a linked loan request when that employee needs calculation recovery', async () => {
  const card = await renderLoanWorksheet();
  fireEvent.change(within(card!).getByLabelText('Employee Loan repayment choice'), { target: { value: 'override' } });
  fireEvent.change(within(card!).getByLabelText('Employee Loan repayment amount'), { target: { value: '400' } });
  apiMocks.runPayroll.mockResolvedValue({ pay_period: { ...initialPayPeriod, status: 'draft', run_purpose: 'correction', includes_recurring_items: false, payroll_items: [{ id: 1, employee_id: 30, employment_type: 'hourly', pay_rate: 16, hours_worked: 80.3, overtime_hours: 14 }] }, results: { success: [], skipped: [], errors: [{ employee_id: 30, name: 'Ana Cruz', error: 'Loan balance needs review.' }] } });
  fireEvent.click(screen.getByRole('button', { name: 'Recalculate' }));
  await screen.findByText('Calculated 0 employees. 1 employee needs attention before approval.');
  const restoredCard = await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  expect((within(restoredCard).getByLabelText('Employee Loan repayment amount') as HTMLInputElement).value).toBe('400.00');
});


it('clearly describes a special-run comparison as limited to selected employees', async () => {
  await renderLoanWorksheet('calculated', {
    comparison_kind: 'selected_employees',
    previous_pay_period: { id: 11, start_date: '2026-09-01', end_date: '2026-09-15', pay_date: '2026-09-16' },
    summary: {}, employee_changes: [],
    review_flags: { status: 'ok', message: 'Selected employees match.', warning_count: 0, review_count: 0 },
  });
  expect(await screen.findByRole('heading', { name: 'Selected Employee Comparison' })).toBeTruthy();
  expect(screen.getByText(/Compared for the selected employees with/)).toBeTruthy();
  expect(screen.getByText(/Employees outside this special run are excluded/)).toBeTruthy();
});


async function renderSavedRateCorrection(singleRate = false) {
  vi.clearAllMocks();
  const employee = { id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: 'hourly', pay_rate: 25, pay_frequency: 'semimonthly', status: 'active', wage_rates: [
    { id: 1, label: 'Old department renamed', rate: 25, is_primary: true, active: false },
    { id: 4, label: 'New department', rate: 40, is_primary: false, active: true },
  ] } as Employee;
  const savedRates = [
    { employee_wage_rate_id: 1, label: 'Original department', rate: 16, regular_hours: 8, overtime_hours: 2, holiday_hours: 1, pto_hours: 3, is_primary: true, active: true },
    ...(!singleRate ? [{ employee_wage_rate_id: 3, label: 'Removed department', rate: 20, regular_hours: 4, overtime_hours: 1, holiday_hours: 2, pto_hours: 1, is_primary: false, active: true }] : []),
  ];
  const item = { id: 1, employee_id: 30, employment_type: 'hourly', pay_rate: 16, hours_worked: singleRate ? 8 : 12, overtime_hours: singleRate ? 2 : 3, holiday_hours: singleRate ? 1 : 3, pto_hours: singleRate ? 3 : 4, timekeeping_source: 'correction_reference', wage_rate_hours: savedRates };
  const period = { ...initialPayPeriod, status: 'draft', run_purpose: 'correction', includes_recurring_items: false, includes_base_salary: false, payroll_items: [item] } as unknown as PayPeriod;
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  apiMocks.runPayroll.mockResolvedValue({ pay_period: { ...period, status: 'calculated' }, results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } });
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={period} />} /></Routes></MemoryRouter>);
  const card = await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  return { card, savedRates };
}

it('preserves correction wage buckets after current rates change or source IDs are deactivated and removed', async () => {
  const { card, savedRates } = await renderSavedRateCorrection();
  expect(within(card).getByText('Original department · $16.00/hr')).toBeTruthy();
  expect(within(card).getByText('Removed department · $20.00/hr')).toBeTruthy();
  expect(within(card).queryByText(/New department/)).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].hours['30'].wage_rates).toEqual(savedRates);
});

it('keeps captured rates and other hour types when the operator deliberately edits one correction bucket', async () => {
  const { card, savedRates } = await renderSavedRateCorrection();
  const bucket = within(card).getByText('Original department · $16.00/hr').parentElement!;
  fireEvent.change(within(bucket).getByLabelText('Regular hours'), { target: { value: '9' } });
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].hours['30'].wage_rates).toEqual([{ ...savedRates[0], regular_hours: 9 }, savedRates[1]]);
});

it('submits a single captured wage bucket with updated hours instead of clearing its historical rate', async () => {
  const { card, savedRates } = await renderSavedRateCorrection(true);
  fireEvent.change(within(card).getByLabelText('Regular hours'), { target: { value: '10' } });
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].hours['30'].wage_rates).toEqual([{ ...savedRates[0], regular_hours: 10 }]);
});
