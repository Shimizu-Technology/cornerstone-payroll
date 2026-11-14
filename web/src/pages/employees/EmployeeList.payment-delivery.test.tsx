// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { EmployeeList } from './EmployeeList';

const apiMocks = vi.hoisted(() => ({ listEmployees: vi.fn(), listDepartments: vi.fn() }));
const companyMock = vi.hoisted(() => ({ activeCompany: undefined as Record<string, unknown> | undefined }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1 }, isClient: true }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1, activeCompany: companyMock.activeCompany }) }));
vi.mock('@/services/api', () => ({
  employeesApi: { list: apiMocks.listEmployees },
  clientEmployeesApi: { list: apiMocks.listEmployees },
  departmentsApi: { list: apiMocks.listDepartments },
  clientDepartmentsApi: { list: apiMocks.listDepartments },
}));
vi.mock('@/components/employees/EmployeeBulkImportModal', () => ({ EmployeeBulkImportModal: () => null }));

describe('EmployeeList payment delivery', () => {
  afterEach(() => { cleanup(); companyMock.activeCompany = undefined; });

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
});
