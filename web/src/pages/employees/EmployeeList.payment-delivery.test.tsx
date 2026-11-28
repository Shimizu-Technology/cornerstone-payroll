// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes, useLocation } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { EmployeeList } from './EmployeeList';

const apiMocks = vi.hoisted(() => ({ listEmployees: vi.fn(), listDepartments: vi.fn(), get: vi.fn() }));
const authMock = vi.hoisted(() => ({ isClient: true, isClientViewer: false }));
const companyMock = vi.hoisted(() => ({ activeCompany: undefined as Record<string, unknown> | undefined }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1 }, isClient: authMock.isClient, isClientViewer: authMock.isClientViewer }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1, activeCompany: companyMock.activeCompany }) }));
vi.mock('@/services/api', () => ({
  apiClient: { get: apiMocks.get },
  employeesApi: { list: apiMocks.listEmployees },
  clientEmployeesApi: { list: apiMocks.listEmployees },
  departmentsApi: { list: apiMocks.listDepartments },
  clientDepartmentsApi: { list: apiMocks.listDepartments },
}));
vi.mock('@/components/employees/EmployeeIntakeSettingsPanel', () => ({ EmployeeIntakeSettingsPanel: () => <p>Employee intake settings</p> }));
vi.mock('@/components/employees/EmployeeOrganizationPanel', () => ({ EmployeeOrganizationPanel: () => <p>Organize employees</p> }));
vi.mock('@/components/employees/EmployeeBulkImportModal', () => ({ EmployeeBulkImportModal: () => null }));

describe('EmployeeList payment delivery', () => {
  afterEach(() => { cleanup(); companyMock.activeCompany = undefined; authMock.isClient = true; authMock.isClientViewer = false; vi.clearAllMocks(); });

  it('lets a practice-copy client add an employee without the staff payroll permission', async () => {
    companyMock.activeCompany = { id: 1, active: true, test_workspace: true, practice_portal: true, workspace_can_write: false };
    apiMocks.listDepartments.mockResolvedValue({ data: [] });
    apiMocks.listEmployees.mockResolvedValue({ data: [], meta: { current_page: 1, total_pages: 1, total_count: 0, per_page: 500 } });
    render(<MemoryRouter initialEntries={['/companies/1/employees']}><Routes><Route path="/companies/:companyId/employees" element={<EmployeeList />} /></Routes></MemoryRouter>);
    expect((await screen.findAllByRole('button', { name: 'Add Employee' })).length).toBeGreaterThan(0);
  });

  it('hides Add Employee from a client whose practice copy is archived', async () => {
    companyMock.activeCompany = { id: 1, active: true, test_workspace: true, practice_portal: true, test_workspace_archived_at: '2026-11-14' };
    apiMocks.listDepartments.mockResolvedValue({ data: [] });
    apiMocks.listEmployees.mockResolvedValue({ data: [], meta: { current_page: 1, total_pages: 1, total_count: 0, per_page: 500 } });
    render(<MemoryRouter initialEntries={['/companies/1/employees']}><Routes><Route path="/companies/:companyId/employees" element={<EmployeeList />} /></Routes></MemoryRouter>);
    expect(await screen.findByText('No employees are available in this workspace.')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Add Employee' })).toBeNull();
  });

  it('shows reviewed and default methods in the list and opens a read-only employee route', async () => {
    apiMocks.listDepartments.mockResolvedValue({ data: [] });
    apiMocks.listEmployees.mockResolvedValue({
      data: [
        { id: 2, first_name: 'Dina', last_name: 'Deposit', employment_type: 'hourly', pay_rate: 20, status: 'active', payment_delivery_method: 'direct_deposit' },
        { id: 3, first_name: 'Pat', last_name: 'Pending', employment_type: 'hourly', pay_rate: 18, status: 'active', payment_delivery_method: null },
      ],
      meta: { current_page: 1, total_pages: 1, total_count: 2, per_page: 500 },
    });
    render(
      <MemoryRouter initialEntries={['/companies/1/employees']}>
        <Routes>
          <Route path="/companies/:companyId/employees" element={<EmployeeList />} />
          <Route path="/companies/:companyId/employees/:id/overview" element={<p>Employee overview route</p>} />
        </Routes>
      </MemoryRouter>,
    );

    expect((await screen.findAllByText('Direct deposit')).length).toBeGreaterThan(0);
    expect(screen.getAllByText('Paper check (default)').length).toBeGreaterThan(0);
    expect(screen.getByText('Not reviewed')).toBeTruthy();
    expect(screen.getByText('Payment method not reviewed')).toBeTruthy();
    fireEvent.click(screen.getAllByRole('button', { name: 'Dina Deposit' })[0]);
    expect(await screen.findByText('Employee overview route')).toBeTruthy();
  });

  it('uses sentence case in both employee lists', async () => {
    apiMocks.listDepartments.mockResolvedValue({ data: [] });
    apiMocks.listEmployees.mockResolvedValue({
      data: [{ id: 2, first_name: 'Dina', last_name: 'Deposit', employment_type: 'hourly', pay_rate: 20, status: 'active', payment_delivery_method: 'direct_deposit' }],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 500 },
    });

    authMock.isClient = true;
    render(<MemoryRouter initialEntries={['/companies/1/employees']}><Routes><Route path="/companies/:companyId/employees" element={<EmployeeList />} /></Routes></MemoryRouter>);
    const clientRateButton = await screen.findByRole('button', { name: 'Pay rate' });
    expect(clientRateButton.className.split(/\s+/)).not.toContain('uppercase');
    cleanup();

    authMock.isClient = false;
    render(<MemoryRouter initialEntries={['/companies/1/employees']}><Routes><Route path="/companies/:companyId/employees" element={<EmployeeList />} /></Routes></MemoryRouter>);
    const staffRateButton = await screen.findByRole('button', { name: 'Pay rate' });
    expect(staffRateButton.className.split(/\s+/)).not.toContain('uppercase');
    expect(screen.getByRole('button', { name: 'Employee' }).className.split(/\s+/)).not.toContain('uppercase');
  });
});


describe('Employee list lifecycle modes', () => {
  afterEach(() => {
    cleanup();
    companyMock.activeCompany = undefined;
    authMock.isClientViewer = false;
    vi.clearAllMocks();
  });

  function CurrentSearch() {
    return <output aria-label="Roster query">{useLocation().search}</output>;
  }

  function renderList(mode: string, viewer = false) {
    companyMock.activeCompany = { id: 1, active: true, employee_lifecycle_mode: mode };
    authMock.isClientViewer = viewer;
    apiMocks.listDepartments.mockResolvedValue({ data: [] });
    apiMocks.listEmployees.mockResolvedValue({
      data: [{
        id: 2, first_name: 'Dina', last_name: 'Deposit', employment_type: 'hourly', pay_rate: 20, status: 'active',
        payment_delivery_method: null, readiness: { status: 'incomplete', missing_keys: ['payment_method'], items: [
          { key: 'payment_method', complete: false, applicable: true },
        ] },
      }],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 500 },
    });
    return render(<MemoryRouter initialEntries={['/companies/1/employees?status=active']}>
      <EmployeeList /><CurrentSearch />
    </MemoryRouter>);
  }

  it('keeps approval-first intake and hides lifecycle controls even for a rolled-back record', async () => {
    renderList('approval_first');
    await screen.findAllByRole('button', { name: 'Dina Deposit' });
    expect(screen.getByText('Employee intake settings')).toBeTruthy();
    expect(screen.queryByRole('heading', { name: /Needs attention/ })).toBeNull();
    expect(screen.queryByLabelText('Cornerstone review')).toBeNull();
    expect(screen.queryByText(/Incomplete.*paid yet/)).toBeNull();
    expect(screen.queryByText('Not chosen')).toBeNull();
    expect(apiMocks.get).not.toHaveBeenCalledWith('/client/verification_items', expect.anything());
  });

  it('retries the verification count and filters the roster across all statuses for a manager', async () => {
    apiMocks.get.mockRejectedValueOnce(new Error('Offline')).mockResolvedValueOnce({ data: [], meta: { total_count: 3 } });
    renderList('client_managed');
    const feedback = await screen.findByRole('alert');
    const retry = within(feedback).getByRole('button', { name: 'Try again' });
    expect(retry.parentElement?.classList.contains('gap-2')).toBe(true);
    fireEvent.click(retry);
    const banner = await screen.findByRole('heading', { name: 'Needs attention 3' });
    expect(banner).toBeTruthy();
    expect(apiMocks.get).toHaveBeenCalledTimes(2);
    expect(apiMocks.get).toHaveBeenCalledWith('/client/verification_items', expect.objectContaining({ status: 'returned_to_client', per_page: 1 }));
    expect((await screen.findAllByText(/Incomplete.*paid yet/)).length).toBe(2);
    expect(screen.getAllByText('Not chosen')).toHaveLength(2);
    expect(screen.queryByText('Employee intake settings')).toBeNull();
    expect(screen.getByText('Organize employees')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Show employees' }));
    await waitFor(() => expect(apiMocks.listEmployees).toHaveBeenLastCalledWith(expect.objectContaining({ status: undefined, needs_attention: true })));
    expect((screen.getByLabelText('Employee status') as HTMLSelectElement).value).toBe('all');
    expect(screen.getByLabelText('Roster query').textContent).toContain('needs_attention=true');
  });

  it('lets client viewers see verification information without mutation controls', async () => {
    apiMocks.get.mockResolvedValueOnce({ data: [], meta: { total_count: 1 } });
    renderList('client_managed', true);
    expect(await screen.findByRole('heading', { name: 'Needs attention 1' })).toBeTruthy();
    expect((await screen.findAllByText(/Incomplete.*paid yet/)).length).toBe(2);
    expect(screen.queryByRole('button', { name: 'Add Employee' })).toBeNull();
    expect(screen.queryByText('Organize employees')).toBeNull();
  });
});
