// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import { EmployeeForm } from './EmployeeForm';

const mocks = vi.hoisted(() => ({ get: vi.fn(), create: vi.fn(), departments: vi.fn(), fields: vi.fn(), assignments: vi.fn() }));
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
  return { ...actual, employeesApi: { ...actual.employeesApi, get: mocks.get, create: mocks.create },
    departmentsApi: { list: mocks.departments }, payrollFieldsApi: { list: mocks.fields }, employeePayrollFieldsApi: { list: mocks.assignments } };
});

const employee = { id: 7, company_id: 1, first_name: 'Juniper', last_name: 'Moss', employment_type: 'hourly', pay_rate: 18,
  pay_frequency: 'biweekly', filing_status: 'single', allowances: 0, additional_withholding: 0, w4_dependent_credit: 0,
  w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0, w4_form_version: 2026,
  w4_effective_on: '2026-11-01', hire_date: '2026-11-01', ssn: '900-70-1234', address_line1: '1 Example Way', city: 'Hagatna', state: 'GU',
  zip: '96910', status: 'active', default_payroll_adjustments: [], default_custom_earnings: [], wage_rates: [],
  document_readiness: { total: 2, required: 2, satisfied: 0, ready_for_payroll: false, missing: ['Identity and work authorization', 'Signed withholding election'] } };

function view(path: string) {
  return render(<MemoryRouter initialEntries={[path]}><FeedbackProvider><Routes>
    <Route path="/companies/:companyId/employees/new" element={<EmployeeForm />} />
    <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
    <Route path="/companies/:companyId/employees/:id/overview" element={<p>Employee overview</p>} />
  </Routes></FeedbackProvider></MemoryRouter>);
}
function w4EffectiveDate() { return document.querySelector<HTMLInputElement>('[name="w4_effective_on"]')!; }
function w4SignedDate() { return screen.getByLabelText(/Signed date on source W-4/) as HTMLInputElement; }
function hireDate() { return document.querySelector<HTMLInputElement>('[name="hire_date"]')!; }

beforeEach(() => {
  vi.clearAllMocks(); mocks.get.mockResolvedValue({ data: employee });
  mocks.departments.mockResolvedValue({ data: [] }); mocks.fields.mockResolvedValue({ payroll_fields: [] }); mocks.assignments.mockResolvedValue({ employee_payroll_fields: [] });
  HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(cleanup);

describe('Adding a new hire', () => {
  it('marks the W-4 effective date required and uses the hire date only after staff accept it', async () => {
    view('/companies/1/employees/new');
    await screen.findByText('W-4 Tax Withholding');
    expect(w4EffectiveDate().required).toBe(true);
    expect(screen.getByText('Effective date', { selector: 'label' }).textContent).toContain('*');
    expect(screen.queryByRole('button', { name: /Use hire date/ })).toBeNull();

    fireEvent.change(hireDate(), { target: { value: '2026-11-02' } });
    expect(w4EffectiveDate().value).toBe('');
    fireEvent.click(screen.getByRole('button', { name: 'Use hire date (2026-11-02)' }));
    expect(w4EffectiveDate().value).toBe('2026-11-02');
    expect(screen.queryByRole('button', { name: /Use hire date/ })).toBeNull();

    // A later hire date change never moves an accepted effective date.
    fireEvent.change(hireDate(), { target: { value: '2026-11-03' } });
    expect(w4EffectiveDate().value).toBe('2026-11-02');
    expect(screen.getByRole('button', { name: 'Use hire date (2026-11-03)' })).toBeTruthy();
  });

  it('warns when the W-4 was signed after its effective date', async () => {
    view('/companies/1/employees/new');
    await screen.findByText('W-4 Tax Withholding');
    fireEvent.change(hireDate(), { target: { value: '2026-11-02' } });
    fireEvent.click(screen.getByRole('button', { name: 'Use hire date (2026-11-02)' }));
    expect(screen.queryByText(/after its effective date/)).toBeNull();

    fireEvent.change(w4SignedDate(), { target: { value: '2026-11-09' } });
    expect(screen.getByRole('alert').textContent).toContain('This W-4 was signed on 2026-11-09, after its effective date of 2026-11-02.');
    expect(w4EffectiveDate().value).toBe('2026-11-02');

    fireEvent.change(w4EffectiveDate(), { target: { value: '2026-11-09' } });
    expect(screen.queryByText(/after its effective date/)).toBeNull();
  });

  it('links the created-employee confirmation to the new hire\'s document manager', async () => {
    // Compensation history in the response means the initial rates were saved with the profile.
    mocks.create.mockResolvedValue({ data: { ...employee, id: 31, compensation_history: { revision: 1 } } });
    view('/companies/1/employees/new');
    await screen.findByText('W-4 Tax Withholding');
    fireEvent.change(screen.getByLabelText(/First Name/), { target: { value: 'Juniper' } });
    fireEvent.change(screen.getByLabelText(/Last Name/), { target: { value: 'Moss' } });
    fireEvent.change(screen.getByLabelText(/Hourly Rate/), { target: { value: '18' } });
    const fields = { ssn: '900-70-1234', ssn_confirmation: '900-70-1234', address_line1: '1 Example Way', city: 'Hagatna', state: 'GU', zip: '96910' };
    for (const [name, value] of Object.entries(fields)) fireEvent.change(document.querySelector(`[name="${name}"]`)!, { target: { value } });
    fireEvent.change(hireDate(), { target: { value: '2026-11-02' } });
    fireEvent.click(screen.getByRole('button', { name: 'Use hire date (2026-11-02)' }));
    fireEvent.submit(document.getElementById('employee-form')!);

    await waitFor(() => expect(mocks.create).toHaveBeenCalled());
    expect(mocks.create.mock.calls[0][0].w4_effective_on).toBe('2026-11-02');
    const link = await screen.findByRole('link', { name: 'Open documents' });
    expect(link.getAttribute('href')).toBe('/companies/1/employees/31/edit?return_to=%2Fcompanies%2F1%2Femployees#employee-documents');
    expect(link.parentElement?.textContent).toContain('upload and verify: Identity and work authorization, Signed withholding election.');
  });

  it('explains why date of birth matters without requiring it', async () => {
    view('/companies/1/employees/new');
    const dob = await screen.findByLabelText('Date of Birth');
    expect((dob as HTMLInputElement).required).toBe(false);
    expect(dob.getAttribute('aria-describedby')).toBe('employee-dob-hint');
    expect(document.getElementById('employee-dob-hint')?.textContent).toBe('Optional for payroll. Needed for the employee app sign-up.');
  });
});

describe('Editing an existing employee', () => {
  it('never offers or applies the hire date to an existing W-4 effective date', async () => {
    mocks.get.mockResolvedValue({ data: { ...employee, w4_effective_on: '2026-11-05', w4_signed_on: '2026-11-05' } });
    view('/companies/1/employees/7/edit');
    await screen.findByDisplayValue('Juniper');
    fireEvent.change(hireDate(), { target: { value: '2026-10-20' } });
    expect(w4EffectiveDate().value).toBe('2026-11-05');
    expect(screen.queryByRole('button', { name: /Use hire date/ })).toBeNull();
  });

  it('keeps the original W-4 effective date for a rehired worker', async () => {
    mocks.get.mockResolvedValue({ data: { ...employee, hire_date: '2026-11-20', w4_effective_on: '2025-03-01', w4_signed_on: '2025-02-25' } });
    view('/companies/1/employees/7/edit');
    await screen.findByDisplayValue('Juniper');
    expect(hireDate().value).toBe('2026-11-20');
    expect(w4EffectiveDate().value).toBe('2025-03-01');
    expect(screen.queryByRole('button', { name: /Use hire date/ })).toBeNull();
    expect(screen.queryByText(/after its effective date/)).toBeNull();
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
