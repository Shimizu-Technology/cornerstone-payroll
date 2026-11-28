// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import { ClientEmployeeOverview } from './ClientEmployeeOverview';

const apiMocks = vi.hoisted(() => ({ get: vi.fn(), update: vi.fn(), appGet: vi.fn(), appPost: vi.fn(), refresh: vi.fn() }));
const companyState = vi.hoisted(() => ({
  activeCompany: { id: 1, test_workspace: true, practice_portal: true, workspace_can_write: false } as Record<string, unknown>,
}));
vi.mock('@/services/api', () => ({ apiClient: { get: apiMocks.appGet, post: apiMocks.appPost }, clientEmployeesApi: { get: apiMocks.get, update: apiMocks.update }, clientPayStubsApi: { history: async () => ({ pay_stubs: [] }) } }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1, activeCompany: companyState.activeCompany, refreshCompanies: apiMocks.refresh }) }));

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
      <FeedbackProvider><Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<ClientEmployeeOverview />} /></Routes></FeedbackProvider>
    </MemoryRouter>,
  );
}

describe('ClientEmployeeOverview', () => {
  beforeEach(() => {
    apiMocks.refresh.mockResolvedValue(undefined);
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
    apiMocks.appPost.mockResolvedValue({ data: { ...dina, status: 'terminated', lifecycle_edit_context: lifecycle }, message: 'Dina was terminated.', warnings: ['Review finalized payroll.'] });
    fireEvent.click(screen.getAllByRole('button', { name: 'Terminate' }).at(-1)!);
    expect(await screen.findByText('Review finalized payroll.')).toBeTruthy();
    expect(await screen.findByRole('button', { name: 'Rehire' })).toBeTruthy();
    expect(document.activeElement?.textContent).toBe('Dina was terminated.');
    expect(apiMocks.get).toHaveBeenCalledOnce();
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
    apiMocks.appPost.mockResolvedValue({ data: { ...dina, lifecycle_edit_context: lifecycle }, message: 'Dina was rehired.' });
    fireEvent.click(screen.getAllByRole('button', { name: 'Rehire' }).at(-1)!);
    expect(await screen.findByText('Dina was rehired.')).toBeTruthy();
    expect(await screen.findByRole('button', { name: 'Terminate' })).toBeTruthy();
    expect(apiMocks.get).toHaveBeenCalledOnce();
    expect(apiMocks.appPost).toHaveBeenCalledWith('/client/employees/2/rehire', { rehire: { effective_date: '2026-11-28' } });
  });

  it('lets termination be set first and explains invalid date combinations inline', async () => {
    clientManaged({ ...dina, hire_date: '2026-10-01' });
    fireEvent.click(await screen.findByRole('button', { name: 'Terminate' }));
    const dialog = screen.getByRole('dialog');
    const worked = within(dialog).getByLabelText('Last day worked') as HTMLInputElement;
    const termination = within(dialog).getByLabelText('Termination date') as HTMLInputElement;
    const confirm = within(dialog).getByRole('button', { name: 'Terminate' }) as HTMLButtonElement;
    expect(termination.min).toBe('2026-10-01');
    fireEvent.change(termination, { target: { value: '2026-11-24' } });
    expect(worked.value).toBe('2026-11-24');
    fireEvent.change(within(dialog).getByLabelText('Reason'), { target: { value: 'voluntary' } });
    expect(confirm.disabled).toBe(false);

    fireEvent.change(worked, { target: { value: '2026-11-25' } });
    expect(termination.min).toBe('2026-11-25');
    expect(termination.getAttribute('aria-invalid')).toBe('true');
    expect(within(dialog).getByText('The termination date must be on or after the last day worked.')).toBeTruthy();
    expect(confirm.disabled).toBe(true);
    fireEvent.change(worked, { target: { value: '2026-11-29' } });
    expect(termination.min).toBe('2026-10-01');
    expect(within(dialog).getByText('The last day worked cannot be in the future.')).toBeTruthy();
    fireEvent.change(termination, { target: { value: '' } });
    expect(within(dialog).getByText('Enter a termination date.')).toBeTruthy();
  });

  it('explains why an incomplete future hire cannot be terminated', async () => {
    clientManaged({ ...dina, hire_date: '2026-12-01' });
    fireEvent.click(await screen.findByRole('button', { name: 'Terminate' }));
    const dialog = within(screen.getByRole('dialog'));
    expect(dialog.getByText(/Update the hire date before recording a termination/)).toBeTruthy();
    expect(dialog.queryByText(/rehire date/i)).toBeNull();
    expect((dialog.getByRole('button', { name: 'Terminate' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('routes a missing legal business name to the tax section independent of the wording', async () => {
    apiMocks.get.mockResolvedValueOnce({ data: {
      ...dina, employment_type: 'contractor', contractor_type: 'business', business_name: null,
      readiness: { ...readiness, items: [
        { key: 'legal_name', label: 'Legal name', applicable: true, complete: false, missing_label: 'Add the legal entity name' },
      ] },
    } });
    clientManaged();
    expect((await screen.findByRole('link', { name: 'Complete setup' })).getAttribute('href')).toMatch(/#employee-tax$/);
  });

  it('refreshes company settings after a lifecycle conflict on a transition or reply', async () => {
    clientManaged();
    const failure = Object.assign(new Error('Mode changed'), { data: { code: 'lifecycle_mode_changed' } });
    apiMocks.appPost.mockRejectedValue(failure);
    fireEvent.click(await screen.findByRole('button', { name: 'Terminate' }));
    const dialog = within(screen.getByRole('dialog'));
    fireEvent.change(dialog.getByLabelText('Reason'), { target: { value: 'voluntary' } });
    fireEvent.click(dialog.getByRole('button', { name: 'Terminate' }));
    expect(await dialog.findByText(/employee settings changed/)).toBeTruthy();
    expect(apiMocks.refresh).toHaveBeenCalledTimes(1);
    fireEvent.click(dialog.getByRole('button', { name: 'Cancel' }));

    fireEvent.click(await screen.findByRole('button', { name: 'Reply to Cornerstone' }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Reply to Cornerstone' }), { target: { value: 'Confirmed.' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send reply' }));
    await waitFor(() => expect(apiMocks.refresh).toHaveBeenCalledTimes(2));
  });

  it('disables returned-item retry during the request and announces each of two replies', async () => {
    clientManaged();
    let resolveRetry: (value: unknown) => void = () => {};
    const queue = vi.fn().mockRejectedValueOnce(new Error('Temporarily unavailable'))
      .mockImplementationOnce(() => new Promise((resolve) => { resolveRetry = resolve; }));
    apiMocks.appGet.mockImplementation(async (url: string) => url === '/client/verification_items'
      ? queue()
      : { data: { enabled: false, status: 'not_invited' } });
    apiMocks.appPost.mockResolvedValue({ data: { status: 'pending_verification' } });
    fireEvent.click(await screen.findByRole('button', { name: 'Try again' }));
    expect((screen.getByRole('button', { name: 'Checking…' }) as HTMLButtonElement).disabled).toBe(true);
    resolveRetry({ data: [returned, { ...returned, id: 31, event_kind: 'profile_change' }], meta: { total_pages: 1 } });

    const toast = 'Response sent to Cornerstone for review.';
    for (const id of [30, 31]) {
      fireEvent.click((await screen.findAllByRole('button', { name: 'Reply to Cornerstone' }))[0]);
      fireEvent.change(screen.getByRole('textbox', { name: 'Reply to Cornerstone' }), { target: { value: 'Confirmed.' } });
      fireEvent.click(screen.getByRole('button', { name: 'Send reply' }));
      const dismiss = await screen.findByRole('button', { name: `Dismiss notification: ${toast}` });
      expect(apiMocks.appPost).toHaveBeenCalledWith(`/client/verification_items/${id}/respond`, { note: 'Confirmed.' });
      fireEvent.click(dismiss);
    }
    expect(screen.queryByRole('heading', { name: 'Needs attention' })).toBeNull();
  });

  it('shows the own-record review rules and links a queued email change instead of marking it saved', async () => {
    const profile = { ...dina, readiness, lifecycle_edit_context: { ...lifecycle, own_record: true } };
    apiMocks.get.mockResolvedValueOnce({ data: profile });
    clientManaged();
    apiMocks.get.mockResolvedValue({ data: profile });
    apiMocks.update.mockResolvedValue({ data: dina, change_request: { id: 41, profile_address: false } });
    expect(await screen.findByText(/Address-only changes can be reviewed by another manager or Cornerstone/)).toBeTruthy();
    expect(screen.getByText(/payment method, name, birth date, hire date, or email/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Edit contact for Dina Deposit' }));
    fireEvent.change(screen.getByLabelText('Email for Dina Deposit'), { target: { value: 'dina.review@example.test' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Dina Deposit' }));

    const request = await screen.findByRole('link', { name: 'Sent to Cornerstone for review' });
    expect(request.getAttribute('href')).toBe('/change-requests?request_id=41');
    expect(screen.getByText('dina.old@example.net')).toBeTruthy();
    expect(screen.queryByText(/^Saved$/)).toBeNull();
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
        <FeedbackProvider><Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<ClientEmployeeOverview />} /></Routes></FeedbackProvider>
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
        <FeedbackProvider><Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<ClientEmployeeOverview />} /></Routes></FeedbackProvider>
      </MemoryRouter>,
    );

    expect(await screen.findByText(/A check number is assigned when a payable run is committed/)).toBeTruthy();
    expect(screen.getAllByText('Paper check').length).toBeGreaterThan(0);
  });
});
