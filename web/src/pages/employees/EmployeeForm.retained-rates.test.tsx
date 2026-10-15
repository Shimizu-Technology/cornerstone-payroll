// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Employee, EmployeeWageRate } from '@/types';
import { EmployeeForm } from './EmployeeForm';

const mocks = vi.hoisted(() => ({
  get: vi.fn(), updateEmployee: vi.fn(), createEmployee: vi.fn(), departments: vi.fn(),
  listRates: vi.fn(), updateRate: vi.fn(), createRate: vi.fn(), deleteRate: vi.fn(),
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1 }, isClient: false, isSuperAdmin: true, isManager: true }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1, activeCompany: { id: 1, pay_frequency: 'biweekly' } }) }));
vi.mock('@/hooks/useEmployeeIntakeSettings', () => ({ useEmployeeIntakeSettings: () => ({ settings: { enabled: false }, loading: false }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/employees/EmployeePayItemsPanel', () => ({ EmployeePayItemsPanel: () => null }));
vi.mock('@/components/employees/EmployeeDocumentsPanel', () => ({ EmployeeDocumentsPanel: () => null }));
vi.mock('@/components/employees/EmployeeClassificationTransitionDialog', () => ({ EmployeeClassificationTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeStatusTransitionDialog', () => ({ EmployeeStatusTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeWorkProfilePanel', () => ({ EmployeeWorkProfilePanel: () => null }));
vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return { ...actual,
    employeesApi: { ...actual.employeesApi, get: mocks.get, update: mocks.updateEmployee, create: mocks.createEmployee },
    departmentsApi: { list: mocks.departments },
    employeeWageRatesApi: { list: mocks.listRates, update: mocks.updateRate, create: mocks.createRate, delete: mocks.deleteRate },
  };
});

const retainedRates: EmployeeWageRate[] = [
  { id: 101, employee_id: 7, label: 'Certification Operations', rate: 25, is_primary: true, active: true },
  { id: 205, employee_id: 7, label: 'Administrative Support', rate: 17.5, is_primary: false, active: true },
];
const hiddenInactiveRate: EmployeeWageRate = { id: 309, employee_id: 7, label: 'Retired rate', rate: 12, is_primary: false, active: false };
const unseenActiveRate: EmployeeWageRate = { id: 411, employee_id: 7, label: 'New weekend rate', rate: 40, is_primary: false, active: true };
function employee(overrides: Partial<Employee> = {}): Employee {
  return {
    id: 7, company_id: 1, first_name: 'Synthetic', last_name: 'Retained', ssn: '900-70-1234',
    hire_date: '2025-01-01', employment_type: 'salary', salary_type: 'annual', pay_rate: 52000,
    pay_frequency: 'biweekly', filing_status: 'single', allowances: 0, additional_withholding: 0,
    w4_dependent_credit: 0, w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0,
    w4_form_version: 2020, w4_effective_on: '2026-01-01', w4_source_reference: 'Reviewed employee election',
    retirement_rate: 0, roth_retirement_rate: 0, status: 'active',
    address_line1: '100 Synthetic Lane', city: 'Hagatna', state: 'GU', zip: '96910',
    contractor_type: 'individual', contractor_pay_type: 'flat_fee',
    wage_rates: retainedRates, default_custom_earnings: [], default_payroll_adjustments: [],
    created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}
function view(editing = true) {
  const path = editing ? '/companies/1/employees/7/edit?return_to=%2Fsaved' : '/companies/1/employees/new';
  return render(<MemoryRouter initialEntries={[path]}><Routes>
    <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
    <Route path="/companies/:companyId/employees/new" element={<EmployeeForm />} />
    <Route path="/companies/1/employees/7/overview" element={<p>Created employee 7 overview</p>} />
    <Route path="/saved" element={<p>Saved employee profile</p>} />
  </Routes></MemoryRouter>);
}
async function loadEmployee(data: Employee) {
  mocks.get.mockResolvedValue({ data });
  mocks.updateEmployee.mockResolvedValue({ data });
  mocks.listRates.mockResolvedValue({ wage_rates: data.wage_rates || [] });
  view();
  await waitFor(() => expect((screen.getByLabelText(/^First Name/) as HTMLInputElement).value).toBe('Synthetic'));
}
function assertNoWrites() {
  for (const write of [mocks.updateEmployee, mocks.createEmployee, mocks.updateRate, mocks.createRate, mocks.deleteRate]) expect(write).not.toHaveBeenCalled();
}
function hourlyValues() {
  return {
    labels: screen.getAllByLabelText(/^Rate Label/).map((field) => (field as HTMLInputElement).value),
    rates: screen.getAllByLabelText(/^Hourly Rate/).map((field) => (field as HTMLInputElement).value),
  };
}
const bases = [
  { label: 'annual salary', overrides: { employment_type: 'salary', salary_type: 'annual', pay_rate: 52000 } as Partial<Employee>, scalarLabel: /^Pay Rate/, scalar: '52000.00', toggleLabel: /^Employment Type/, nonHourlyValue: 'salary' },
  { label: 'contractor flat fee', overrides: { employment_type: 'contractor', contractor_pay_type: 'flat_fee', pay_rate: 500 } as Partial<Employee>, scalarLabel: /^Flat Fee per Period/, scalar: '500.00', toggleLabel: /^Pay Structure/, nonHourlyValue: 'flat_fee' },
];

beforeEach(() => {
  vi.clearAllMocks();
  mocks.departments.mockResolvedValue({ data: [] });
  mocks.updateRate.mockResolvedValue({}); mocks.createRate.mockResolvedValue({}); mocks.deleteRate.mockResolvedValue({});
  HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(cleanup);

describe.each(bases)('retained hourly definitions after $label', ({ overrides, scalarLabel, scalar, toggleLabel, nonHourlyValue }) => {
  it('restores both saved labels/rates/IDs without changing non-hourly money or writing before explicit Save', async () => {
    await loadEmployee(employee(overrides));
    expect((screen.getByLabelText(scalarLabel) as HTMLInputElement).value).toBe(scalar);
    expect(screen.queryByText('Hourly Pay Rates')).toBeNull();
    assertNoWrites();
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: 'hourly' } });
    expect(hourlyValues()).toEqual({ labels: ['Certification Operations', 'Administrative Support'], rates: ['25.00', '17.50'] });
    expect(screen.getAllByRole('radio', { name: 'Primary' }).map((field) => (field as HTMLInputElement).checked)).toEqual([true, false]);
    assertNoWrites();
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: nonHourlyValue } });
    expect((screen.getByLabelText(scalarLabel) as HTMLInputElement).value).toBe(scalar);
    assertNoWrites();
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: 'hourly' } });
    // Fresh list includes inactive history and another operator's later active addition.
    mocks.listRates.mockResolvedValue({ wage_rates: [...retainedRates, hiddenInactiveRate, unseenActiveRate] });
    fireEvent.submit(document.getElementById('employee-form')!);
    await screen.findByText('Saved employee profile');
    expect(mocks.updateEmployee).toHaveBeenCalledTimes(1);
    expect(mocks.updateEmployee.mock.calls[0][0]).toBe(7);
    expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({
      employment_type: overrides.employment_type === 'contractor' ? 'contractor' : 'hourly',
      ...(overrides.employment_type === 'contractor' ? { contractor_pay_type: 'hourly' } : {}),
      pay_rate: 25,
      wage_rates: [
        { id: 101, label: 'Certification Operations', rate: 25, is_primary: true, active: true },
        { id: 205, label: 'Administrative Support', rate: 17.5, is_primary: false, active: true },
      ],
    });
    expect(mocks.listRates).toHaveBeenCalledExactlyOnceWith(7, 1);
    expect(mocks.deleteRate).not.toHaveBeenCalled();
    expect(mocks.createRate).not.toHaveBeenCalled();
    expect(mocks.updateRate.mock.calls).toEqual([
      [101, { label: 'Certification Operations', rate: 25, is_primary: true, active: true }, 1],
      [205, { label: 'Administrative Support', rate: 17.5, is_primary: false, active: true }, 1],
    ]);
  });

  it('keeps the current non-hourly scalar on an ordinary save without touching hidden wage-rate endpoints', async () => {
    await loadEmployee(employee(overrides));
    expect((screen.getByLabelText(scalarLabel) as HTMLInputElement).value).toBe(scalar);
    fireEvent.submit(document.getElementById('employee-form')!);
    await screen.findByText('Saved employee profile');
    expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({ employment_type: overrides.employment_type, pay_rate: overrides.pay_rate });
    expect(mocks.updateEmployee.mock.calls[0][1].wage_rates).toBeUndefined();
    for (const endpoint of [mocks.listRates, mocks.updateRate, mocks.createRate, mocks.deleteRate]) expect(endpoint).not.toHaveBeenCalled();
  });

  it('requires a deliberate hourly amount when no hourly definition was ever retained', async () => {
    await loadEmployee(employee({ ...overrides, wage_rates: [] }));
    expect((screen.getByLabelText(scalarLabel) as HTMLInputElement).value).toBe(scalar);
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: 'hourly' } });
    expect(hourlyValues()).toEqual({ labels: ['Regular'], rates: ['0.00'] });
    fireEvent.submit(document.getElementById('employee-form')!);
    expect(await screen.findByText('Each hourly pay rate must be greater than 0')).toBeTruthy();
    assertNoWrites();
    expect(mocks.listRates).not.toHaveBeenCalled();
  });

  it.each(['edit', 'remove', 'primary', 'add'])('preserves the non-hourly amount after an hourly %s and a round trip before Save', async (action) => {
    await loadEmployee(employee(overrides));
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: 'hourly' } });
    if (action === 'edit') {
      fireEvent.change(screen.getAllByLabelText(/^Hourly Rate/)[0], { target: { value: '30' } });
    } else if (action === 'remove') {
      fireEvent.click(screen.getByRole('button', { name: 'Remove hourly rate Certification Operations' }));
    } else if (action === 'primary') {
      fireEvent.click(screen.getAllByRole('radio', { name: 'Primary' })[1]);
    } else {
      fireEvent.click(screen.getByRole('button', { name: 'Add Rate' }));
      fireEvent.change(screen.getAllByLabelText(/^Rate Label/)[2], { target: { value: 'Weekend' } });
      fireEvent.change(screen.getAllByLabelText(/^Hourly Rate/)[2], { target: { value: '40' } });
    }
    const expectedDraft = action === 'remove'
      ? { labels: ['Administrative Support'], rates: ['17.50'] }
      : { labels: ['Certification Operations', 'Administrative Support', ...(action === 'add' ? ['Weekend'] : [])],
          rates: [action === 'edit' ? '30.00' : '25.00', '17.50', ...(action === 'add' ? ['40.00'] : [])] };
    expect(hourlyValues()).toEqual(expectedDraft);
    const expectedPrimary = action === 'primary' ? [false, true] : action === 'remove' ? [true] : [true, false, ...(action === 'add' ? [false] : [])];
    expect(screen.getAllByRole('radio', { name: 'Primary' }).map((field) => (field as HTMLInputElement).checked)).toEqual(expectedPrimary);
    assertNoWrites();
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: nonHourlyValue } });
    expect((screen.getByLabelText(scalarLabel) as HTMLInputElement).value).toBe(scalar);
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: 'hourly' } });
    expect(hourlyValues()).toEqual(expectedDraft);
    expect(screen.getAllByRole('radio', { name: 'Primary' }).map((field) => (field as HTMLInputElement).checked)).toEqual(expectedPrimary);
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: nonHourlyValue } });
    assertNoWrites();
    fireEvent.submit(document.getElementById('employee-form')!);
    await screen.findByText('Saved employee profile');
    expect(mocks.updateEmployee).toHaveBeenCalledTimes(1);
    expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({ employment_type: overrides.employment_type, pay_rate: overrides.pay_rate });
    expect(mocks.updateEmployee.mock.calls[0][1].wage_rates).toBeUndefined();
    for (const endpoint of [mocks.listRates, mocks.updateRate, mocks.createRate, mocks.deleteRate]) expect(endpoint).not.toHaveBeenCalled();
  });

  it('preserves a newly entered non-hourly amount while editing and returning from hourly rates', async () => {
    await loadEmployee(employee(overrides));
    const amount = (overrides.pay_rate || 0) + 100;
    fireEvent.change(screen.getByLabelText(scalarLabel), { target: { value: String(amount) } });
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: 'hourly' } });
    fireEvent.change(screen.getAllByLabelText(/^Hourly Rate/)[0], { target: { value: '30' } });
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: nonHourlyValue } });
    expect((screen.getByLabelText(scalarLabel) as HTMLInputElement).value).toBe(amount.toFixed(2));
    assertNoWrites();
    fireEvent.submit(document.getElementById('employee-form')!);
    await screen.findByText('Saved employee profile');
    expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({ employment_type: overrides.employment_type, pay_rate: amount });
    for (const endpoint of [mocks.listRates, mocks.updateRate, mocks.createRate, mocks.deleteRate]) expect(endpoint).not.toHaveBeenCalled();
  });

  it('defensively filters an inactive primary supplied in the response and saves only the active retained ID', async () => {
    const inactivePrimary = { ...retainedRates[0], active: false };
    await loadEmployee(employee({ ...overrides, wage_rates: [inactivePrimary, retainedRates[1], hiddenInactiveRate] }));
    fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: 'hourly' } });
    expect(hourlyValues()).toEqual({ labels: ['Administrative Support'], rates: ['17.50'] });
    expect((screen.getByRole('radio', { name: 'Primary' }) as HTMLInputElement).checked).toBe(true);
    assertNoWrites();
    mocks.listRates.mockResolvedValue({ wage_rates: [inactivePrimary, retainedRates[1], hiddenInactiveRate, unseenActiveRate] });
    fireEvent.submit(document.getElementById('employee-form')!);
    await screen.findByText('Saved employee profile');
    expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({ pay_rate: 17.5, wage_rates: [
      { id: 205, label: 'Administrative Support', rate: 17.5, is_primary: true, active: true },
    ] });
    expect(mocks.updateRate.mock.calls).toEqual([
      [205, { label: 'Administrative Support', rate: 17.5, is_primary: true, active: true }, 1],
    ]);
    expect(mocks.createRate).not.toHaveBeenCalled();
    expect(mocks.deleteRate).not.toHaveBeenCalled();
  });
});

it.each([
  ...bases.map((base) => ({ ...base, responseShape: 'canonical empty active-rate list' })),
  ...bases.map((base) => ({ ...base, responseShape: 'defensive supplied inactive rows' })),
  { label: 'existing hourly profile', overrides: { employment_type: 'hourly', pay_rate: 25 } as Partial<Employee>, toggleLabel: null, responseShape: 'defensive supplied inactive rows' },
])('requires an explicit new hourly definition on $label with $responseShape and preserves retired IDs', async ({ overrides, toggleLabel, responseShape }) => {
  const inactiveRates = retainedRates.map((rate) => ({ ...rate, active: false }));
  // Normal employee GET serializes only active rows. The later rate-list GET
  // returns all definitions, including retired ones that must remain untouched.
  await loadEmployee(employee({ ...overrides, wage_rates: responseShape === 'canonical empty active-rate list' ? [] : inactiveRates }));
  if (toggleLabel) fireEvent.change(screen.getByLabelText(toggleLabel), { target: { value: 'hourly' } });
  expect(hourlyValues()).toEqual({ labels: ['Regular'], rates: ['0.00'] });
  assertNoWrites();
  fireEvent.submit(document.getElementById('employee-form')!);
  expect(await screen.findByText('Each hourly pay rate must be greater than 0')).toBeTruthy();
  assertNoWrites();
  expect(mocks.listRates).not.toHaveBeenCalled();
  fireEvent.change(screen.getByLabelText(/^Hourly Rate/), { target: { value: '30' } });
  mocks.listRates.mockResolvedValue({ wage_rates: [...inactiveRates, unseenActiveRate] });
  fireEvent.submit(document.getElementById('employee-form')!);
  await screen.findByText('Saved employee profile');
  expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({ pay_rate: 30, wage_rates: [
    { label: 'Regular', rate: 30, is_primary: true, active: true },
  ] });
  expect(mocks.updateEmployee.mock.calls[0][1].wage_rates[0].id).toBeUndefined();
  expect(mocks.createRate).toHaveBeenCalledExactlyOnceWith({ employee_id: 7, label: 'Regular', rate: 30, is_primary: true, active: true }, 1);
  expect(mocks.updateRate).not.toHaveBeenCalled();
  expect(mocks.deleteRate).not.toHaveBeenCalled();
});

it.each(['salary', 'hourly'])('preserves a zero variable-salary draft and validates the chosen %s basis from its own amount', async (basis) => {
  await loadEmployee(employee({ employment_type: 'salary', salary_type: 'variable', pay_rate: 0 }));
  expect(screen.queryByLabelText(/^Pay Rate/)).toBeNull();
  fireEvent.change(screen.getByLabelText(/^Employment Type/), { target: { value: 'hourly' } });
  fireEvent.change(screen.getAllByLabelText(/^Hourly Rate/)[0], { target: { value: '30' } });
  fireEvent.change(screen.getByLabelText(/^Employment Type/), { target: { value: 'salary' } });
  expect(screen.queryByLabelText(/^Pay Rate/)).toBeNull();
  expect(screen.getByText(/Pay is set each pay period using the salary override/)).toBeTruthy();
  if (basis === 'hourly') fireEvent.change(screen.getByLabelText(/^Employment Type/), { target: { value: 'hourly' } });
  assertNoWrites();
  fireEvent.submit(document.getElementById('employee-form')!);
  await screen.findByText('Saved employee profile');
  expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({ employment_type: basis, pay_rate: basis === 'hourly' ? 30 : 0 });
  if (basis === 'salary') {
    expect(mocks.updateEmployee.mock.calls[0][1].wage_rates).toBeUndefined();
    for (const endpoint of [mocks.listRates, mocks.updateRate]) expect(endpoint).not.toHaveBeenCalled();
  } else {
    expect(mocks.updateEmployee.mock.calls[0][1].wage_rates).toMatchObject([
      { id: 101, rate: 30, is_primary: true }, { id: 205, rate: 17.5, is_primary: false },
    ]);
    expect(mocks.updateRate.mock.calls).toEqual([
      [101, { label: 'Certification Operations', rate: 30, is_primary: true, active: true }, 1],
      [205, { label: 'Administrative Support', rate: 17.5, is_primary: false, active: true }, 1],
    ]);
  }
  expect(mocks.createRate).not.toHaveBeenCalled();
  expect(mocks.deleteRate).not.toHaveBeenCalled();
});

it('keeps a brand-new hourly profile at an explicit zero default rather than inventing a saved rate', () => {
  view(false);
  expect(hourlyValues()).toEqual({ labels: ['Regular'], rates: ['0.00'] });
  expect(mocks.get).not.toHaveBeenCalled();
  assertNoWrites();
});

it('creates a new hourly employee from the explicitly entered rate without requiring a hidden scalar', async () => {
  mocks.createEmployee.mockResolvedValue({ data: employee({ employment_type: 'hourly', pay_rate: 25, wage_rates: [] }) });
  mocks.listRates.mockResolvedValue({ wage_rates: [] });
  view(false);
  const fields: Array<[RegExp, string]> = [
    [/^First Name/, 'Synthetic'], [/^Last Name/, 'Retained'],
    [/^Social Security Number/, '900-70-1234'], [/^Re-enter Social Security Number/, '900-70-1234'],
    [/^Hire Date/, '2025-01-01'], [/^Address Line 1/, '100 Synthetic Lane'],
    [/^City/, 'Hagatna'], [/^State/, 'GU'], [/^ZIP Code/, '96910'],
    [/^Effective date/, '2026-01-01'], [/^Hourly Rate/, '25'],
  ];
  for (const [label, value] of fields) fireEvent.change(screen.getByLabelText(label), { target: { value } });
  assertNoWrites();
  fireEvent.submit(document.getElementById('employee-form')!);
  await screen.findByText('Created employee 7 overview');
  expect(mocks.createEmployee).toHaveBeenCalledTimes(1);
  expect(mocks.createEmployee.mock.calls[0][0]).toMatchObject({ company_id: 1, employment_type: 'hourly', pay_rate: 25,
    wage_rates: [{ label: 'Regular', rate: 25, is_primary: true, active: true }],
  });
  expect(mocks.createRate).toHaveBeenCalledExactlyOnceWith({ employee_id: 7, label: 'Regular', rate: 25, is_primary: true, active: true }, 1);
  expect(mocks.updateEmployee).not.toHaveBeenCalled();
  expect(mocks.updateRate).not.toHaveBeenCalled();
  expect(mocks.deleteRate).not.toHaveBeenCalled();
});

it('preserves the existing single-scalar fallback for an already-hourly employee without labeled definitions', async () => {
  await loadEmployee(employee({ employment_type: 'hourly', pay_rate: 25, wage_rates: [] }));
  expect(hourlyValues()).toEqual({ labels: ['Regular'], rates: ['25.00'] });
  assertNoWrites();
});


it('preserves hidden inactive and unseen active rates during an ordinary hourly save', async () => {
  await loadEmployee(employee({ employment_type: 'hourly', pay_rate: 25 }));
  expect(hourlyValues()).toEqual({ labels: ['Certification Operations', 'Administrative Support'], rates: ['25.00', '17.50'] });
  assertNoWrites();
  mocks.listRates.mockResolvedValue({ wage_rates: [...retainedRates, hiddenInactiveRate, unseenActiveRate] });
  fireEvent.submit(document.getElementById('employee-form')!);
  await screen.findByText('Saved employee profile');
  expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({ pay_rate: 25, wage_rates: [
    { id: 101, label: 'Certification Operations', rate: 25, active: true },
    { id: 205, label: 'Administrative Support', rate: 17.5, active: true },
  ] });
  expect(mocks.deleteRate).not.toHaveBeenCalled();
  expect(mocks.createRate).not.toHaveBeenCalled();
  expect(mocks.updateRate.mock.calls.map(([id]) => id)).toEqual([101, 205]);
});

it.each([true, false])('limits explicit removal to the displayed saved ID still active in the fresh list (%s)', async (stillActive) => {
  await loadEmployee(employee({ employment_type: 'hourly', pay_rate: 25 }));
  fireEvent.click(screen.getByRole('button', { name: 'Remove hourly rate Administrative Support' }));
  expect(hourlyValues()).toEqual({ labels: ['Certification Operations'], rates: ['25.00'] });
  assertNoWrites();
  mocks.listRates.mockResolvedValue({ wage_rates: [
    retainedRates[0], { ...retainedRates[1], active: stillActive }, hiddenInactiveRate, unseenActiveRate,
  ] });
  fireEvent.submit(document.getElementById('employee-form')!);
  await screen.findByText('Saved employee profile');
  expect(mocks.updateEmployee.mock.calls[0][1]).toMatchObject({ pay_rate: 25, wage_rates: [
    { id: 101, label: 'Certification Operations', rate: 25, is_primary: true, active: true },
  ] });
  if (stillActive) expect(mocks.deleteRate).toHaveBeenCalledExactlyOnceWith(205, 1);
  else expect(mocks.deleteRate).not.toHaveBeenCalled();
  expect(mocks.createRate).not.toHaveBeenCalled();
  expect(mocks.updateRate.mock.calls).toEqual([
    [101, { label: 'Certification Operations', rate: 25, is_primary: true, active: true }, 1],
  ]);
});
