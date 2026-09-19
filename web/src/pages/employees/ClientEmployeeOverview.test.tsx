// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ClientEmployeeOverview } from './ClientEmployeeOverview';

const apiMocks = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock('@/services/api', () => ({ clientEmployeesApi: { get: apiMocks.get } }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1 }) }));

describe('ClientEmployeeOverview', () => {
  afterEach(cleanup);

  it('shows how the employee is paid before opening Edit', async () => {
    apiMocks.get.mockResolvedValue({ data: {
      id: 2, company_id: 1, first_name: 'Dina', last_name: 'Deposit', status: 'active',
      employment_type: 'hourly', pay_rate: 20, pay_frequency: 'biweekly',
      payment_delivery_method: 'direct_deposit', department: { id: 3, name: 'Operations' },
    } });
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/overview']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<ClientEmployeeOverview />} /></Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByRole('heading', { name: 'How this employee is paid' })).toBeTruthy();
    expect(screen.getAllByText('Direct deposit').length).toBeGreaterThan(0);
    expect(screen.getByText(/bank transfer is handled and confirmed outside the app/)).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Edit employee' }).getAttribute('href')).toContain('/employees/2/edit');
  });

  it('shows paper check and when a check number is assigned', async () => {
    apiMocks.get.mockResolvedValue({ data: {
      id: 3, company_id: 1, first_name: 'Pat', last_name: 'Check', status: 'active',
      employment_type: 'hourly', pay_rate: 18, pay_frequency: 'weekly',
      payment_delivery_method: 'paper_check',
    } });
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/3/overview']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<ClientEmployeeOverview />} /></Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText(/A check number is assigned when a payable run is committed/)).toBeTruthy();
    expect(screen.getAllByText('Paper check').length).toBeGreaterThan(0);
  });
});
