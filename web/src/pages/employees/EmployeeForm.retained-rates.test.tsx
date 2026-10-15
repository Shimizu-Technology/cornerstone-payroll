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
});

it('keeps a brand-new hourly profile at an explicit zero default rather than inventing a saved rate', () => {
  view(false);
  expect(hourlyValues()).toEqual({ labels: ['Regular'], rates: ['0.00'] });
  expect(mocks.get).not.toHaveBeenCalled();
  assertNoWrites();
});

it('preserves the existing single-scalar fallback for an already-hourly employee without labeled definitions', async () => {
  await loadEmployee(employee({ employment_type: 'hourly', pay_rate: 25, wage_rates: [] }));
  expect(hourlyValues()).toEqual({ labels: ['Regular'], rates: ['25.00'] });
  assertNoWrites();
});
