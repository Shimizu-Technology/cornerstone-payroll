// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ClientEmployeeOverview } from './ClientEmployeeOverview';

const apiMocks = vi.hoisted(() => ({ get: vi.fn(), update: vi.fn(), appGet: vi.fn(), appPost: vi.fn() }));
const companyState = vi.hoisted(() => ({
  activeCompany: { id: 1, test_workspace: true, practice_portal: true, workspace_can_write: false } as Record<string, unknown>,
}));
vi.mock('@/services/api', () => ({ apiClient: { get: apiMocks.appGet, post: apiMocks.appPost }, clientEmployeesApi: { get: apiMocks.get, update: apiMocks.update }, clientPayStubsApi: { history: async () => ({ pay_stubs: [] }) } }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1, activeCompany: companyState.activeCompany }) }));

const dina = {
  id: 2, company_id: 1, first_name: 'Dina', last_name: 'Deposit', status: 'active',
  employment_type: 'hourly', pay_rate: 20, pay_frequency: 'biweekly', email: 'dina.old@example.net', contact_revision: 'rev-1',
  payment_delivery_method: 'direct_deposit', department: { id: 3, name: 'Operations' },
};
const readiness = {
  status: 'incomplete', rates_on: '2026-11-30', w4_on: '2026-12-04', direct_deposit_missing_bank_details: true,
  missing_keys: ['tax_form'], reason: "Can't be paid yet: W-4 missing.",
  items: [{ key: 'tax_form', label: 'W-4', complete: false, applicable: true, missing_label: 'W-4 missing' }],
};
const lifecycle = {
  own_record: false, today: '2026-11-28', former_access_years: 2, compensation_default_on: '2026-12-01',
  approved_runs: [{ start_date: '2026-11-10', end_date: '2026-11-18' }],
  last_committed_period_end: '2026-11-12',
  rehire_readiness: { ...readiness, status: 'ready', missing_keys: [], items: [] },
};
const returned = { id: 30, employee_id: 2, event_kind: 'w4_change', return_note: 'Please confirm the signed W-4 date.' };

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

  function clientManaged(employee: Record<string, unknown> = dina, viewer = false) {
    companyState.activeCompany = { id: 1, employee_lifecycle_mode: 'client_managed', client_view_only: viewer };
    apiMocks.get.mockResolvedValue({ data: { ...employee, readiness, lifecycle_edit_context: lifecycle } });
    apiMocks.appGet.mockImplementation(async (url: string) => url === '/client/verification_items'
      ? { data: [returned], meta: { total_pages: 1 } }
      : { data: { enabled: false, status: 'not_invited' } });
    return renderOverview();
  }

  it('preserves approval-first even if a rolled-back employee still has a readiness result', async () => {
    companyState.activeCompany = { id: 1, employee_lifecycle_mode: 'approval_first' };
    apiMocks.get.mockResolvedValue({ data: { ...dina, readiness, lifecycle_edit_context: lifecycle } });
    renderOverview();
    expect(await screen.findByRole('link', { name: 'Edit employee' })).toBeTruthy();
    expect(screen.queryByRole('heading', { name: 'Ready to pay' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Terminate' })).toBeNull();
    expect(apiMocks.appGet).not.toHaveBeenCalledWith('/client/verification_items', expect.anything());
  });

  it('shows period dates and the correct setup section, and replies without disclosing an SSN in a note', async () => {
    clientManaged();
    expect(await screen.findByText(/Pay setup as of Nov 30, 2026/)).toBeTruthy();
    expect(screen.getByText(/can't be paid yet|can’t be paid yet/i)).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Complete setup' }).getAttribute('href')).toMatch(/#employee-tax$/);
    fireEvent.click(await screen.findByRole('button', { name: 'Reply to Cornerstone' }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Reply to Cornerstone' }), { target: { value: 'Date confirmed. 900-11-2233' } });
    apiMocks.appPost.mockResolvedValue({ data: { ...returned, status: 'pending_verification' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send reply' }));
    expect(await screen.findByText('Response sent to Cornerstone for review.')).toBeTruthy();
    expect(apiMocks.appPost).toHaveBeenCalledWith('/client/verification_items/30/respond', { note: 'Date confirmed. •••-••-2233' });
    expect(screen.queryByText(returned.return_note)).toBeNull();
  });

  it('lets a viewer read the checklist and return note with the mutation controls hidden', async () => {
    clientManaged(dina, true);
    expect(await screen.findByText(returned.return_note)).toBeTruthy();
    expect(screen.getByRole('heading', { name: 'Ready to pay' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Reply to Cornerstone' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Terminate' })).toBeNull();
    expect(screen.queryByRole('link', { name: 'Edit employee' })).toBeNull();
  });

  it('previews backdated and re-approval warnings and submits termination with a final-pay note', async () => {
    clientManaged();
    fireEvent.click(await screen.findByRole('button', { name: 'Terminate' }));
    const lastDay = screen.getByLabelText('Last day worked') as HTMLInputElement;
    const terminationDate = screen.getByLabelText('Termination date') as HTMLInputElement;
    expect(terminationDate.max).toBe('2026-11-28');
    fireEvent.change(lastDay, { target: { value: '2026-11-11' } });
    expect(terminationDate.value).toBe('2026-11-11');
    expect(screen.getByText(/already finalized for a period/)).toBeTruthy();
    expect(screen.getByText(/approve the updated payroll again/)).toBeTruthy();
    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'voluntary' } });
    fireEvent.change(screen.getByLabelText(/Final pay and unused PTO/), { target: { value: 'Review unused leave.' } });
    apiMocks.appPost.mockResolvedValue({ data: { ...dina, status: 'terminated' }, message: 'Dina was terminated.', warnings: ['Review finalized payroll.'] });
    apiMocks.get.mockResolvedValue({ data: { ...dina, status: 'terminated', lifecycle_edit_context: lifecycle } });
    fireEvent.click(screen.getAllByRole('button', { name: 'Terminate' }).at(-1)!);
    expect(await screen.findByText('Review finalized payroll.')).toBeTruthy();
    expect(apiMocks.appPost).toHaveBeenCalledWith('/client/employees/2/terminate', { termination: {
      last_worked_on: '2026-11-11', effective_date: '2026-11-11', reason_category: 'voluntary', final_pay_notes: 'Review unused leave.',
    } });
  });

  it('previews the rehire checklist and sends a date after termination', async () => {
    clientManaged({ ...dina, status: 'terminated', termination_date: '2026-11-15' });
    fireEvent.click(await screen.findByRole('button', { name: 'Rehire' }));
    expect(screen.getByRole('heading', { name: 'Ready to pay after rehire' })).toBeTruthy();
    const date = screen.getByLabelText('Rehire date') as HTMLInputElement;
    expect(date.min).toBe('2026-11-16');
    expect(date.max).toBe('2026-11-28');
    apiMocks.appPost.mockResolvedValue({ data: dina, message: 'Dina was rehired.' });
    apiMocks.get.mockResolvedValue({ data: dina });
    fireEvent.click(screen.getAllByRole('button', { name: 'Rehire' }).at(-1)!);
    expect(await screen.findByText('Dina was rehired.')).toBeTruthy();
    expect(apiMocks.appPost).toHaveBeenCalledWith('/client/employees/2/rehire', { rehire: { effective_date: '2026-11-28' } });
  });

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
