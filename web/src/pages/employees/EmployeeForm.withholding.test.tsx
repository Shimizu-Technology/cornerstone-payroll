// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeForm } from './EmployeeForm';

const mocks = vi.hoisted(() => ({ get: vi.fn(), update: vi.fn(), departments: vi.fn(), fields: vi.fn(), assignments: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1 }, isClient: false, isSuperAdmin: true, isManager: true }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1 }) }));
vi.mock('@/hooks/useEmployeeIntakeSettings', () => ({ useEmployeeIntakeSettings: () => ({ settings: { enabled: false }, loading: false }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/employees/EmployeeDocumentsPanel', () => ({ EmployeeDocumentsPanel: () => null }));
vi.mock('@/components/employees/EmployeeClassificationTransitionDialog', () => ({ EmployeeClassificationTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeStatusTransitionDialog', () => ({ EmployeeStatusTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeWorkProfilePanel', () => ({ EmployeeWorkProfilePanel: () => null }));
vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return { ...actual, employeesApi: { ...actual.employeesApi, get: mocks.get, update: mocks.update },
    departmentsApi: { list: mocks.departments }, payrollFieldsApi: { list: mocks.fields }, employeePayrollFieldsApi: { list: mocks.assignments } };
});
const employee = { id: 7, first_name: 'Synthetic', last_name: 'Worker', employment_type: 'salary', salary_type: 'annual', pay_rate: 24000,
  pay_frequency: 'biweekly', filing_status: 'single', allowances: 0, additional_withholding: 0, w4_dependent_credit: 0,
  w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0, w4_form_version: 2026,
  w4_effective_on: '2026-01-01', w4_signed_on: null, w4_source_reference: 'Reviewed default', hire_date: '2025-01-01',
  ssn: '900-70-1234', address_line1: '100 Synthetic Lane', city: 'Hagatna', state: 'GU', zip: '96910', status: 'active',
  current_w4_election: { source: 'default_withholding', effective_on: '2026-01-01' },
  intake_readiness: { profile_incomplete: true, missing_fields: ['withholding_election'], exception: null },
  default_payroll_adjustments: [], default_custom_earnings: [], wage_rates: [] };
function view() {
  return render(<MemoryRouter initialEntries={['/companies/1/employees/7/edit?return_to=%2Fcompanies%2F1%2Femployees%2F7%2Foverview']}><Routes>
    <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
    <Route path="/companies/:companyId/employees/:id/overview" element={<p>Saved employee</p>} />
  </Routes></MemoryRouter>);
}
function field(label: RegExp | string): HTMLInputElement | HTMLSelectElement {
  const node = screen.getByText(label, { selector: 'label' }).parentElement?.querySelector<HTMLInputElement | HTMLSelectElement>('input,select');
  if (!node) throw new Error('Missing form field '+label);
  return node;
}
function toggle() { return screen.getByRole('checkbox', { name: 'Record a received employee withholding election' }); }
function submit() { fireEvent.submit(document.getElementById('employee-form')!); }
beforeEach(() => {
  vi.clearAllMocks(); mocks.get.mockResolvedValue({ data: employee }); mocks.update.mockResolvedValue({ data: employee });
  mocks.departments.mockResolvedValue({ data: [] }); mocks.fields.mockResolvedValue({ payroll_fields: [] }); mocks.assignments.mockResolvedValue({ employee_payroll_fields: [] });
  HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(cleanup);
describe('Received-election draft preservation and default safeguards', () => {
  it('preserves all unrelated W-4 fields, currency drafts and reason when receipt is unchecked', async () => {
    view(); await screen.findByText('Approved default withholding');
    const currency = [[/Total Annual Step 3 Credit/, '123.45'], [/4\(a\) Other Income/, '5.67'], [/4\(b\) Deductions/, '45.67'], [/4\(c\) Extra Withholding/, '89.01']] as const;
    currency.forEach(([label, value]) => fireEvent.change(field(label), { target: { value } }));
    fireEvent.change(field(/Filing Status/), { target: { value: 'married' } });
    fireEvent.change(field('Form revision year'), { target: { value: '2025' } });
    fireEvent.click(screen.getByRole('checkbox', { name: /Employee checked the Step 2/ }));
    fireEvent.change(document.querySelector('[name="w4_change_reason"]')!, { target: { value: 'Employer supplied updated election' } });
    fireEvent.click(toggle()); fireEvent.click(toggle());
    currency.forEach(([label, value]) => expect(field(label).value).toBe(value));
    expect(field(/Filing Status/).value).toBe('married');
    expect(field('Form revision year').value).toBe('2025');
    expect((screen.getByRole('checkbox', { name: /Employee checked the Step 2/ }) as HTMLInputElement).checked).toBe(true);
    expect(document.querySelector<HTMLInputElement>('[name="w4_change_reason"]')?.value).toBe('Employer supplied updated election');
    expect(document.querySelector<HTMLInputElement>('[name="w4_effective_on"]')?.value).toBe(employee.w4_effective_on);
    submit();
    expect(await screen.findByText(/Confirm that the employee withholding election was received before replacing/)).toBeTruthy();
    expect(mocks.update).not.toHaveBeenCalled();
  });
  it('submits preserved tax values only after explicit receipt evidence and keeps return context', async () => {
    view(); await screen.findByText('Approved default withholding');
    fireEvent.change(field(/Total Annual Step 3 Credit/), { target: { value: '100.50' } });
    fireEvent.click(toggle()); fireEvent.click(toggle()); fireEvent.click(toggle());
    fireEvent.change(document.querySelector('[name="w4_effective_on"]')!, { target: { value: '2026-10-01' } });
    fireEvent.change(screen.getByLabelText('Source document / reference (optional)'), { target: { value: 'Synthetic received form' } });
    fireEvent.change(document.querySelector('[name="w4_change_reason"]')!, { target: { value: 'Employer delivered updated form' } });
    submit(); await waitFor(() => expect(mocks.update).toHaveBeenCalled());
    expect(mocks.update.mock.calls[0][1]).toMatchObject({ w4_dependent_credit: 100.5, w4_election_received: true,
      w4_effective_on: '2026-10-01', w4_source_reference: 'Synthetic received form', w4_change_reason: 'Employer delivered updated form' });
    await screen.findByText('Saved employee');
  });

  it('restores evidence metadata and allows an ordinary address-only save after check and uncheck', async () => {
    view(); await screen.findByText('Approved default withholding');
    fireEvent.click(toggle());
    expect(document.querySelector<HTMLInputElement>('[name="w4_effective_on"]')?.value).toBe('');
    fireEvent.click(toggle());
    fireEvent.change(document.querySelector('[name="city"]')!, { target: { value: 'Tamuning' } });
    submit(); await waitFor(() => expect(mocks.update).toHaveBeenCalled());
    expect(mocks.update.mock.calls[0][1]).toMatchObject({ city: 'Tamuning', filing_status: 'single', w4_effective_on: '2026-01-01', w4_source_reference: 'Reviewed default' });
    expect(mocks.update.mock.calls[0][1].w4_election_received).toBeUndefined();
    await screen.findByText('Saved employee');
  });
});
