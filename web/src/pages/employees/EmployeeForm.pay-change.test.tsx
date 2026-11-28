// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes, useLocation } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Employee, EmployeeCompensationHistory } from '@/types';
import { EmployeeForm } from './EmployeeForm';

const mocks = vi.hoisted(() => ({
  get: vi.fn(), updateEmployee: vi.fn(), createEmployee: vi.fn(), departments: vi.fn(),
  listRates: vi.fn(), updateRate: vi.fn(), createRate: vi.fn(), deleteRate: vi.fn(), notify: vi.fn(), verifyItem: vi.fn(), employeeForFix: vi.fn(),
}));
vi.mock('@/components/ui/action-feedback', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/components/ui/action-feedback')>()),
  useFeedback: () => ({ notify: mocks.notify }),
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1 }, isClient: false, isSuperAdmin: true, isManager: true }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ refreshCompanies: async () => {}, activeCompanyId: 1, activeCompany: { id: 1, pay_frequency: 'biweekly', client_capabilities: ['manage_client_configuration'] } }) }));
vi.mock('@/hooks/useEmployeeIntakeSettings', () => ({ useEmployeeIntakeSettings: () => ({ settings: { enabled: false }, loading: false }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/employees/EmployeePayItemsPanel', () => ({ EmployeePayItemsPanel: () => null }));
vi.mock('@/components/employees/EmployeeDocumentsPanel', () => ({ EmployeeDocumentsPanel: () => null }));
vi.mock('@/components/employees/EmployeeClassificationTransitionDialog', () => ({ EmployeeClassificationTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeStatusTransitionDialog', () => ({ EmployeeStatusTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeWorkProfilePanel', () => ({ EmployeeWorkProfilePanel: () => null }));
vi.mock('@/services/staff-employee-lifecycle', () => ({
  staffEmployeeLifecycleApi: { employeeForFix: mocks.employeeForFix, get: mocks.verifyItem },
}));
vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return { ...actual,
    employeesApi: { ...actual.employeesApi, get: mocks.get, update: mocks.updateEmployee, create: mocks.createEmployee },
    departmentsApi: { list: mocks.departments },
    employeeWageRatesApi: { list: mocks.listRates, update: mocks.updateRate, create: mocks.createRate, delete: mocks.deleteRate },
  };
});

const history: EmployeeCompensationHistory = {
  revision: 'pay-revision',
  can_correct: true,
  effective_dates: { next_uncommitted_period: '2026-11-16', today: '2026-11-22', locked_through: '2026-11-15' },
  pay_rate_changes: [
    { id: 1, effective_on: '2024-01-01', ends_on: '2026-11-30', pay_rate: '15.0', employment_type: 'hourly', reason: 'Baseline recorded from the existing employee setup', source: 'backfill', historical_correction: false, status: 'current' },
  ],
  wage_rate_versions: [
    { id: 10, employee_wage_rate_id: 101, effective_on: '2024-01-01', ends_on: '2026-11-30', label: 'Regular', rate: '15.0', is_primary: true, active: true, reason: 'Baseline recorded from the existing wage-rate setup', source: 'backfill', historical_correction: false, status: 'current' },
    { id: 11, employee_wage_rate_id: 101, effective_on: '2026-12-01', ends_on: null, label: 'Regular', rate: '17.0', is_primary: true, active: true, reason: 'Annual raise', source: 'staff', historical_correction: false, created_by_name: 'Fictional Staff', status: 'scheduled' },
  ],
};

function employee(overrides: Partial<Employee> = {}): Employee {
  return {
    id: 7, company_id: 1, first_name: 'Synthetic', last_name: 'Hourly', ssn: '900-70-1234',
    hire_date: '2024-01-01', employment_type: 'hourly', pay_rate: 15,
    pay_frequency: 'biweekly', filing_status: 'single', allowances: 0, additional_withholding: 0,
    w4_dependent_credit: 0, w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0,
    w4_form_version: 2020, w4_effective_on: '2026-01-01', w4_source_reference: 'Reviewed employee election',
    retirement_rate: 0, roth_retirement_rate: 0, status: 'active',
    address_line1: '100 Synthetic Lane', city: 'Hagatna', state: 'GU', zip: '96910',
    wage_rates: [{ id: 101, employee_id: 7, label: 'Regular', rate: 15, is_primary: true, active: true }],
    default_custom_earnings: [], default_payroll_adjustments: [],
    compensation_history: history,
    created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}

async function loadEmployee(data: Employee) {
  mocks.get.mockResolvedValue({ data });
  mocks.updateEmployee.mockResolvedValue({ data, compensation_warnings: [] });
  render(<MemoryRouter initialEntries={['/companies/1/employees/7/edit?return_to=%2Fsaved']}><Routes>
    <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
    <Route path="/saved" element={<p>Saved employee profile</p>} />
  </Routes></MemoryRouter>);
  await waitFor(() => expect((screen.getByLabelText(/^First Name/) as HTMLInputElement).value).toBe('Synthetic'));
}

function changeHourlyRate(value: string) {
  const field = screen.getAllByLabelText(/^Hourly Rate/)[0];
  fireEvent.change(field, { target: { value } });
  fireEvent.blur(field);
}

function submit() {
  fireEvent.submit(document.getElementById('employee-form')!);
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.departments.mockResolvedValue({ data: [] });
  HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(cleanup);

describe('pay changes with an effective date', () => {
  it('shows the read-only pay rate history, including a scheduled raise', async () => {
    await loadEmployee(employee());
    const card = screen.getByTestId('pay-rate-history');
    expect(within(card).getAllByText('Regular (primary): $17.00/hr').length).toBeGreaterThan(0);
    expect(within(card).getAllByText('Scheduled').length).toBeGreaterThan(0);
    expect(within(card).queryByText('Pay rate $15.00/hr')).toBeNull();
    expect(within(card).getByRole('button', { name: /Cancel change for/ })).toBeTruthy();
    expect(within(card).queryByRole('textbox')).toBeNull();
  });

  it('asks for no effective date when pay is unchanged', async () => {
    await loadEmployee(employee());
    expect(screen.queryByTestId('pay-change-effective-date')).toBeNull();
    submit();
    await screen.findByText('Saved employee profile');
    const payload = mocks.updateEmployee.mock.calls[0][1];
    expect(payload.compensation_effective_on).toBeUndefined();
    expect(payload.compensation_change_reason).toBeUndefined();
    for (const endpoint of [mocks.listRates, mocks.updateRate, mocks.createRate, mocks.deleteRate]) expect(endpoint).not.toHaveBeenCalled();
  });

  it('saves a scalar-only hourly profile without sending compensation', async () => {
    await loadEmployee(employee({ wage_rates: [] }));
    fireEvent.change(screen.getByLabelText(/^First Name/), { target: { value: 'Renamed' } });
    expect(screen.queryByTestId('pay-change-effective-date')).toBeNull();
    submit();
    await waitFor(() => expect(mocks.updateEmployee).toHaveBeenCalled());
    const payload = mocks.updateEmployee.mock.calls[0][1];
    expect(payload.first_name).toBe('Renamed');
    for (const key of ['pay_rate', 'wage_rates', 'pay_frequency', 'employment_type', 'compensation_effective_on']) {
      expect(payload[key]).toBeUndefined();
    }
  });

  it('clears a historical correction when changing back to an open date', async () => {
    await loadEmployee(employee());
    changeHourlyRate('16');
    fireEvent.click(screen.getByRole('radio', { name: 'Custom date' }));
    fireEvent.change(screen.getByLabelText('Pay change effective date'), { target: { value: '2026-11-10' } });
    fireEvent.click(screen.getByRole('checkbox', { name: /Record as a historical correction/ }));
    fireEvent.click(screen.getByRole('radio', { name: /Today/ }));
    fireEvent.change(screen.getByLabelText(/Reason for this pay change/), { target: { value: 'Current raise' } });
    submit();
    await waitFor(() => expect(mocks.updateEmployee).toHaveBeenCalled());
    expect(mocks.updateEmployee.mock.calls[0][1].compensation_historical_correction).toBeUndefined();
  });

  it('requires an explicit effective-date choice and a reason before saving a rate change', async () => {
    await loadEmployee(employee());
    changeHourlyRate('16.50');
    const selector = await screen.findByTestId('pay-change-effective-date');
    const choices = within(selector).getAllByRole('radio').map((radio) => (radio as HTMLInputElement).checked);
    expect(choices).toEqual([false, false, false]);
    expect(within(selector).getByLabelText('Start of next uncommitted pay period (Nov 16, 2026)')).toBeTruthy();
    expect(within(selector).getByLabelText('Today (Nov 22, 2026)')).toBeTruthy();
    expect(within(selector).getByLabelText('Custom date')).toBeTruthy();

    submit();
    expect(await screen.findByText('Choose when this pay change takes effect.')).toBeTruthy();
    expect(screen.getByText('Explain why the pay is changing.')).toBeTruthy();
    expect(mocks.updateEmployee).not.toHaveBeenCalled();
  });

  it('saves the new rate with the next uncommitted period start in one request', async () => {
    await loadEmployee(employee());
    changeHourlyRate('16.50');
    fireEvent.click(await screen.findByLabelText('Start of next uncommitted pay period (Nov 16, 2026)'));
    fireEvent.change(screen.getByLabelText(/^Reason for this pay change/), { target: { value: 'Annual raise' } });
    submit();
    await screen.findByText('Saved employee profile');
    expect(mocks.updateEmployee).toHaveBeenCalledTimes(1);
    expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({
      pay_rate: 16.5,
      compensation_effective_on: '2026-11-16',
      compensation_change_reason: 'Annual raise',
      compensation_revision: 'pay-revision',
      compensation_wage_rate_edits: [{ id: 101, rate: 16.5 }],
    });
    expect(mocks.updateEmployee.mock.calls[0][1].compensation_historical_correction).toBeUndefined();
    for (const endpoint of [mocks.listRates, mocks.updateRate, mocks.createRate, mocks.deleteRate]) expect(endpoint).not.toHaveBeenCalled();
  });

  it('sends today when Today is chosen', async () => {
    await loadEmployee(employee());
    changeHourlyRate('16.50');
    fireEvent.click(await screen.findByLabelText('Today (Nov 22, 2026)'));
    fireEvent.change(screen.getByLabelText(/^Reason for this pay change/), { target: { value: 'Promotion' } });
    submit();
    await screen.findByText('Saved employee profile');
    expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({ compensation_effective_on: '2026-11-22', compensation_change_reason: 'Promotion' });
  });

  it('requires a historical correction for a custom date inside approved or committed payroll', async () => {
    await loadEmployee(employee());
    changeHourlyRate('16.50');
    fireEvent.click(await screen.findByLabelText('Custom date'));
    fireEvent.change(screen.getByLabelText('Pay change effective date'), { target: { value: '2026-11-01' } });
    fireEvent.change(screen.getByLabelText(/^Reason for this pay change/), { target: { value: 'Raise agreed on Nov 1' } });
    submit();
    expect(await screen.findByText(/Payroll through Nov 15, 2026 is approved or committed\. Choose a later date/)).toBeTruthy();
    expect(mocks.updateEmployee).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('checkbox', { name: /Record as a historical correction/ }));
    submit();
    await screen.findByText('Saved employee profile');
    expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({
      compensation_effective_on: '2026-11-01',
      compensation_historical_correction: true,
    });
  });

  it('shows the server warning when a change starts in the middle of an open payroll', async () => {
    await loadEmployee(employee());
    mocks.updateEmployee.mockResolvedValue({
      data: employee(),
      compensation_warnings: ['The 2026-11-16 to 2026-11-30 payroll is open and this change starts mid-period on 2026-11-22.'],
    });
    changeHourlyRate('16.50');
    fireEvent.click(await screen.findByLabelText('Today (Nov 22, 2026)'));
    fireEvent.change(screen.getByLabelText(/^Reason for this pay change/), { target: { value: 'Promotion' } });
    submit();
    await screen.findByText('Saved employee profile');
    expect(mocks.notify).toHaveBeenCalledWith({ tone: 'info', message: expect.stringMatching(/starts mid-period on 2026-11-22/) });
  });
});

it('warns about client re-approval before saving a verification fix and hands off the displayed revision', async () => {
  function QueueDestination() {
    const { state } = useLocation();
    return <output>{JSON.stringify(state.lifecycleFix)}</output>;
  }
  const updatedAt = '2026-11-27T12:00:00.000001Z';
  let resolveItem: (value: unknown) => void = () => {};
  mocks.verifyItem.mockReturnValue(new Promise(resolve => { resolveItem = resolve; }));
  mocks.employeeForFix.mockResolvedValue({ data: employee({ ssn: undefined, ssn_last_four: '1234' }) });
  mocks.updateEmployee.mockResolvedValue({ data: employee(), compensation_warnings: [] });
  render(<MemoryRouter initialEntries={['/companies/1/employees/7/edit?verify_item_id=22']}><Routes>
    <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
    <Route path="/companies/:companyId/verifications" element={<QueueDestination />} />
  </Routes></MemoryRouter>);
  await screen.findByText('Checking for approved payroll before editing…');
  expect((screen.getByRole('button', { name: 'Update Employee' }) as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByLabelText(/^Social Security Number/) as HTMLInputElement).value).toBe('');
  expect(screen.getByText(/Saved SSN ending in 1234/)).toBeTruthy();
  resolveItem({ data: { id: 22, company_id: 1, employee_id: 7, can_review: true, updated_at: updatedAt, warnings: { approved_pay_period_ids: [44] } } });
  await screen.findByText(/unapprove the run, recalculate, republish the review package, and get client re-approval/);
  fireEvent.change(screen.getByLabelText(/^First Name/), { target: { value: 'Synthetic Fix' } });
  submit();
  expect(await screen.findByText(JSON.stringify({ id: 22, companyId: 1, employeeId: 7, revision: updatedAt }))).toBeTruthy();
  expect(mocks.updateEmployee.mock.calls[0][1].ssn).toBeUndefined();
  expect(mocks.updateEmployee.mock.calls[0][1].mask_tax_ids).toBe(true);
});

it.each(['hourly', 'salary', 'contractor'] as const)('saves a verification fix on an incomplete gated %s hire', async (employmentType) => {
  const data = employee({ readiness_gate_enforced: true, pay_rate: 0, wage_rates: [], ssn: undefined,
    employment_type: employmentType, w4_effective_on: null, w4_source_reference: null, hire_date: null,
    address_line1: undefined, city: undefined, state: undefined, zip: undefined, contractor_type: 'business', contractor_pay_type: 'flat_fee' });
  mocks.employeeForFix.mockResolvedValue({ data });
  mocks.updateEmployee.mockResolvedValue({ data: { ...data, first_name: 'Synthetic Corrected' } });
  mocks.verifyItem.mockResolvedValue({ data: { id: 22, company_id: 1, employee_id: 7, can_review: true,
    updated_at: '2026-11-27T12:00:00Z', warnings: { approved_pay_period_ids: [] } } });
  render(<MemoryRouter initialEntries={['/companies/1/employees/7/edit?verify_item_id=22']}><Routes>
    <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
    <Route path="/companies/:companyId/verifications" element={<p>Ready to verify saved fix</p>} />
  </Routes></MemoryRouter>);
  const update = await screen.findByRole('button', { name: employmentType === 'contractor' ? 'Update Contractor' : 'Update Employee' });
  await waitFor(() => expect(update).toHaveProperty('disabled', false));
  fireEvent.change(screen.getByLabelText(/^First Name/), { target: { value: 'Synthetic Corrected' } });
  fireEvent.click(update);
  expect(await screen.findByText('Ready to verify saved fix')).toBeTruthy();
  expect(mocks.updateEmployee).toHaveBeenCalledWith(7, expect.objectContaining({
    first_name: 'Synthetic Corrected', mask_tax_ids: true, pay_rate: undefined, wage_rates: undefined,
    w4_effective_on: undefined, contractor_ein: undefined,
  }), 1);
  expect(mocks.updateEmployee.mock.calls[0][1]).not.toHaveProperty('ssn');
  expect(mocks.listRates).not.toHaveBeenCalled();
});

it('still requires a saved pay rate and withholding date on a gated employee', async () => {
  await loadEmployee(employee({ readiness_gate_enforced: true }));
  changeHourlyRate('0');
  fireEvent.change(screen.getByLabelText(/^Effective date/), { target: { value: '' } });
  submit();
  expect(screen.getByText('Each hourly pay rate must be greater than 0')).toBeTruthy();
  expect(screen.getByText('Enter the date this W-4 became effective')).toBeTruthy();
  expect(mocks.updateEmployee).not.toHaveBeenCalled();
});
