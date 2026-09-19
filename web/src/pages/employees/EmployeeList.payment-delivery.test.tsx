// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { EmployeeList } from './EmployeeList';

const apiMocks = vi.hoisted(() => ({ listEmployees: vi.fn(), listDepartments: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1 }, isClient: true }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1 }) }));
vi.mock('@/services/api', () => ({
  employeesApi: { list: apiMocks.listEmployees },
  clientEmployeesApi: { list: apiMocks.listEmployees },
  departmentsApi: { list: apiMocks.listDepartments },
  clientDepartmentsApi: { list: apiMocks.listDepartments },
}));
vi.mock('@/components/employees/EmployeeBulkImportModal', () => ({ EmployeeBulkImportModal: () => null }));

describe('EmployeeList payment delivery', () => {
  afterEach(cleanup);

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
    fireEvent.click(screen.getAllByRole('button', { name: 'Dina Deposit' })[0]);
    expect(await screen.findByText('Employee overview route')).toBeTruthy();
  });
});
