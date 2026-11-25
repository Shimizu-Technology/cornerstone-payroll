// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeForm } from './EmployeeForm';

const mocks = vi.hoisted(() => ({ get: vi.fn(), departments: vi.fn(), fields: vi.fn(), assignments: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1 }, isClient: false, isSuperAdmin: true, isManager: true }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ refreshCompanies: async () => {}, activeCompanyId: 1 }) }));
vi.mock('@/hooks/useEmployeeIntakeSettings', () => ({ useEmployeeIntakeSettings: () => ({ settings: { enabled: false }, loading: false }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/employees/EmployeeDocumentsPanel', () => ({ EmployeeDocumentsPanel: () => <p>Document manager open</p> }));
vi.mock('@/components/employees/EmployeeClassificationTransitionDialog', () => ({ EmployeeClassificationTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeStatusTransitionDialog', () => ({ EmployeeStatusTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeWorkProfilePanel', () => ({ EmployeeWorkProfilePanel: () => null }));
vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return { ...actual, employeesApi: { ...actual.employeesApi, get: mocks.get },
    departmentsApi: { list: mocks.departments }, payrollFieldsApi: { list: mocks.fields }, employeePayrollFieldsApi: { list: mocks.assignments } };
});

const employee = { id: 7, company_id: 1, first_name: 'Juniper', last_name: 'Moss', employment_type: 'hourly', pay_rate: 18,
  pay_frequency: 'biweekly', filing_status: 'single', allowances: 0, additional_withholding: 0, w4_dependent_credit: 0,
  w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0, w4_form_version: 2026,
  w4_effective_on: '2026-11-01', hire_date: '2026-11-01', ssn: '900-70-1234', address_line1: '1 Example Way', city: 'Hagatna', state: 'GU',
  zip: '96910', status: 'active', default_payroll_adjustments: [], default_custom_earnings: [], wage_rates: [],
  document_readiness: { total: 2, required: 2, satisfied: 0, ready_for_payroll: false, missing: ['Identity and work authorization', 'Signed withholding election'] } };

function view(path: string) {
  return render(<MemoryRouter initialEntries={[path]}><Routes>
    <Route path="/companies/:companyId/employees/new" element={<EmployeeForm />} />
    <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
  </Routes></MemoryRouter>);
}
function w4EffectiveDate() { return document.querySelector<HTMLInputElement>('[name="w4_effective_on"]')!; }
function hireDate() { return document.querySelector<HTMLInputElement>('[name="hire_date"]')!; }

beforeEach(() => {
  vi.clearAllMocks(); mocks.get.mockResolvedValue({ data: employee });
  mocks.departments.mockResolvedValue({ data: [] }); mocks.fields.mockResolvedValue({ payroll_fields: [] }); mocks.assignments.mockResolvedValue({ employee_payroll_fields: [] });
  HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(cleanup);

describe('Adding a new hire', () => {
  it('marks the W-4 effective date required and follows the hire date until staff change it', async () => {
    view('/companies/1/employees/new');
    await screen.findByText('W-4 Tax Withholding');
    expect(w4EffectiveDate().required).toBe(true);
    expect(screen.getByText('Effective date', { selector: 'label' }).textContent).toContain('*');

    fireEvent.change(hireDate(), { target: { value: '2026-11-02' } });
    expect(w4EffectiveDate().value).toBe('2026-11-02');
    fireEvent.change(hireDate(), { target: { value: '2026-11-03' } });
    expect(w4EffectiveDate().value).toBe('2026-11-03');

    fireEvent.change(w4EffectiveDate(), { target: { value: '2026-11-10' } });
    fireEvent.change(hireDate(), { target: { value: '2026-11-04' } });
    expect(w4EffectiveDate().value).toBe('2026-11-10');
  });

  it('explains why date of birth matters without requiring it', async () => {
    view('/companies/1/employees/new');
    const dob = await screen.findByLabelText('Date of Birth');
    expect((dob as HTMLInputElement).required).toBe(false);
    expect(dob.getAttribute('aria-describedby')).toBe('employee-dob-hint');
    expect(document.getElementById('employee-dob-hint')?.textContent).toBe('Optional for payroll. Needed for the employee app sign-up.');
  });
});

describe('New-hire documents on the employee form', () => {
  it('lists what is still needed and opens the document manager from a documents link', async () => {
    view('/companies/1/employees/7/edit#employee-documents');
    expect(await screen.findByText('Document manager open')).toBeTruthy();
    expect(screen.getByText("Before this employee's first payroll is approved, upload and verify: Identity and work authorization, Signed withholding election.")).toBeTruthy();
    expect(screen.queryByText(/tucked away/)).toBeNull();
  });

  it('keeps the document manager closed on a plain edit link', async () => {
    view('/companies/1/employees/7/edit');
    await screen.findByText(/upload and verify: Identity and work authorization/);
    expect(screen.queryByText('Document manager open')).toBeNull();
  });
});
