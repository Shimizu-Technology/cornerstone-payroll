// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { EmployeeForm } from './EmployeeForm';
import { ApiError } from '@/services/api';

const mocks = vi.hoisted(() => ({
  company: undefined as { id: number; pay_frequency: string; workspace_can_write?: boolean; test_workspace?: boolean } | undefined,
  enabled: false, create: vi.fn(), reload: vi.fn(), departments: vi.fn(), fields: vi.fn(),
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1 }, isClient: false, isSuperAdmin: true, isManager: true }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1, activeCompany: mocks.company }) }));
vi.mock('@/hooks/useEmployeeIntakeSettings', () => ({ useEmployeeIntakeSettings: () => ({ settings: { enabled: mocks.enabled }, loading: false, reload: mocks.reload }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return { ...actual, employeesApi: { ...actual.employeesApi, create: mocks.create },
    departmentsApi: { list: mocks.departments }, payrollFieldsApi: { list: mocks.fields } };
});

function form() {
  return <MemoryRouter initialEntries={['/companies/1/employees/new']}><Routes>
    <Route path="/companies/:companyId/employees/new" element={<EmployeeForm />} />
  </Routes></MemoryRouter>;
}
beforeEach(() => {
  vi.clearAllMocks(); mocks.company = { id: 1, pay_frequency: 'semimonthly' }; mocks.enabled = false;
  mocks.departments.mockResolvedValue({ data: [] }); mocks.fields.mockResolvedValue({ payroll_fields: [] });
  mocks.reload.mockResolvedValue(undefined); HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(cleanup);

it('defaults to the selected client frequency and retains entered fields when metadata arrives later', async () => {
  mocks.company = undefined;
  const view = render(form());
  fireEvent.change(screen.getByLabelText(/First Name/), { target: { value: 'Synthetic' } });
  mocks.company = { id: 1, pay_frequency: 'semimonthly' }; view.rerender(form());
  await waitFor(() => expect((screen.getByLabelText(/Pay Frequency/) as HTMLSelectElement).value).toBe('semimonthly'));
  expect((screen.getByLabelText(/First Name/) as HTMLInputElement).value).toBe('Synthetic');
  fireEvent.change(screen.getByLabelText(/Pay Frequency/), { target: { value: 'weekly' } });
  mocks.company = { id: 1, pay_frequency: 'monthly' }; view.rerender(form());
  expect((screen.getByLabelText(/Pay Frequency/) as HTMLSelectElement).value).toBe('weekly');
});

it('associates visible employee labels and gives added wage rows distinct labels and IDs', () => {
  render(form()); fireEvent.click(screen.getByRole('button', { name: 'Add Rate' }));
  const ids = [...document.querySelectorAll<HTMLInputElement>('input[id], select[id]')].map((node) => node.id);
  expect(new Set(ids).size).toBe(ids.length);
  for (const label of document.querySelectorAll<HTMLLabelElement>('label')) {
    expect(label.control, label.textContent || 'unnamed label').toBeTruthy();
  }
});

it('keeps the entered draft and reloads intake policy after a server-side expiration rejection', async () => {
  mocks.enabled = true;
  mocks.create.mockRejectedValue(new ApiError('Incomplete employee entry has expired', 422,
    { hire_date: ["can't be blank"] }, { code: 'employee_intake_expired' }));
  render(form());
  fireEvent.change(screen.getByLabelText(/First Name/), { target: { value: 'Synthetic' } });
  fireEvent.change(screen.getByLabelText(/Last Name/), { target: { value: 'Retained' } });
  const rate = screen.getByLabelText(/Hourly Rate/);
  fireEvent.change(rate, { target: { value: '25' } });
  fireEvent.submit(document.getElementById('employee-form')!);
  await waitFor(() => expect(mocks.create).toHaveBeenCalled());
  expect(await screen.findByText(/Incomplete employee entry has expired\. hire date:/)).toBeTruthy();
  expect(mocks.reload).toHaveBeenCalledTimes(1);
  expect((screen.getByLabelText(/First Name/) as HTMLInputElement).value).toBe('Synthetic');
  expect((screen.getByLabelText(/Last Name/) as HTMLInputElement).value).toBe('Retained');
});

it('guards a direct reviewer form route and retains an opened draft through temporary access loss', () => {
  const view = render(form());
  fireEvent.change(screen.getByLabelText(/First Name/), { target: { value: 'Retained draft' } });
  mocks.company = { id: 1, pay_frequency: 'semimonthly', test_workspace: true, workspace_can_write: false };
  view.rerender(form());
  expect(screen.getByRole('region', { name: 'Read-only employee access' })).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Create Employee' })).toBeNull();
  expect(mocks.create).not.toHaveBeenCalled();
  mocks.company = { ...mocks.company, workspace_can_write: true };
  view.rerender(form());
  expect((screen.getByLabelText(/First Name/) as HTMLInputElement).value).toBe('Retained draft');
});
