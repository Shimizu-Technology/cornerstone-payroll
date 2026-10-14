// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useState } from 'react';
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import type { AirePayrollCalendarState, Employee, PayPeriod } from '@/types';
import { PayPeriodDetail } from './PayPeriodDetail';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  liabilities: vi.fn(),
  payrollFieldInputs: vi.fn(),
  employeesList: vi.fn(),
  runPayroll: vi.fn(),
  commit: vi.fn(),
  refreshSetup: vi.fn(),
  comparison: vi.fn(),
}));

const componentMocks = vi.hoisted(() => ({
  timeTrackingImport: vi.fn(),
  calendarRefreshCompleted: vi.fn(),
  correctionCallback: vi.fn(),
  paymentMethodSaved: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  ApiError: class ApiError extends Error {},
  payPeriodsApi: {
    get: apiMocks.get,
    liabilities: apiMocks.liabilities,
    payrollFieldInputs: apiMocks.payrollFieldInputs,
    runPayroll: apiMocks.runPayroll,
    commit: apiMocks.commit,
    refreshSetup: apiMocks.refreshSetup,
    comparison: apiMocks.comparison,
  },
  employeesApi: { list: apiMocks.employeesList },
  payrollItemsApi: {},
}));

vi.mock('@/components/payroll/ChecksPanel', () => ({
  ChecksPanel: ({ refreshToken, payPeriod }: { refreshToken?: number; payPeriod: PayPeriod }) => (
    <><div data-testid="processing-check-list-refresh-token">{refreshToken}</div>
      <div data-testid="saved-instrument-state">{payPeriod.payroll_items?.[0]?.voided ? 'Voided' : 'Assigned'}</div></>
  ),
}));
vi.mock('@/components/payroll/PaymentMethodDialog', () => ({
  PaymentMethodDialog: ({ onSaved }: { onSaved: () => Promise<void> }) => { componentMocks.paymentMethodSaved(onSaved); return null; },
}));
vi.mock('@/components/checks/NonEmployeeChecksPanel', () => ({ NonEmployeeChecksPanel: () => null }));
vi.mock('@/components/reports/ReportsDownloadPanel', () => ({ ReportsDownloadPanel: () => null }));
vi.mock('@/components/payroll/PayrollFinalRecordPanel', () => ({ PayrollFinalRecordPanel: () => null }));
vi.mock('@/components/payroll/TimeTrackingImportModal', () => ({
  TimeTrackingImportModal: (props: { open: boolean; autoPreview?: boolean; initialSourceId?: number; onImportComplete?: () => Promise<boolean>; onCorrectionRecorded?: () => void }) => {
    componentMocks.timeTrackingImport(props);
    return props.open ? (
      <div
        data-testid="time-tracking-import-modal"
        data-auto-preview={String(Boolean(props.autoPreview))}
        data-source-id={props.initialSourceId ?? ''}
      ><button onClick={props.onImportComplete}>Complete explicit time import</button><button onClick={props.onCorrectionRecorded}>Record accounting correction</button></div>
    ) : null;
  },
}));
vi.mock('@/components/payroll/AirePayrollRecordsDialog', () => ({ AirePayrollRecordsDialog: () => null }));
vi.mock('@/components/payroll/AirePaymentEvidenceHolds', () => ({
  AirePaymentEvidenceHolds: ({ refreshToken, onChanged }: { refreshToken: number; onChanged: () => void }) => (
    <button data-testid="source-holds-revision" data-revision={refreshToken} onClick={onChanged}>Change source hold</button>
  ),
}));
vi.mock('@/components/payroll/AireManualPaymentReconciliation', () => ({
  AireManualPaymentReconciliation: ({ refreshToken, onChanged }: { refreshToken: number; onChanged: () => void }) => (
    <button data-testid="source-reconciliation-revision" data-revision={refreshToken} onClick={onChanged}>Change source allocation</button>
  ),
}));
vi.mock('@/components/payroll/AirePayrollCockpit', () => ({
  AirePayrollCockpit: ({ onReviewFinalizedBatch, refreshToken, onSourceChanged, onRefresh }: { onReviewFinalizedBatch?: () => void; refreshToken: number; onSourceChanged: () => void; onRefresh: () => Promise<boolean | void> }) => (
    <div data-testid="source-cockpit-revision" data-revision={refreshToken}>
      <button type="button" onClick={onReviewFinalizedBatch}>Review verified time tracking batch</button>
      <button type="button" onClick={onSourceChanged}>Approve source time</button>
      <button type="button" onClick={() => { void onRefresh().then(componentMocks.calendarRefreshCompleted); }}>Refresh source calendar</button>
    </div>
  ),
}));
vi.mock('@/components/payroll/PayrollLiabilityPanel', () => ({
  PayrollLiabilityPanel: ({ reconciliation }: { reconciliation?: { status: string; postings: unknown[] } | null }) =>
    <div data-testid="saved-liability-state">{reconciliation?.status}:{reconciliation?.postings.length}</div>,
}));
vi.mock('@/components/payroll/CorrectionPanel', () => ({
  CorrectionPanel: ({ payPeriod, onPayPeriodChange }: { payPeriod: PayPeriod; onPayPeriodChange: (updated: PayPeriod) => void }) => {
    componentMocks.correctionCallback(onPayPeriodChange);
    return <button onClick={() => onPayPeriodChange({ ...payPeriod, correction_status: 'voided', payroll_items: undefined })}>Finish correction</button>;
  },
}));
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

const sourceCalendar: AirePayrollCalendarState = {
  enabled: true, source_id: 12, source_name: 'Synthetic time tracking', eligible: true,
  external_pay_period_id: 'source-period-12', cutoff_state: 'batch_verified',
  needs_revision: false, can_publish: false, can_retry: false,
  finalized_batch: { event_id: 'event-12', verification_status: 'verified', verification_attempts: 1,
    occurred_at: '2026-09-22T07:00:00Z', payroll_batch_id: 'batch-12', payroll_batch_checksum: 'checksum-12' },
};

afterEach(cleanup);

it.each([
  { recurring: false, expectedGross: '$64.00', editedGross: '$89.00', firstEmployee: 'Ana Cruz' },
  { recurring: true, expectedGross: '$214.00', editedGross: '$239.00', firstEmployee: 'Zed Cruz' },
])('previews and sorts draft gross with recurring setup $recurring while retaining explicit bonus', async ({ recurring, expectedGross, editedGross, firstEmployee }) => {
  vi.clearAllMocks();
  const employee = {
    id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: 'hourly',
    pay_rate: 16, pay_frequency: 'semimonthly', status: 'active',
    default_custom_earnings: [{ name: 'Allowance', amount: 120 }],
    default_payroll_adjustments: [
      { label: 'Additional allowance', amount: 30, treatment: 'taxable_addition', active: true },
      { label: 'Inactive allowance', amount: 90, treatment: 'taxable_addition', active: false },
    ],
  } as unknown as Employee;
  const other = { ...employee, id: 31, first_name: 'Zed', pay_rate: 100, default_custom_earnings: [], default_payroll_adjustments: [] };
  const period = {
    ...initialPayPeriod, status: 'draft', run_purpose: 'adjustment', includes_recurring_items: recurring,
    payroll_items: [
      { id: 1, employee_id: 30, employment_type: 'hourly', pay_rate: 16, hours_worked: 4, overtime_hours: 0 },
      { id: 2, employee_id: 31, employment_type: 'hourly', pay_rate: 100, hours_worked: 1, overtime_hours: 0 },
    ],
  } as unknown as PayPeriod;
  apiMocks.employeesList.mockResolvedValue({ data: [employee, other], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={period} />} /></Routes></MemoryRouter>);
  const card = await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  const row = screen.getAllByRole('link', { name: 'Ana Cruz' }).map(link => link.closest('tr')).find(Boolean)!;
  expect(within(row).getByText(expectedGross)).toBeTruthy();
  const sort = screen.getByRole('option', { name: 'Est. Gross Low-High' }).closest('select')!;
  fireEvent.change(sort, { target: { value: 'gross:asc' } });
  const table = row.closest('table')!;
  expect(within(table).getAllByRole('link')[0].textContent).toBe(firstEmployee);
  fireEvent.change(within(card).getByLabelText('Bonus this payroll for Ana Cruz'), { target: { value: '25' } });
  expect(within(row).getByText(editedGross)).toBeTruthy();
  expect(apiMocks.runPayroll).not.toHaveBeenCalled();
});

async function renderTaxableFieldPreview(recurring: boolean) {
  vi.clearAllMocks();
  const employee = { id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: 'hourly', pay_rate: 16, pay_frequency: 'semimonthly', status: 'active' } as Employee;
  const period = { ...initialPayPeriod, status: 'draft', includes_recurring_items: recurring,
    payroll_items: [{ id: 1, employee_id: 30, employment_type: 'hourly', pay_rate: 16, hours_worked: 4, overtime_hours: 0 }] } as unknown as PayPeriod;
  const field = { id: 8, company_id: 7, name: 'Allowance', kind: 'addition', tax_treatment: 'taxable_addition', category: 'allowance', amount_type: 'fixed', default_amount: 75, active: true, show_in_payroll_grid: true, sort_order: 0 };
  const percentage = { ...field, id: 9, name: 'Percentage allowance', amount_type: 'percentage', default_amount: null, default_percentage: 10, sort_order: 1 };
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [field, percentage], assignments: [
    { employee_id: 30, payroll_field_definition_id: 8, amount_type: 'fixed', assigned_amount: null, default_amount: 75, suggested_amount: 75, editable: true, overridden: false },
    { employee_id: 30, payroll_field_definition_id: 9, amount_type: 'percentage', assigned_percentage: null, default_percentage: 10, editable: true, overridden: false },
  ] } });
  apiMocks.runPayroll.mockResolvedValue({ pay_period: { ...period, status: 'calculated' }, results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } });
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={period} />} /></Routes></MemoryRouter>);
  const input = await screen.findByLabelText('Allowance requested amount for Ana Cruz') as HTMLInputElement;
  const row = input.closest('tr')!;
  return { input, row };
}

it.each([
  { recurring: false, gross: '$64.00', withOverride: '$89.00', defaultInput: '' },
  { recurring: true, gross: '$145.40', withOverride: '$95.40', defaultInput: '75.00' },
])('previews fixed and percentage defaults with recurring setup $recurring and keeps explicit amounts', async ({ recurring, gross, withOverride, defaultInput }) => {
  const { input, row } = await renderTaxableFieldPreview(recurring);
  expect(input.value).toBe(defaultInput);
  expect(within(row).getByText(gross)).toBeTruthy();
  fireEvent.change(input, { target: { value: '25' } });
  expect(within(row).getByText(withOverride)).toBeTruthy();
  fireEvent.click(within(row).getByRole('button', { name: /Override/ }));
  expect(input.value).toBe(defaultInput);
  expect(within(row).getByText(gross)).toBeTruthy();
  expect(apiMocks.runPayroll).not.toHaveBeenCalled();
});

it('submits an explicit amount equal to the excluded employee default as a one-time override', async () => {
  const { input } = await renderTaxableFieldPreview(false);
  fireEvent.change(input, { target: { value: '25' } });
  fireEvent.change(input, { target: { value: '75' } });
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].payroll_field_inputs['30']['8']).toEqual({ mode: 'override', amount: 75, replace_request: true });
});

it('can tab through untouched excluded fields and calculate without creating empty overrides', async () => {
  const user = userEvent.setup();
  const { input } = await renderTaxableFieldPreview(false);
  await user.click(input);
  await user.tab();
  await user.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].payroll_field_inputs['30']).toEqual({ '8': { mode: 'default' }, '9': { mode: 'default' } });
});

it('keeps a cleared explicit request invalid until it is deliberately reset to excluded setup', async () => {
  const user = userEvent.setup();
  const { input, row } = await renderTaxableFieldPreview(false);
  await user.click(input);
  await user.type(input, '25');
  await user.clear(input);
  await user.tab();
  await user.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  expect(apiMocks.runPayroll).not.toHaveBeenCalled();
  expect(input.getAttribute('aria-invalid')).toBe('true');
  await user.click(within(row).getByRole('button', { name: 'Enter an amount or clear this payroll amount' }));
  await user.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].payroll_field_inputs['30']['8']).toEqual({ mode: 'default' });
});

it('retains an explicit zero override after blur when recurring setup is excluded', async () => {
  const user = userEvent.setup();
  const { input } = await renderTaxableFieldPreview(false);
  await user.click(input);
  await user.type(input, '0');
  await user.tab();
  await user.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].payroll_field_inputs['30']['8']).toEqual({ mode: 'override', amount: 0, replace_request: true });
});

it('reserves the time tracking source preference for the guided verified-batch review', async () => {
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
        source_name: 'time tracking Services',
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

  fireEvent.click(screen.getByRole('button', { name: 'Review verified time tracking batch' }));
  await waitFor(() => {
    expect(modal.getAttribute('data-auto-preview')).toBe('true');
    expect(modal.getAttribute('data-source-id')).toBe('12');
  });
});

async function renderCappedFieldWorksheet(withAire = false) {
  vi.clearAllMocks();
  const employee = { id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: 'hourly', pay_rate: 15, pay_frequency: 'biweekly', status: 'active' } as Employee;
  const field = { id: 8, company_id: 7, name: '401(k) supplemental', kind: 'deduction', tax_treatment: 'pre_tax_deduction', category: 'retirement', amount_type: 'fixed', active: true, show_in_payroll_grid: true, sort_order: 0 };
  const assignment = { employee_id: 30, payroll_field_definition_id: 8, amount_type: 'fixed', current_amount: 0, requested_amount: 1070, suggested_amount: 0, overridden: true, editable: true };
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [field], assignments: [assignment], retained_manual_entries: [{ employee_id: 30, field_id: 9, label: 'Previous manual retirement', requested_amount: 1070, applied_amount: 93.04, source: 'manual' }] } });
  apiMocks.runPayroll.mockResolvedValue({ pay_period: { ...initialPayPeriod, status: 'calculated' }, results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } });
  const period = { ...initialPayPeriod, status: 'draft', ...(withAire ? { time_tracking: { active_source_types: ['aire_services'], linked_aire_records: [], aire_calendar: sourceCalendar } } : {}) } as unknown as PayPeriod;
  apiMocks.get.mockResolvedValue({ pay_period: period });
  function TokenHost() {
    const [refreshToken, setRefreshToken] = useState(0);
    const navigate = useNavigate();
    return <><button onClick={() => setRefreshToken(token => token + 1)}>Sibling checks changed</button>
      <button onClick={() => navigate('/companies/7/pay-runs/13/work')}>Other draft run</button>
      <PayPeriodDetail initialPayPeriod={period} refreshToken={refreshToken} /></>;
  }
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<TokenHost />} /></Routes></MemoryRouter>);
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

function approvedCommitView(refreshToken = 0, withAire = false) {
  apiMocks.employeesList.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  return <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes>
    <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={{ ...initialPayPeriod, status: 'approved', ...(withAire ? { time_tracking: { active_source_types: ['aire_services'], linked_aire_records: [], aire_calendar: sourceCalendar } } : {}) } as PayPeriod} refreshToken={refreshToken} />} />
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

it('settles a commit after a same-run sibling refresh and reloads the committed run', async () => {
  vi.clearAllMocks();
  const approved = { ...initialPayPeriod, status: 'approved' as const };
  const committed = { ...initialPayPeriod, status: 'committed' as const };
  let finishCommit!: (response: { pay_period: PayPeriod }) => void;
  apiMocks.commit.mockReturnValue(new Promise(resolve => { finishCommit = resolve; }));
  apiMocks.get.mockResolvedValueOnce({ pay_period: approved }).mockResolvedValue({ pay_period: committed });
  const view = render(approvedCommitView());
  fireEvent.click(await screen.findByRole('button', { name: 'Commit & Finalize' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Confirm commit' }));
  view.rerender(approvedCommitView(1));
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledTimes(1));
  await act(async () => finishCommit({ pay_period: committed }));
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledTimes(2));
  expect(screen.queryByRole('button', { name: 'Commit & Finalize' })).toBeNull();
  expect(apiMocks.commit).toHaveBeenCalledExactlyOnceWith(12);
});
it('preserves a commit rejection after a same-run sibling refresh', async () => {
  vi.clearAllMocks();
  let rejectCommit!: (error: Error) => void;
  apiMocks.commit.mockReturnValue(new Promise((_resolve, reject) => { rejectCommit = reject; }));
  apiMocks.get.mockResolvedValue({ pay_period: { ...initialPayPeriod, status: 'approved' } });
  const view = render(approvedCommitView());
  fireEvent.click(await screen.findByRole('button', { name: 'Commit & Finalize' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Confirm commit' }));
  view.rerender(approvedCommitView(1));
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledTimes(1));
  await act(async () => rejectCommit(new Error('Commit rejected after sibling refresh')));
  expect(await screen.findByText('Commit rejected after sibling refresh')).toBeTruthy();
  expect(apiMocks.commit).toHaveBeenCalledExactlyOnceWith(12);
});

it.each(['success', 'error'])('ignores a previous-route commit %s after navigating to another run', async outcome => {
  vi.clearAllMocks(); approvedCommitView();
  let finishCommit!: (response: { pay_period: PayPeriod }) => void;
  let rejectCommit!: (error: Error) => void;
  apiMocks.commit.mockReturnValue(new Promise((resolve, reject) => { finishCommit = resolve; rejectCommit = reject; }));
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
  fireEvent.click(await screen.findByRole('button', { name: 'Confirm commit' }));
  fireEvent.click(screen.getByRole('button', { name: 'Other run' }));
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledExactlyOnceWith(13));
  await act(async () => {
    if (outcome === 'success') finishCommit({ pay_period: initialPayPeriod });
    else rejectCommit(new Error('Previous run failed'));
  });
  fireEvent.click(await screen.findByRole('button', { name: 'Commit & Finalize' }));
  expect(within(await screen.findByRole('dialog')).getByText('#13')).toBeTruthy();
  expect(screen.queryByText('Previous run failed')).toBeNull();
  expect(apiMocks.get).toHaveBeenCalledExactlyOnceWith(13);
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


it('invalidates every source panel without remounting or resetting payroll drafts', async () => {
  const field = await renderCappedFieldWorksheet(true) as HTMLInputElement;
  const card = await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  const regular = within(card).getByLabelText('Regular hours') as HTMLInputElement;
  const bonus = within(card).getByLabelText('Bonus this payroll for Ana Cruz') as HTMLInputElement;
  fireEvent.change(regular, { target: { value: '19' } });
  fireEvent.change(bonus, { target: { value: '77' } });
  fireEvent.change(field, { target: { value: '888' } });
  fireEvent.blur(field);
  const panels = ['source-cockpit-revision', 'source-holds-revision', 'source-reconciliation-revision']
    .map(id => screen.getByTestId(id));
  for (const [index, name] of ['Approve source time', 'Change source hold', 'Change source allocation', 'Refresh source calendar'].entries()) {
    await act(async () => fireEvent.click(screen.getByRole('button', { name })));
    await waitFor(() => panels.forEach(panel => expect(panel.getAttribute('data-revision')).toBe(String(index + 1))));
    if (index === 0) expect(apiMocks.get).not.toHaveBeenCalled();
    else await waitFor(() => expect(apiMocks.get).toHaveBeenCalledTimes(index));
    expect(regular.value).toBe('19');
    expect(bonus.value).toBe('77.00');
    expect(field.value).toBe('888.00');
    expect(screen.getByLabelText('401(k) supplemental')).toBe(field);
    panels.forEach((panel, panelIndex) => expect(screen.getByTestId(['source-cockpit-revision', 'source-holds-revision', 'source-reconciliation-revision'][panelIndex])).toBe(panel));
  }
});


async function editPayrollDrafts() {
  const field = await renderCappedFieldWorksheet(true) as HTMLInputElement;
  const card = await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  const regular = within(card).getByLabelText('Regular hours') as HTMLInputElement;
  const bonus = within(card).getByLabelText('Bonus this payroll for Ana Cruz') as HTMLInputElement;
  fireEvent.change(regular, { target: { value: '19' } });
  fireEvent.change(bonus, { target: { value: '77' } });
  fireEvent.change(field, { target: { value: '888' } });
  fireEvent.blur(field);
  return { field, regular, bonus };
}

it('preserves dirty hours, bonus edits and worksheet requests when the parent check token changes', async () => {
  const { field, regular, bonus } = await editPayrollDrafts();
  const period = { ...initialPayPeriod, status: 'draft', notes: 'Latest sibling check metadata', time_tracking: { active_source_types: ['aire_services'], linked_aire_records: [], aire_calendar: sourceCalendar } } as unknown as PayPeriod;
  apiMocks.get.mockResolvedValue({ pay_period: period });
  fireEvent.click(screen.getByRole('button', { name: 'Sibling checks changed' }));
  await screen.findByText('Latest sibling check metadata');
  expect(regular.value).toBe('19');
  expect(bonus.value).toBe('77.00');
  expect(field.value).toBe('888.00');
  expect(screen.getByTestId('source-cockpit-revision').getAttribute('data-revision')).toBe('1');
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].hours['30']).toEqual(expect.objectContaining({ regular: 19 }));
  expect(apiMocks.runPayroll.mock.calls[0][1].bonuses).toEqual({ '30': 77 });
  expect(apiMocks.runPayroll.mock.calls[0][1].payroll_field_inputs['30']['8']).toEqual({ mode: 'override', amount: 888, replace_request: true });
});

it.each(['import', 'calculation', 'navigation'])('still applies canonical inputs after explicit %s following a passive refresh', async (action) => {
  await editPayrollDrafts();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Sibling checks changed' })));
  const worksheet = (await apiMocks.payrollFieldInputs.mock.results[0].value).payroll_field_inputs;
  const canonical = { ...initialPayPeriod, id: action === 'navigation' ? 13 : 12, status: 'draft', payroll_items: [{ id: 90, employee_id: 30, employment_type: 'hourly', pay_rate: 15, hours_worked: 26, overtime_hours: 0, bonus: 12, gross_pay: 402, net_pay: 380 }] } as unknown as PayPeriod;
  apiMocks.get.mockResolvedValue({ pay_period: canonical });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { ...worksheet, assignments: worksheet.assignments.map((assignment: { requested_amount: number }) => ({ ...assignment, requested_amount: 250 })) } });
  if (action === 'import') {
    fireEvent.click(screen.getByRole('button', { name: 'Import Time Tracking' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Complete explicit time import' }));
  } else if (action === 'calculation') {
    apiMocks.runPayroll.mockResolvedValue({ pay_period: { ...canonical, status: 'calculated' }, results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } });
    fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  } else {
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Sibling checks changed' }));
      fireEvent.click(screen.getByRole('button', { name: 'Other draft run' }));
    });
    await waitFor(() => expect(apiMocks.get).toHaveBeenCalledWith(13));
  }
  await waitFor(() => expect(screen.getByLabelText('401(k) supplemental')).toHaveProperty('value', '250.00'));
  const card = screen.getByRole('region', { name: 'Payroll entry for Ana Cruz' });
  expect(within(card).getByLabelText('Regular hours')).toHaveProperty('value', '26');
  expect(within(card).getByLabelText('Bonus this payroll for Ana Cruz')).toHaveProperty('value', '12.00');
});

it('initializes worksheet inputs when a parent token supersedes the first pending load', async () => {
  let resolveOld!: (value: { data: Employee[]; meta: { total_pages: number } }) => void;
  apiMocks.employeesList.mockImplementationOnce(() => new Promise(resolve => { resolveOld = resolve; }));
  const ready = renderCappedFieldWorksheet();
  await waitFor(() => expect(apiMocks.employeesList).toHaveBeenCalledTimes(1));
  fireEvent.click(screen.getByRole('button', { name: 'Sibling checks changed' }));
  const field = await ready;
  expect(field).toHaveProperty('value', '1070.00');
  await act(async () => resolveOld({ data: [], meta: { total_pages: 1 } }));
  expect(screen.getByLabelText('401(k) supplemental')).toBe(field);
});


it('owns calendar refresh completion while keeping all dirty payroll inputs', async () => {
  const { field, regular, bonus } = await editPayrollDrafts();
  let finishReload!: (value: { pay_period: PayPeriod }) => void;
  apiMocks.get.mockReturnValueOnce(new Promise(resolve => { finishReload = resolve; }));
  fireEvent.click(screen.getByRole('button', { name: 'Refresh source calendar' }));
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledExactlyOnceWith(12));
  expect(componentMocks.calendarRefreshCompleted).not.toHaveBeenCalled();
  const updated = { ...initialPayPeriod, status: 'draft', notes: 'Delivered calendar metadata',
    time_tracking: { active_source_types: ['aire_services'], linked_aire_records: [], aire_calendar: sourceCalendar } } as unknown as PayPeriod;
  await act(async () => finishReload({ pay_period: updated }));
  await screen.findByText('Delivered calendar metadata');
  expect(componentMocks.calendarRefreshCompleted).toHaveBeenCalledExactlyOnceWith(true);
  expect(regular.value).toBe('19');
  expect(bonus.value).toBe('77.00');
  expect(field.value).toBe('888.00');
  expect(apiMocks.runPayroll).not.toHaveBeenCalled();
  expect(apiMocks.commit).not.toHaveBeenCalled();
});


it.each(['import', 'calculation'])('explicitly refreshes every source panel after canonical %s with an unchanged calendar event', async action => {
  await editPayrollDrafts();
  apiMocks.runPayroll.mockResolvedValue({ pay_period: { ...initialPayPeriod, status: 'calculated', time_tracking: { active_source_types: ['aire_services'], linked_aire_records: [], aire_calendar: sourceCalendar } } as PayPeriod, results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } });
  expect(screen.getByTestId('source-cockpit-revision').getAttribute('data-revision')).toBe('0');
  if (action === 'import') {
    fireEvent.click(screen.getByRole('button', { name: 'Import Time Tracking' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Complete explicit time import' }));
  } else {
    fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  }
  await waitFor(() => {
    for (const id of ['source-cockpit-revision', 'source-holds-revision', 'source-reconciliation-revision']) {
      expect(screen.getByTestId(id).getAttribute('data-revision')).toBe('1');
    }
  });
  expect(apiMocks.commit).not.toHaveBeenCalled();
  expect(apiMocks.runPayroll).toHaveBeenCalledTimes(action === 'calculation' ? 1 : 0);
});

it('refreshes committed source receipt and history panels once after the canonical commit reload', async () => {
  vi.clearAllMocks();
  const committed = { ...initialPayPeriod, time_tracking: { active_source_types: ['aire_services'], linked_aire_records: [],
    aire_calendar: sourceCalendar } } as PayPeriod;
  apiMocks.commit.mockResolvedValue({ pay_period: committed });
  apiMocks.get.mockResolvedValue({ pay_period: committed });
  render(approvedCommitView(0, true));
  fireEvent.click(await screen.findByRole('button', { name: 'Commit & Finalize' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Confirm commit' }));
  await waitFor(() => {
    for (const id of ['source-cockpit-revision', 'source-holds-revision', 'source-reconciliation-revision']) {
      expect(screen.getByTestId(id).getAttribute('data-revision')).toBe('1');
    }
  });
  expect(apiMocks.commit).toHaveBeenCalledExactlyOnceWith(12);
  expect(apiMocks.get).toHaveBeenCalledExactlyOnceWith(12);
});


it('refreshes accounting correction metadata and every source panel while preserving typed payroll drafts', async () => {
  const { field, regular, bonus } = await editPayrollDrafts();
  apiMocks.get.mockResolvedValue({ pay_period: { ...initialPayPeriod, status: 'draft', notes: 'Accounting correction metadata refreshed',
    time_tracking: { active_source_types: ['aire_services'], linked_aire_records: [], aire_calendar: sourceCalendar } } });
  fireEvent.click(screen.getByRole('button', { name: 'Import Time Tracking' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Record accounting correction' }));
  await screen.findByText('Accounting correction metadata refreshed');
  expect(screen.getByTestId('source-cockpit-revision').getAttribute('data-revision')).toBe('1');
  expect(screen.getByTestId('source-holds-revision').getAttribute('data-revision')).toBe('1');
  expect(screen.getByTestId('source-reconciliation-revision').getAttribute('data-revision')).toBe('1');
  expect(regular.value).toBe('19');
  expect(bonus.value).toBe('77.00');
  expect(field.value).toBe('888.00');
  expect(screen.getByLabelText('401(k) supplemental')).toBe(field);
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].hours['30']).toEqual(expect.objectContaining({ regular: 19 }));
  expect(apiMocks.runPayroll.mock.calls[0][1].bonuses).toEqual({ '30': 77 });
  expect(apiMocks.runPayroll.mock.calls[0][1].payroll_field_inputs['30']['8']).toEqual({ mode: 'override', amount: 888, replace_request: true });
});

async function renderLoanWorksheet(status: 'draft' | 'calculated' | 'approved' = 'calculated', comparisonResponse?: unknown, loanPayment = 0, rates?: { profile: number; saved: number }, standaloneAmount = 0, namedAmount = 0, namedRequest?: number) {
  vi.clearAllMocks();
  const employee = { id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: 'hourly', pay_rate: rates?.profile ?? 16, pay_frequency: 'semimonthly', status: 'active' } as Employee;
  const other = { ...employee, id: 31, first_name: 'Other' } as Employee;
  const item = { id: 1, employee_id: 30, employment_type: 'hourly', pay_rate: rates?.saved ?? 16, hours_worked: rates ? 4 : 80.3, overtime_hours: rates ? 0 : 14, gross_pay: rates ? 100 : 1620.8, net_pay: 1393.15 - loanPayment, loan_deduction: standaloneAmount, loan_payment: loanPayment };
  const period = { ...initialPayPeriod, status, run_purpose: 'correction', includes_recurring_items: false, includes_base_salary: false, payroll_items: [item], ...(comparisonResponse ? { cycle: 'regular' } : {}) } as unknown as PayPeriod;
  const options = [{ employee_id: 30, loan_id: 2, name: 'Employee Loan', tracking_mode: 'balance_tracked', current_balance: 3259.97, scheduled_amount: 300, current_amount: namedAmount, eligible: true, mode: namedRequest === undefined ? 'default' : 'override', requested_amount: namedRequest }];
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

it.each(['payroll', 'employees'])('hides stale approved controls when setup changes but the canonical %s reload fails', async failedRead => {
  await renderLoanWorksheet('approved');
  if (failedRead === 'payroll') apiMocks.get.mockRejectedValueOnce(new Error('Payroll read unavailable'));
  else apiMocks.employeesList.mockRejectedValueOnce(new Error('Employee read unavailable'));
  fireEvent.click(screen.getByRole('button', { name: 'Refresh current setup' }));
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Refresh and recalculate' }));
  expect(await screen.findByText(/Setup changed, but the updated payroll could not load/)).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Commit' })).toBeNull();
  expect(screen.queryByText(/Current setup applied to the saved employees/)).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  expect(await screen.findByRole('button', { name: 'Recalculate' })).toBeTruthy();
  expect(apiMocks.refreshSetup).toHaveBeenCalledTimes(1);
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


it('labels the saved loan total as loan deductions while keeping standalone entry distinct', async () => {
  await renderLoanWorksheet('calculated', undefined, 300);
  const header = screen.getByRole('columnheader', { name: 'Loan deductions' });
  expect(header.title).toBe('Calculated total of linked loan repayments and any standalone loan deduction.');
  expect(screen.queryByRole('columnheader', { name: 'Standalone deduction' })).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: '+ Tips & Deductions' }));
  expect(await screen.findByRole('columnheader', { name: 'Standalone deduction' })).toBeTruthy();
});


it('clears a previous refresh success while a new request is pending and keeps a rejection in context', async () => {
  await renderLoanWorksheet('approved');
  fireEvent.click(screen.getByRole('button', { name: 'Refresh current setup' }));
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Refresh and recalculate' }));
  await screen.findByText(/Current setup applied to the saved employees and inputs/);
  let reject!: (error: Error) => void;
  apiMocks.refreshSetup.mockImplementationOnce(() => new Promise((_resolve, failure) => { reject = failure; }));
  fireEvent.click(screen.getByRole('button', { name: 'Refresh current setup' }));
  const dialog = screen.getByRole('dialog');
  fireEvent.click(within(dialog).getByLabelText('Include recurring employee setup'));
  fireEvent.click(within(dialog).getByRole('button', { name: 'Refresh and recalculate' }));
  expect(screen.queryByText(/Current setup applied to the saved employees and inputs/)).toBeNull();
  expect((within(dialog).getByRole('button', { name: 'Refreshing…' }) as HTMLButtonElement).disabled).toBe(true);
  expect(apiMocks.refreshSetup).toHaveBeenLastCalledWith(12, { includes_recurring_items: true, includes_base_salary: false });
  await act(async () => reject(new Error('The saved setup changed; review it again.')));
  expect(await within(dialog).findByText('The saved setup changed; review it again.')).toBeTruthy();
  expect(screen.queryByText(/Current setup applied to the saved employees and inputs/)).toBeNull();
  const card = screen.getByRole('region', { name: 'Payroll entry for Ana Cruz' });
  expect((within(card).getByLabelText('Regular hours') as HTMLInputElement).value).toBe('80.3');
  expect(screen.queryByRole('region', { name: 'Payroll entry for Other Cruz' })).toBeNull();
  expect(apiMocks.commit).not.toHaveBeenCalled();
});

it('reports partial setup refresh errors without claiming success or expanding the saved roster', async () => {
  await renderLoanWorksheet('approved');
  apiMocks.refreshSetup.mockResolvedValueOnce({ results: { success: [], skipped: [], errors: [{ employee_id: 30, error: 'Current tax setup needs review.' }] } });
  fireEvent.click(screen.getByRole('button', { name: 'Refresh current setup' }));
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Refresh and recalculate' }));
  expect(await screen.findByText('1 employee needs attention after refreshing setup.')).toBeTruthy();
  expect(screen.getByText('Current tax setup needs review.')).toBeTruthy();
  expect(screen.queryByText(/Current setup applied to the saved employees and inputs/)).toBeNull();
  expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.queryByRole('region', { name: 'Payroll entry for Other Cruz' })).toBeNull();
});

it('clears previous employee refresh failures before the next deferred request', async () => {
  await renderLoanWorksheet('approved');
  apiMocks.refreshSetup.mockResolvedValueOnce({ results: { success: [], skipped: [], errors: [{ employee_id: 30, error: 'Old setup outcome.' }] } });
  fireEvent.click(screen.getByRole('button', { name: 'Refresh current setup' }));
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Refresh and recalculate' }));
  await screen.findByText('Old setup outcome.');
  let resolve!: (value: unknown) => void;
  apiMocks.refreshSetup.mockImplementationOnce(() => new Promise(success => { resolve = success; }));
  fireEvent.click(screen.getByRole('button', { name: 'Refresh current setup' }));
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Refresh and recalculate' }));
  expect(screen.queryByText('Old setup outcome.')).toBeNull();
  expect(screen.queryByRole('heading', { name: 'Resolve these employees before approval' })).toBeNull();
  await act(async () => resolve({ results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } }));
  expect(await screen.findByText(/Current setup applied to the saved employees and inputs/)).toBeTruthy();
  expect(screen.queryByText('Old setup outcome.')).toBeNull();
});


it.each([
  ['mobile', 'calculated'], ['desktop', 'calculated'], ['mobile', 'draft'], ['desktop', 'draft'],
] as const)('shows the appropriate saved or current rate in the %s %s worksheet', async (surface, status) => {
  await renderLoanWorksheet(status, undefined, 0, { profile: 27, saved: 25 });
  const entry = surface === 'mobile'
    ? screen.getByRole('region', { name: 'Payroll entry for Ana Cruz' })
    : screen.getAllByRole('row').find(row => within(row).queryByRole('link', { name: 'Ana Cruz' }))!;
  const expected = status === 'calculated' ? '$25.00/hr' : '$27.00/hr';
  const other = status === 'calculated' ? '$27.00/hr' : '$25.00/hr';
  expect(within(entry).getByText(expected)).toBeTruthy();
  expect(within(entry).queryByText(other)).toBeNull();
  expect(apiMocks.runPayroll).not.toHaveBeenCalled();
  expect(apiMocks.refreshSetup).not.toHaveBeenCalled();
});


const correctionOriginal = { ...initialPayPeriod, payroll_items: [{ id: 1, employee_id: 30, employee_name: 'Ana Cruz', employment_type: 'hourly', pay_rate: 25, hours_worked: 4, overtime_hours: 0, gross_pay: 100, net_pay: 77.35, voided: false }],
  time_tracking: { active_source_types: ['aire_services'], linked_aire_records: [], aire_calendar: sourceCalendar } } as unknown as PayPeriod;
const correctionCanonical = { ...correctionOriginal, notes: 'Canonical voided instruments and history', correction_status: 'voided',
  payroll_items: correctionOriginal.payroll_items!.map(item => ({ ...item, voided: true })) } as PayPeriod;

async function renderCorrectionRefresh() {
  vi.clearAllMocks();
  apiMocks.get.mockResolvedValue({ pay_period: correctionCanonical });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: { status: 'posted', postings: [{}] } });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  apiMocks.employeesList.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
  function Page() {
    const navigate = useNavigate();
    return <><button onClick={() => navigate('/companies/7/pay-runs/13/work')}>Other run</button>
      <button onClick={() => navigate('/companies/8/pay-runs/12/work')}>Other company</button>
      <PayPeriodDetail initialPayPeriod={correctionOriginal} /></>;
  }
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<Page />} /></Routes></MemoryRouter>);
  await screen.findByRole('button', { name: 'Finish correction' });
}

it('reloads saved instruments, journal liabilities and source history after a partial correction response', async () => {
  await renderCorrectionRefresh();
  expect(screen.getByTestId('saved-instrument-state').textContent).toBe('Assigned');
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: { status: 'reversed', postings: [{}, {}] } });
  let resolve!: (value: { pay_period: PayPeriod }) => void;
  apiMocks.get.mockImplementationOnce(() => new Promise(success => { resolve = success; }));
  fireEvent.click(screen.getByRole('button', { name: 'Finish correction' }));
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledExactlyOnceWith(12));
  expect(screen.getByText('Voided', { selector: 'span' })).toBeTruthy();
  await act(async () => resolve({ pay_period: correctionCanonical }));
  expect(await screen.findByText('Canonical voided instruments and history')).toBeTruthy();
  expect(screen.getByTestId('saved-instrument-state').textContent).toBe('Voided');
  expect(screen.getByTestId('saved-liability-state').textContent).toBe('reversed:2');
  expect(screen.getByTestId('processing-check-list-refresh-token').textContent).toBe('1');
  for (const id of ['source-cockpit-revision', 'source-holds-revision', 'source-reconciliation-revision']) {
    expect(screen.getByTestId(id).getAttribute('data-revision')).toBe('1');
  }
  expect(apiMocks.commit).not.toHaveBeenCalled();
});

it.each(['Other run', 'Other company'])('ignores a late correction response after switching to %s', async label => {
  await renderCorrectionRefresh();
  const oldCallback = componentMocks.correctionCallback.mock.calls.at(-1)![0] as (updated: PayPeriod) => void;
  const other = { ...correctionOriginal, id: label === 'Other run' ? 13 : 12, company_id: label === 'Other company' ? 8 : 7, notes: 'Different active scope' };
  apiMocks.get.mockResolvedValue({ pay_period: other });
  fireEvent.click(screen.getByRole('button', { name: label }));
  await screen.findByText('Different active scope');
  const calls = apiMocks.get.mock.calls.length;
  act(() => oldCallback(correctionCanonical));
  expect(apiMocks.get.mock.calls.length).toBe(calls);
  expect(screen.getByText('Different active scope')).toBeTruthy();
  expect(screen.queryByText('Canonical voided instruments and history')).toBeNull();
});

it('does not apply a pending correction reload after navigating to another run', async () => {
  await renderCorrectionRefresh();
  let resolve!: (value: { pay_period: PayPeriod }) => void;
  apiMocks.get.mockImplementationOnce(() => new Promise(success => { resolve = success; }));
  fireEvent.click(screen.getByRole('button', { name: 'Finish correction' }));
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledWith(12));
  apiMocks.get.mockResolvedValue({ pay_period: { ...correctionOriginal, id: 13, notes: 'New run remains current' } });
  fireEvent.click(screen.getByRole('button', { name: 'Other run' }));
  await screen.findByText('New run remains current');
  await act(async () => resolve({ pay_period: correctionCanonical }));
  expect(screen.getByText('New run remains current')).toBeTruthy();
  expect(screen.queryByText('Canonical voided instruments and history')).toBeNull();
});


async function renderRefreshNavigation() {
  vi.clearAllMocks();
  const original = { ...correctionOriginal, status: 'approved' as const };
  apiMocks.get.mockResolvedValue({ pay_period: { ...original, id: 13, notes: 'New active refresh scope' } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  apiMocks.employeesList.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
  function Page() {
    const navigate = useNavigate();
    const [refreshToken, setRefreshToken] = useState(0);
    return <><button onClick={() => setRefreshToken(token => token + 1)}>Sibling refresh</button>
      <button onClick={() => navigate('/companies/7/pay-runs/13/work')}>Next refresh run</button>
      <button onClick={() => navigate('/companies/8/pay-runs/12/work')}>Next refresh company</button>
      <PayPeriodDetail initialPayPeriod={original} refreshToken={refreshToken} /></>;
  }
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<Page />} /></Routes></MemoryRouter>);
  await screen.findByRole('button', { name: 'Refresh current setup' });
  return original;
}

function submitRefreshNavigation() {
  fireEvent.click(screen.getByRole('button', { name: 'Refresh current setup' }));
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Refresh and recalculate' }));
}

it.each(['run', 'company'])('does not reload the old run or clear a new busy refresh after a deferred POST and %s navigation', async scope => {
  const original = await renderRefreshNavigation();
  let finishOld!: (value: unknown) => void;
  let finishNew!: (value: unknown) => void;
  apiMocks.refreshSetup.mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve; }))
    .mockImplementationOnce(() => new Promise(resolve => { finishNew = resolve; }));
  submitRefreshNavigation();
  const next = { ...original, id: scope === 'run' ? 13 : 12, company_id: scope === 'company' ? 8 : 7, notes: 'New active refresh scope' };
  apiMocks.get.mockResolvedValue({ pay_period: next });
  fireEvent.click(screen.getByRole('button', { name: scope === 'run' ? 'Next refresh run' : 'Next refresh company' }));
  await screen.findByText('New active refresh scope');
  expect(screen.queryByRole('dialog')).toBeNull();
  expect((screen.getByRole('button', { name: 'Refresh current setup' }) as HTMLButtonElement).disabled).toBe(false);
  submitRefreshNavigation();
  const calls = apiMocks.get.mock.calls.length;
  await act(async () => finishOld({ results: { success: [], skipped: [], errors: [{ employee_id: 30, error: 'Old run failure must stay behind.' }] } }));
  expect(apiMocks.get.mock.calls.length).toBe(calls);
  expect(screen.queryByText('Old run failure must stay behind.')).toBeNull();
  expect(screen.getByText('New active refresh scope')).toBeTruthy();
  expect((within(screen.getByRole('dialog')).getByRole('button', { name: 'Refreshing…' }) as HTMLButtonElement).disabled).toBe(true);
  await act(async () => finishNew({ results: { success: [], skipped: [], errors: [] } }));
  await screen.findByText(/Current setup applied to the saved employees and inputs/);
});

it('does not add old refresh outcome feedback after its deferred canonical GET and navigation', async () => {
  const original = await renderRefreshNavigation();
  let finishGet!: (value: { pay_period: PayPeriod }) => void;
  apiMocks.refreshSetup.mockResolvedValue({ results: { success: [], skipped: [], errors: [{ employee_id: 30, error: 'Prior run reload error.' }] } });
  apiMocks.get.mockImplementationOnce(() => new Promise(resolve => { finishGet = resolve; }));
  submitRefreshNavigation();
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledWith(12));
  apiMocks.get.mockResolvedValue({ pay_period: { ...original, id: 13, notes: 'New active refresh scope' } });
  fireEvent.click(screen.getByRole('button', { name: 'Next refresh run' }));
  await screen.findByText('New active refresh scope');
  await act(async () => finishGet({ pay_period: { ...original, notes: 'Old canonical refresh result' } }));
  expect(screen.getByText('New active refresh scope')).toBeTruthy();
  expect(screen.queryByText('Prior run reload error.')).toBeNull();
  expect(screen.queryByText('1 employee needs attention after refreshing setup.')).toBeNull();
  expect(screen.queryByText('Old canonical refresh result')).toBeNull();
});

it('keeps a late refresh POST rejection out of the new run', async () => {
  await renderRefreshNavigation();
  let reject!: (error: Error) => void;
  apiMocks.refreshSetup.mockImplementationOnce(() => new Promise((_resolve, failure) => { reject = failure; }));
  submitRefreshNavigation();
  fireEvent.click(screen.getByRole('button', { name: 'Next refresh run' }));
  await screen.findByText('New active refresh scope');
  await act(async () => reject(new Error('Old refresh request was rejected.')));
  expect(screen.queryByText('Old refresh request was rejected.')).toBeNull();
  expect(screen.getByText('New active refresh scope')).toBeTruthy();
});

it('allows approval with a calculated linked payment and an unrelated standalone deduction', async () => {
  await renderLoanWorksheet('calculated', undefined, 340, undefined, 40, 300);
  expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(false);
});

it('allows a separate standalone deduction when the named repayment is explicitly skipped', async () => {
  await renderLoanWorksheet('calculated', undefined, 40, undefined, 40, 0, 0);
  expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(false);
});

it('blocks approval when a standalone deduction has replaced the due named repayment', async () => {
  await renderLoanWorksheet('calculated', undefined, 40, undefined, 40);
  expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true);
});

it('keeps a missing linked repayment warning after unrelated edits to a saved positive override', async () => {
  const card = await renderLoanWorksheet('calculated', undefined, 40, undefined, 40, 0, 300);
  expect(screen.getByText(/Clear the standalone one-time deduction/)).toBeTruthy();
  fireEvent.change(within(card!).getByLabelText('Regular hours'), { target: { value: '81' } });
  expect(screen.getByText(/Clear the standalone one-time deduction/)).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(within(card!).getByLabelText('Employee Loan repayment amount'), { target: { value: '200' } });
  expect(screen.queryByText(/Clear the standalone one-time deduction/)).toBeNull();
  expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true);
});

it('saves both named and standalone amounts through worksheet recalculation', async () => {
  await renderLoanWorksheet('calculated', undefined, 340, undefined, 40, 300, 300);
  fireEvent.click(screen.getByRole('button', { name: 'Recalculate' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalled());
  expect(apiMocks.runPayroll.mock.calls[0][1].named_loan_payments).toEqual({ '30': { '2': { mode: 'override', amount: 300 } } });
  expect(apiMocks.runPayroll.mock.calls[0][1].loan_deductions).toEqual({ '30': 40 });
});

it('updates the separate-deduction warning for a staged zero skip while requiring recalculation', async () => {
  const card = await renderLoanWorksheet('calculated', undefined, 40, undefined, 40);
  expect(screen.getByText(/Clear the standalone one-time deduction/)).toBeTruthy();
  fireEvent.change(within(card!).getByLabelText('Employee Loan repayment choice'), { target: { value: 'override' } });
  fireEvent.change(within(card!).getByLabelText('Employee Loan repayment amount'), { target: { value: '0' } });
  fireEvent.change(within(card!).getByLabelText('Standalone one-time deduction'), { target: { value: '40' } });
  expect(screen.queryByText(/Clear the standalone one-time deduction/)).toBeNull();
  expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true);
});

it('accepts a staged positive linked request alongside a separate amount without warning to clear it', async () => {
  const card = await renderLoanWorksheet('calculated', undefined, 40, undefined, 40);
  fireEvent.change(within(card!).getByLabelText('Employee Loan repayment choice'), { target: { value: 'override' } });
  fireEvent.change(within(card!).getByLabelText('Standalone one-time deduction'), { target: { value: '40' } });
  expect(screen.queryByText(/Clear the standalone one-time deduction/)).toBeNull();
  expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true);
});

it.each(['mobile', 'desktop'])('retains both imported earning buckets and captured rates on the %s worksheet and calculate request', async surface => {
  vi.clearAllMocks();
  const employee = { id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: 'hourly', pay_rate: 99, pay_frequency: 'semimonthly', status: 'active', wage_rates: [{ id: 1, label: 'Current profile', rate: 99, is_primary: true, active: true }] } as unknown as Employee;
  const buckets = [
    { employee_wage_rate_id: 1, source_bucket_key: 'carry', label: 'Carryover Oct10', rate: 10, regular_hours: 4, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, is_primary: true, active: true },
    { employee_wage_rate_id: 1, source_bucket_key: 'current', label: 'Current Oct20', rate: 25, regular_hours: 2, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, is_primary: false, active: true },
  ];
  const item = { id: 1, employee_id: 30, employment_type: 'hourly', pay_rate: 25, hours_worked: 6, overtime_hours: 0, gross_pay: 90, net_pay: 83.11, import_source: 'time_tracking:custom:1:BATCH', wage_rate_hours: buckets };
  const period = { ...initialPayPeriod, status: 'draft', run_purpose: 'adjustment', includes_recurring_items: false, includes_base_salary: false, payroll_items: [item] } as unknown as PayPeriod;
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  apiMocks.runPayroll.mockResolvedValue({ pay_period: { ...period, status: 'calculated' }, results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } });
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={period} />} /></Routes></MemoryRouter>);
  await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  const entry = surface === 'mobile' ? screen.getByRole('region', { name: 'Payroll entry for Ana Cruz' }) : screen.getAllByRole('row').find(row => within(row).queryByRole('link', { name: 'Ana Cruz' }))!;
  expect(within(entry).getAllByText(/Carryover Oct10/).length).toBeGreaterThan(0);
  expect(within(entry).getAllByText(/Current Oct20/).length).toBeGreaterThan(0);
  expect(within(entry).queryByText('$99.00/hr')).toBeNull();
  const hourInputs = within(entry).getAllByRole('textbox').filter(input => ['4', '2'].includes((input as HTMLInputElement).value));
  expect(hourInputs.length).toBe(2);
  expect(hourInputs.every(input => (input as HTMLInputElement).disabled)).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalledTimes(1));
  expect(apiMocks.runPayroll.mock.calls[0][1].hours['30']).toEqual({ regular: 6, overtime: 0, wage_rates: buckets });
});

it.each(['mobile', 'desktop'])('calculates unchanged signed captured buckets and displays their recorded context on %s', async surface => {
  vi.clearAllMocks();
  const employee = { id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: 'hourly', pay_rate: 99, pay_frequency: 'biweekly', status: 'active' } as Employee;
  const buckets = [6, -1].map((hours, index) => ({ employee_wage_rate_id: 1, source_bucket_key: `bucket-${index}`, label: 'Regular', rate: 25,
    regular_hours: hours, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, is_primary: true, active: true,
    source_lines: [{ source_time_entry_id: `line-${index}`, line_key: 'REG', source_time_entry_version: 1,
      source_kind: index === 0 ? 'current' : 'correction', original_work_date: index === 0 ? '2026-10-20' : '2026-10-10', total_hours: hours, regular_hours: hours, overtime_hours: 0 }] }));
  const item = { id: 1, employee_id: 30, employment_type: 'hourly', pay_rate: 25, hours_worked: 5, overtime_hours: 0, gross_pay: 125, net_pay: 115.44,
    import_source: 'time_tracking:custom:1:BATCH', wage_rate_hours: buckets };
  const period = { ...initialPayPeriod, status: 'draft', run_purpose: 'adjustment', includes_recurring_items: false, includes_base_salary: false, payroll_items: [item] } as unknown as PayPeriod;
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  apiMocks.runPayroll.mockResolvedValue({ pay_period: { ...period, status: 'calculated' }, results: { success: [{ employee_id: 30 }], skipped: [], errors: [] } });
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={period} />} /></Routes></MemoryRouter>);
  await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  const entry = surface === 'mobile' ? screen.getByRole('region', { name: 'Payroll entry for Ana Cruz' }) : screen.getAllByRole('row').find(row => within(row).queryByRole('link', { name: 'Ana Cruz' }))!;
  expect(within(entry).getAllByText('Current work · Oct 20, 2026').length).toBeGreaterThan(0);
  expect(within(entry).getAllByText('Correction · Oct 10, 2026').length).toBeGreaterThan(0);
  const signedInput = within(entry).getAllByRole('textbox').find(input => (input as HTMLInputElement).value === '-1') as HTMLInputElement;
  expect(signedInput.disabled).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  await waitFor(() => expect(apiMocks.runPayroll).toHaveBeenCalledTimes(1));
  expect(apiMocks.runPayroll.mock.calls[0][1].hours['30']).toEqual({ regular: 5, overtime: 0, wage_rates: buckets });
  expect(screen.queryByText('Hours must be between 0 and 200 per period')).toBeNull();
});

it.each(['draft', 'calculated', 'committed'])('shows retained correction holds and saved amounts without current salary forecasts in %s', async status => {
  vi.clearAllMocks();
  const employee = { id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: 'salary', salary_type: 'annual', pay_rate: 52000, pay_frequency: 'semimonthly', status: 'active' } as Employee;
  const reason = 'Review original payroll evidence: retained hourly pay basis differs from current salary setup.';
  const item = { id: 1, employee_id: 30, employee_name: 'Ana Cruz', employment_type: 'hourly', pay_rate: 25, hours_worked: 3, overtime_hours: 0,
    gross_pay: 75, net_pay: 69.26, timekeeping_source: 'correction_reference', correction_pay_basis_hold: { reason } };
  const period = { ...initialPayPeriod, status, run_purpose: 'correction', includes_base_salary: true, includes_recurring_items: false, payroll_items: [item] } as unknown as PayPeriod;
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={period} />} /></Routes></MemoryRouter>);
  await screen.findByText('Saved gross pay');
  await waitFor(() => expect(screen.getAllByText(text => text.includes(reason)).length).toBeGreaterThan(0));
  expect(screen.queryByText('$1.04/period')).toBeNull();
  expect(screen.queryByText('$2,166.67/period')).toBeNull();
  expect(screen.getAllByText('$75.00').length).toBeGreaterThan(0);
  if (status !== 'committed') {
    const mobile = await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
    expect(within(mobile).getByText(reason)).toBeTruthy();
    const row = screen.getAllByRole('row').find(row => within(row).queryByRole('link', { name: 'Ana Cruz' }) && within(row).queryByText(reason))!;
    expect(within(row).getByText('Retained pay basis · review required')).toBeTruthy();
    const calculate = screen.getByRole('button', { name: status === 'draft' ? 'Calculate Payroll' : 'Recalculate' }) as HTMLButtonElement;
    expect(calculate.disabled).toBe(true);
    fireEvent.click(calculate);
    expect(apiMocks.runPayroll).not.toHaveBeenCalled();
    if (status === 'calculated') expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true);
  } else {
    expect(screen.getAllByRole('link', { name: 'View details' }).length).toBeGreaterThan(0);
    expect(screen.queryByRole('button', { name: 'Recalculate' })).toBeNull();
  }
});

it.each(['changed basis', 'missing legacy buckets'])('holds imported %s without synthesizing profile rates or new salary forecasts', async shape => {
  vi.clearAllMocks();
  const employee = { id: 30, company_id: 7, first_name: 'Ana', last_name: 'Cruz', employment_type: shape === 'changed basis' ? 'salary' : 'hourly',
    salary_type: 'annual', pay_rate: shape === 'changed basis' ? 52000 : 99, pay_frequency: 'semimonthly', status: 'active',
    wage_rates: [{ id: 1, label: 'Current primary profile', rate: 99, is_primary: true, active: true },
      { id: 2, label: 'Current secondary profile', rate: 150, is_primary: false, active: true }] } as unknown as Employee;
  const item = { id: 1, employee_id: 30, employment_type: 'hourly', pay_rate: 25, hours_worked: 3, overtime_hours: 0, gross_pay: 75, net_pay: 69.26,
    import_source: 'time_tracking:custom:1:BATCH', wage_rate_hours: shape === 'changed basis' ? [{ employee_wage_rate_id: 1, label: 'Retained regular', rate: 25,
      source_bucket_key: 'retained', regular_hours: 3, overtime_hours: 0, holiday_hours: 0, pto_hours: 0 }] : [] };
  const period = { ...initialPayPeriod, status: 'draft', run_purpose: 'adjustment', includes_base_salary: true, includes_recurring_items: false, payroll_items: [item] } as unknown as PayPeriod;
  apiMocks.employeesList.mockResolvedValue({ data: [employee], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={period} />} /></Routes></MemoryRouter>);
  const mobile = await screen.findByRole('region', { name: 'Payroll entry for Ana Cruz' });
  expect(within(mobile).getByText('Retained pay basis · review required')).toBeTruthy();
  const reason = shape === 'changed basis' ? /Retained Source pay basis differs/ : /Retained Source earning evidence is unavailable/;
  expect(within(mobile).getByText(reason)).toBeTruthy();
  const row = screen.getAllByRole('row').find(candidate => within(candidate).queryByRole('link', { name: 'Ana Cruz' }))!;
  expect(within(row).getByText(reason)).toBeTruthy();
  expect(within(row).getByText('$75.00')).toBeTruthy();
  expect(screen.queryByText('$1.04/period')).toBeNull();
  expect(screen.queryByText('Current primary profile')).toBeNull();
  expect(screen.queryByText('Current secondary profile')).toBeNull();
  expect((screen.getByRole('button', { name: 'Calculate Payroll' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: 'Calculate Payroll' }));
  expect(apiMocks.runPayroll).not.toHaveBeenCalled();
});

it.each(['resolve', 'reject'])('retains a newer same-run reload when the setup GET is superseded then %s', async completion => {
  const original = await renderRefreshNavigation();
  let finish!: (value: { pay_period: PayPeriod }) => void;
  let reject!: (error: Error) => void;
  apiMocks.refreshSetup.mockResolvedValue({ results: { success: [], skipped: [], errors: [] } });
  apiMocks.get.mockImplementationOnce(() => new Promise((resolve, failure) => { finish = resolve; reject = failure; }));
  submitRefreshNavigation();
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledWith(12));
  apiMocks.get.mockResolvedValue({ pay_period: { ...original, status: 'calculated', notes: 'Latest same-run payroll' } });
  fireEvent.click(screen.getByRole('button', { name: 'Sibling refresh' }));
  await screen.findByText('Latest same-run payroll');
  await act(async () => completion === 'resolve'
    ? finish({ pay_period: { ...original, notes: 'Old canonical setup' } })
    : reject(new Error('Old setup GET failed')));
  expect(screen.getByText('Latest same-run payroll')).toBeTruthy();
  expect(screen.queryByText(/Setup changed, but the updated payroll could not load/)).toBeNull();
  expect(screen.queryByText(/Current setup applied to the saved employees/)).toBeNull();
  expect(screen.queryByText('Old setup GET failed')).toBeNull();
});

it('rejects the saved-payment callback when the current canonical reload fails', async () => {
  await renderRefreshNavigation();
  apiMocks.get.mockRejectedValueOnce(new Error('Saved method read failed'));
  const callback = componentMocks.paymentMethodSaved.mock.calls.at(-1)![0] as () => Promise<void>;
  await act(async () => { await expect(callback()).rejects.toThrow('Saved payment method could not refresh.'); });
  expect(await screen.findByText('Saved method read failed')).toBeTruthy();
});

it('retains saved-import context, blocks stale approval/commit and retries canonical payroll without reapplying', async () => {
  const original = await renderRefreshNavigation();
  const callback = componentMocks.timeTrackingImport.mock.calls.at(-1)![0].onImportComplete as () => Promise<boolean>;
  apiMocks.get.mockRejectedValueOnce(new Error('Saved source payroll read unavailable'));
  await act(async () => { expect(await callback()).toBe(false); });
  expect(await screen.findByText(/Source hours were saved, but the current payroll could not load/)).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Commit & Finalize' }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.queryByRole('button', { name: 'Refresh current setup' })).toBeNull();
  expect(apiMocks.commit).not.toHaveBeenCalled();
  expect(apiMocks.runPayroll).not.toHaveBeenCalled();
  apiMocks.get.mockResolvedValue({ pay_period: { ...original, status: 'calculated', notes: 'Canonical saved source hours' } });
  fireEvent.click(screen.getByRole('button', { name: 'Reload saved payroll' }));
  await screen.findByText('Canonical saved source hours');
  expect(screen.queryByText(/Saved source hours need a current payroll reload before processing/)).toBeNull();
  expect(screen.queryByText(/Source hours were saved, but the current payroll could not load/)).toBeNull();
  expect((screen.getByRole('button', { name: 'Refresh current setup' }) as HTMLButtonElement).disabled).toBe(false);
  expect(apiMocks.commit).not.toHaveBeenCalled();
  expect(apiMocks.runPayroll).not.toHaveBeenCalled();
});

it('accepts a newer successful canonical read when the saved-import reload is superseded', async () => {
  const original = await renderRefreshNavigation();
  let finish!: (value: { pay_period: PayPeriod }) => void;
  apiMocks.get.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  const callback = componentMocks.timeTrackingImport.mock.calls.at(-1)![0].onImportComplete as () => Promise<boolean>;
  let pending!: Promise<boolean>;
  act(() => { pending = callback(); });
  await waitFor(() => expect(apiMocks.get).toHaveBeenCalledWith(12));
  apiMocks.get.mockResolvedValue({ pay_period: { ...original, status: 'calculated', notes: 'Fresh canonical imported payroll' } });
  fireEvent.click(screen.getByRole('button', { name: 'Sibling refresh' }));
  await screen.findByText('Fresh canonical imported payroll');
  await act(async () => { finish({ pay_period: original }); expect(await pending).toBe(true); });
  expect(screen.getByText('Fresh canonical imported payroll')).toBeTruthy();
  expect(screen.queryByText(/Source hours were saved, but the current payroll could not load/)).toBeNull();
  expect(screen.queryByText(/Saved source hours need a current payroll reload before processing/)).toBeNull();
});
