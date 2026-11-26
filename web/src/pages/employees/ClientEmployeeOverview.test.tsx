// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ClientEmployeeOverview } from './ClientEmployeeOverview';

const apiMocks = vi.hoisted(() => ({ get: vi.fn(), update: vi.fn(), appGet: vi.fn() }));
const companyState = vi.hoisted(() => ({
  activeCompany: { id: 1, test_workspace: true, practice_portal: true, workspace_can_write: false } as Record<string, unknown>,
}));
vi.mock('@/services/api', () => ({ apiClient: { get: apiMocks.appGet }, clientEmployeesApi: { get: apiMocks.get, update: apiMocks.update }, clientPayStubsApi: { history: async () => ({ pay_stubs: [] }) } }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1, activeCompany: companyState.activeCompany }) }));

const dina = {
  id: 2, company_id: 1, first_name: 'Dina', last_name: 'Deposit', status: 'active',
  employment_type: 'hourly', pay_rate: 20, pay_frequency: 'biweekly', email: 'dina.old@example.net', contact_revision: 'rev-1',
  payment_delivery_method: 'direct_deposit', department: { id: 3, name: 'Operations' },
};

function renderOverview(id = 2) {
  return render(
    <MemoryRouter initialEntries={[`/companies/1/employees/${id}/overview`]}>
      <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<ClientEmployeeOverview />} /></Routes>
    </MemoryRouter>,
  );
}

describe('ClientEmployeeOverview', () => {
  beforeEach(() => {
    apiMocks.appGet.mockResolvedValue({ data: { enabled: false, status: 'not_invited' } });
    companyState.activeCompany = { id: 1, test_workspace: true, practice_portal: true, workspace_can_write: false };
  });
  afterEach(() => { cleanup(); vi.clearAllMocks(); });

  it('opens the Contact card from Edit contact details and reloads the app panel after an email change', async () => {
    apiMocks.get.mockResolvedValue({ data: dina });
    apiMocks.update.mockResolvedValue({ data: { ...dina, email: 'dina.new@example.net', contact_revision: 'rev-2' }, contact_warnings: [], change_request: null });
    renderOverview();

    fireEvent.click(await screen.findByRole('button', { name: 'Edit contact details' }));
    const email = screen.getByLabelText('Email for Dina Deposit') as HTMLInputElement;
    expect(document.activeElement).toBe(email);
    const panelReads = apiMocks.appGet.mock.calls.length;

    fireEvent.change(email, { target: { value: 'dina.new@example.net' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Dina Deposit' }));

    await waitFor(() => expect(apiMocks.update).toHaveBeenCalledWith(2, expect.objectContaining({
      email: 'dina.new@example.net', row_revision: 'rev-1', baseline_values: { email: 'dina.old@example.net' }, response_view: 'contact',
    })));
    expect(await screen.findByText('dina.new@example.net')).toBeTruthy();
    await waitFor(() => expect(apiMocks.appGet.mock.calls.length).toBeGreaterThan(panelReads));
  });

  it('hides contact editing on a closed practice copy', async () => {
    companyState.activeCompany = { id: 1, test_workspace: true, practice_portal: true, test_workspace_read_only: true };
    apiMocks.get.mockResolvedValue({ data: dina });
    renderOverview();

    expect(await screen.findByText(/employee app isn't turned on/)).toBeTruthy();
    expect(screen.getByText('dina.old@example.net')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Edit contact details' })).toBeNull();
    expect(screen.queryByRole('link', { name: 'Edit contact details' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Edit contact for Dina Deposit' })).toBeNull();
  });

  it('shows practice clients the profile edit link despite denied staff payroll permission', async () => {
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
    expect(await screen.findByText(/employee app isn't turned on/)).toBeTruthy();
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
