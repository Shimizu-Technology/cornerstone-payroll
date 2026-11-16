// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { Employee } from '@/types';
import { EmployeeForm } from './EmployeeForm';

const mocks = vi.hoisted(() => ({ get: vi.fn(), manage: true, client: false }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1 }, isClient: mocks.client, isSuperAdmin: false }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ refreshCompanies: vi.fn(), activeCompanyId: 1, activeCompany: { id: 1, pay_frequency: 'biweekly', client_capabilities: ['manage_client_configuration'] } }) }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: () => mocks.manage }));
vi.mock('@/hooks/useEmployeeIntakeSettings', () => ({ useEmployeeIntakeSettings: () => ({ settings: { enabled: false }, loading: false }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/employees/EmployeePayItemsPanel', () => ({ EmployeePayItemsPanel: () => null }));
vi.mock('@/components/employees/EmployeeDocumentsPanel', () => ({ EmployeeDocumentsPanel: () => null }));
vi.mock('@/components/employees/EmployeeClassificationTransitionDialog', () => ({ EmployeeClassificationTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeWorkProfilePanel', () => ({ EmployeeWorkProfilePanel: () => null }));
vi.mock('@/services/api', async original => ({
  ...await original<typeof import('@/services/api')>(),
  employeesApi: { get: mocks.get }, clientEmployeesApi: { get: mocks.get },
  departmentsApi: { list: vi.fn().mockResolvedValue({ data: [] }) },
  clientDepartmentsApi: { list: vi.fn().mockResolvedValue({ data: [] }) },
  employeeWageRatesApi: { list: vi.fn().mockResolvedValue({ wage_rates: [] }) },
}));
beforeEach(() => { vi.clearAllMocks(); mocks.manage = true; mocks.client = false; HTMLElement.prototype.scrollIntoView = vi.fn(); });
afterEach(cleanup);
async function view(status: Employee['status']) {
  mocks.get.mockResolvedValue({ data: {
    id: 7, company_id: 1, first_name: 'Avery', last_name: 'Example', status,
    employment_type: 'hourly', pay_rate: 18, hire_date: '2024-01-01',
    termination_date: status === 'terminated' ? '2024-03-15' : null,
    wage_rates: [], default_custom_earnings: [], default_payroll_adjustments: [],
  } });
  render(<MemoryRouter initialEntries={['/companies/1/employees/7/edit']}><Routes>
    <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
  </Routes></MemoryRouter>);
  await screen.findByDisplayValue('Avery');
}
it.each(['inactive', 'terminated'] as const)('offers reactivation for an %s worker and opens the dialog', async status => {
  await view(status);
  expect(screen.getByText(`This employee is ${status}`)).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Reactivate' }));
  expect(await screen.findByRole('dialog', { name: 'Reactivate Avery' })).toBeTruthy();
});
it('does not offer reactivation for an active worker', async () => {
  await view('active');
  expect(screen.queryByRole('button', { name: 'Reactivate' })).toBeNull();
  expect(screen.queryByText(/This employee is/)).toBeNull();
});
it('shows the accountant hint instead of a reactivation action', async () => {
  mocks.manage = false;
  await view('inactive');
  expect(screen.getByText('A manager or admin can reactivate this worker.')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Reactivate' })).toBeNull();
});
it('does not expose the staff reactivation banner to clients', async () => {
  mocks.client = true; mocks.manage = false;
  await view('inactive');
  expect(screen.queryByRole('button', { name: 'Reactivate' })).toBeNull();
  expect(screen.queryByText('This employee is inactive')).toBeNull();
});
