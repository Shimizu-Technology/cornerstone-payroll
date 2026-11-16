// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { Employee } from '@/types';
import { EmployeeForm } from './EmployeeForm';

const allStaffCapabilities = ['manage_client_configuration', 'manage_employee_status'];
const mocks = vi.hoisted(() => ({ get: vi.fn(), capabilities: [] as string[], client: false }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1 }, isClient: mocks.client, isSuperAdmin: false }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ refreshCompanies: vi.fn(), activeCompanyId: 1, activeCompany: { id: 1, pay_frequency: 'biweekly', client_capabilities: ['manage_client_configuration'] } }) }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: (capability: string) => mocks.capabilities.includes(capability) }));
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
beforeEach(() => { vi.clearAllMocks(); mocks.capabilities = [...allStaffCapabilities]; mocks.client = false; HTMLElement.prototype.scrollIntoView = vi.fn(); });
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
it('lets an accountant reactivate an inactive worker', async () => {
  mocks.capabilities = ['manage_employee_status'];
  await view('inactive');
  fireEvent.click(screen.getByRole('button', { name: 'Reactivate' }));
  expect(await screen.findByRole('dialog', { name: 'Reactivate Avery' })).toBeTruthy();
});
it('lets an accountant mark a worker inactive but not terminate them', async () => {
  mocks.capabilities = ['manage_employee_status'];
  await view('active');
  expect(screen.getByRole('button', { name: 'Mark inactive' })).toBeTruthy();
  expect(screen.queryByRole('button', { name: /Terminate/ })).toBeNull();
  expect(screen.getByText(/A manager or admin can terminate a worker whose employment has ended/)).toBeTruthy();
});
it('offers managers both Mark inactive and Terminate', async () => {
  await view('active');
  expect(screen.getByRole('button', { name: 'Mark inactive' })).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Terminate Employee' })).toBeTruthy();
});
it('explains when the operator has no access to change status', async () => {
  mocks.capabilities = [];
  await view('inactive');
  expect(screen.getByText("You don't have access to reactivate this worker.")).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Reactivate' })).toBeNull();
});
it('does not expose the staff reactivation banner to clients', async () => {
  mocks.client = true; mocks.capabilities = [];
  await view('inactive');
  expect(screen.queryByRole('button', { name: 'Reactivate' })).toBeNull();
  expect(screen.queryByText('This employee is inactive')).toBeNull();
});
it('leaves rehiring a terminated worker to managers and admins', async () => {
  mocks.capabilities = ['manage_employee_status'];
  await view('terminated');
  expect(screen.getByText('A manager or admin can rehire this worker.')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Reactivate' })).toBeNull();
});
it('tells an accountant marking a worker inactive who can terminate', async () => {
  mocks.capabilities = ['manage_employee_status'];
  await view('active');
  fireEvent.click(screen.getByRole('button', { name: 'Mark inactive' }));
  const dialog = await screen.findByRole('dialog', { name: 'Mark Avery inactive' });
  expect(dialog.textContent).toContain('A manager or admin can terminate a worker whose employment has ended.');
  expect(dialog.textContent).not.toContain('Use Terminate');
});
