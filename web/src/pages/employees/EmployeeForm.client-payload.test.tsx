// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, type RenderResult } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeForm } from './EmployeeForm';

const mocks = vi.hoisted(() => ({ get: vi.fn(), update: vi.fn(), departments: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1, role: 'client' }, isClient: true, isSuperAdmin: false, isManager: false }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ refreshCompanies: async () => {}, activeCompanyId: 1 }) }));
vi.mock('@/hooks/useEmployeeIntakeSettings', () => ({ useEmployeeIntakeSettings: () => ({ settings: { enabled: false }, loading: false }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/employees/EmployeeDocumentsPanel', () => ({ EmployeeDocumentsPanel: () => null }));
vi.mock('@/components/employees/EmployeeClassificationTransitionDialog', () => ({ EmployeeClassificationTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeStatusTransitionDialog', () => ({ EmployeeStatusTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeWorkProfilePanel', () => ({ EmployeeWorkProfilePanel: () => null }));
vi.mock('@/components/employees/EmployeePayItemsPanel', () => ({ EmployeePayItemsPanel: () => null }));
vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return { ...actual, clientEmployeesApi: { ...actual.clientEmployeesApi, get: mocks.get, update: mocks.update },
    clientDepartmentsApi: { ...actual.clientDepartmentsApi, list: mocks.departments } };
});

const base = { pay_frequency: 'biweekly', filing_status: 'single', allowances: 0, additional_withholding: 0, w4_dependent_credit: 0,
  w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0, w4_form_version: 2026,
  w4_effective_on: '2026-01-01', w4_signed_on: null, w4_source_reference: '', hire_date: '2025-01-01', ssn_last_four: '6789',
  address_line1: '100 Synthetic Lane', city: 'Hagåtña', state: 'GU', zip: '96910', status: 'active',
  default_payroll_adjustments: [], default_custom_earnings: [], wage_rates: [] };
const hourly = { ...base, id: 7, first_name: 'Lino', last_name: 'Quinata', employment_type: 'hourly', salary_type: 'annual', pay_rate: 12,
  contractor_type: null, contractor_pay_type: null, business_name: null };
const business = { ...base, id: 8, first_name: 'Tano', last_name: 'Builders', employment_type: 'contractor', pay_rate: 500,
  contractor_type: 'business', contractor_pay_type: 'flat_fee', business_name: 'Tano Builders LLC', ssn_last_four: null,
  contractor_ein_last_four: '4321' };

function view(id: number): RenderResult {
  return render(<MemoryRouter initialEntries={[`/companies/1/employees/${id}/edit`]}><Routes>
    <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
    <Route path="*" element={<p>Left the form</p>} />
  </Routes></MemoryRouter>);
}
function submit(): void { fireEvent.submit(document.getElementById('employee-form')!); }

beforeEach(() => {
  vi.clearAllMocks();
  mocks.departments.mockResolvedValue({ data: [] });
  mocks.update.mockResolvedValue({ data: hourly, change_request: null, message: 'Saved' });
  HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(cleanup);

describe('Client employee form payload', () => {
  it('leaves contractor defaults out of a W-2 worker update', async () => {
    mocks.get.mockResolvedValue({ data: hourly });
    view(7);
    await waitFor(() => expect(document.querySelector<HTMLInputElement>('[name="city"]')?.value).toBe('Hagåtña'));
    fireEvent.change(document.querySelector('[name="city"]')!, { target: { value: 'Tamuning' } });
    submit();
    await waitFor(() => expect(mocks.update).toHaveBeenCalled());
    const payload = mocks.update.mock.calls[0][1];
    expect(payload.city).toBe('Tamuning');
    for (const key of ['contractor_type', 'contractor_pay_type', 'business_name', 'contractor_ein', 'w9_on_file']) {
      expect(payload[key]).toBeUndefined();
    }
  });

  it('shows the saved EIN last four and keeps it when the field is left blank', async () => {
    mocks.get.mockResolvedValue({ data: business });
    mocks.update.mockResolvedValue({ data: business, change_request: null, message: 'Saved' });
    view(8);
    expect(await screen.findByText(/Saved EIN ending in 4321/)).toBeTruthy();
    const ein = document.querySelector<HTMLInputElement>('[name="contractor_ein"]')!;
    expect(ein.value).toBe('');
    expect(ein.placeholder).toContain('4321');
    expect(ein.required).toBe(false);
    submit();
    await waitFor(() => expect(mocks.update).toHaveBeenCalled());
    const payload = mocks.update.mock.calls[0][1];
    expect(payload.contractor_ein).toBeUndefined();
    expect(payload.contractor_type).toBe('business');
  });
});
