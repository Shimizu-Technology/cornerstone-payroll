// @vitest-environment jsdom
import { act, cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { CompanyProvider, useCompany } from '@/contexts/CompanyContext';
import { EmployeeForm } from './EmployeeForm';

const mocks = vi.hoisted(() => ({
  selected: 1, listCompanies: vi.fn(), create: vi.fn(), listRates: vi.fn(), createRate: vi.fn(),
  departments: vi.fn(), fields: vi.fn(),
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({
  user: { id: 1, company_id: 1, organization_id: 1 }, isAuthenticated: true, isLoading: false,
  isClient: false, isSuperAdmin: true, isManager: true,
}) }));
vi.mock('@/hooks/useEmployeeIntakeSettings', () => ({ useEmployeeIntakeSettings: () => ({
  settings: { enabled: true }, loading: false,
}) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return { ...actual,
    companiesApi: { ...actual.companiesApi, list: mocks.listCompanies,
      getActiveCompanyId: () => mocks.selected,
      switchCompany: (id: number) => { mocks.selected = id; },
    },
    employeesApi: { ...actual.employeesApi, create: mocks.create },
    employeeWageRatesApi: { ...actual.employeeWageRatesApi, list: mocks.listRates, create: mocks.createRate },
    departmentsApi: { list: mocks.departments }, payrollFieldsApi: { list: mocks.fields },
  };
});

function response(firstCount = 0) {
  return { companies: [
    { id: 1, organization_id: 1, name: 'Synthetic One', active_employees: firstCount, pay_frequency: 'biweekly' },
    { id: 2, organization_id: 1, name: 'Synthetic Two', active_employees: 2, pay_frequency: 'biweekly' },
  ], current_company_id: 1, can_manage_clients: true, can_switch_company: true };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
function Summary() {
  const { activeCompany, switchCompany } = useCompany();
  const navigate = useNavigate();
  return <>
    <output aria-label="Selected client summary">{activeCompany?.id}:{activeCompany?.active_employees}</output>
    <button onClick={() => switchCompany(2)}>Switch to second client</button>
    <button onClick={() => navigate('/companies/2/employees/new')}>New employee in second client</button>
  </>;
}
function view() {
  render(<MemoryRouter initialEntries={['/companies/1/employees/new']}><CompanyProvider>
    <Summary /><Routes>
      <Route path="/companies/:companyId/employees/new" element={<EmployeeForm />} />
      <Route path="/companies/1/employees/20/overview" element={<p>Saved employee 20 overview</p>} />
    </Routes>
  </CompanyProvider></MemoryRouter>);
}
async function createDraft(user: ReturnType<typeof userEvent.setup>) {
  await screen.findByText('1:0');
  await user.type(screen.getByLabelText(/^First Name/), 'Synthetic');
  await user.type(screen.getByLabelText(/^Last Name/), 'Summary');
  await user.clear(screen.getByLabelText(/^Hourly Rate/));
  await user.type(screen.getByLabelText(/^Hourly Rate/), '25');
  await user.click(screen.getByRole('button', { name: 'Create Employee' }));
}
beforeEach(() => {
  vi.resetAllMocks(); mocks.selected = 1;
  mocks.listCompanies.mockResolvedValue(response());
  mocks.create.mockResolvedValue({ data: { id: 20 } });
  mocks.departments.mockResolvedValue({ data: [] }); mocks.fields.mockResolvedValue({ payroll_fields: [] });
  mocks.listRates.mockResolvedValue({ wage_rates: [] }); mocks.createRate.mockResolvedValue({});
  HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(cleanup);

it('refreshes the real client summary once after saving an employee without a page reload', async () => {
  mocks.listCompanies.mockResolvedValueOnce(response()).mockResolvedValueOnce(response(1));
  const user = userEvent.setup(); view(); await createDraft(user);
  expect(await screen.findByText('Saved employee 20 overview')).toBeTruthy();
  expect(await screen.findByText('1:1')).toBeTruthy();
  expect(mocks.create).toHaveBeenCalledTimes(1);
  expect(mocks.create).toHaveBeenCalledWith(expect.objectContaining({ company_id: 1, first_name: 'Synthetic', last_name: 'Summary' }));
  expect(mocks.listCompanies).toHaveBeenCalledTimes(2);
});

it('does not delay saved navigation or replace a newly selected client and draft when summary refresh finishes', async () => {
  const pending = deferred<ReturnType<typeof response>>();
  mocks.listCompanies.mockResolvedValueOnce(response()).mockReturnValueOnce(pending.promise);
  const user = userEvent.setup(); view(); await createDraft(user);
  expect(await screen.findByText('Saved employee 20 overview')).toBeTruthy();
  await user.click(screen.getByRole('button', { name: 'Switch to second client' }));
  await user.click(screen.getByRole('button', { name: 'New employee in second client' }));
  await user.type(screen.getByLabelText(/^First Name/), 'Unsubmitted next draft');
  await act(async () => { pending.resolve(response(1)); });
  expect(screen.getByText('2:2')).toBeTruthy();
  expect((screen.getByLabelText(/^First Name/) as HTMLInputElement).value).toBe('Unsubmitted next draft');
  expect(mocks.selected).toBe(2);
  expect(mocks.create).toHaveBeenCalledTimes(1);
  expect(mocks.listCompanies).toHaveBeenCalledTimes(2);
});

it('retains successful save navigation when summary loading and its existing single retry fail', async () => {
  mocks.listCompanies.mockResolvedValueOnce(response()).mockRejectedValue(new Error('Summary unavailable'));
  const user = userEvent.setup(); view(); await createDraft(user);
  expect(await screen.findByText('Saved employee 20 overview')).toBeTruthy();
  await waitFor(() => expect(mocks.listCompanies).toHaveBeenCalledTimes(3), { timeout: 3000 });
  expect(screen.getByText('1:0')).toBeTruthy();
  expect(screen.getByText('Saved employee 20 overview')).toBeTruthy();
  expect(mocks.create).toHaveBeenCalledTimes(1);
});

it('preserves a rejected employee draft without refreshing or pretending that a new employee was saved', async () => {
  mocks.create.mockRejectedValue(new Error('Employee create rejected'));
  const user = userEvent.setup(); view(); await createDraft(user);
  expect(await screen.findByText('Employee create rejected')).toBeTruthy();
  expect((screen.getByLabelText(/^First Name/) as HTMLInputElement).value).toBe('Synthetic');
  expect((screen.getByLabelText(/^Last Name/) as HTMLInputElement).value).toBe('Summary');
  expect(screen.queryByText('Saved employee 20 overview')).toBeNull();
  expect(mocks.listCompanies).toHaveBeenCalledTimes(1);
});

it('ignores a late create completion after the operator switches client context', async () => {
  const pending = deferred<{ data: { id: number } }>(); mocks.create.mockReturnValue(pending.promise);
  const user = userEvent.setup(); view(); await createDraft(user);
  expect(mocks.create).toHaveBeenCalledTimes(1);
  await user.click(screen.getByRole('button', { name: 'Switch to second client' }));
  await act(async () => { pending.resolve({ data: { id: 20 } }); });
  expect(screen.getByText('2:2')).toBeTruthy();
  expect(screen.queryByText('Saved employee 20 overview')).toBeNull();
  expect(mocks.listCompanies).toHaveBeenCalledTimes(1);
});
