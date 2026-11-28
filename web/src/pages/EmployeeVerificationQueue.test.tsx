// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes, useLocation } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { VerificationDetails } from '@/services/staff-employee-lifecycle';
import { EmployeeVerificationQueue } from './EmployeeVerificationQueue';

const mocks = vi.hoisted(() => ({ granted: true, audit: true, managed: true, companyReadOnly: false, list: vi.fn(), get: vi.fn(), verify: vi.fn(), sendBack: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ hasCapability: (capability: string) => capability !== 'view_audit_history' || mocks.audit }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({
  activeCompany: { id: 2, workspace_can_write: !mocks.companyReadOnly, client_managed_employee_lifecycle: mocks.managed }, activeCompanyId: 2,
}) }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({
  useSelectedCompanyCapability: (capability: string, companyId: number) => mocks.granted && capability === 'manage_client_configuration' && companyId === 2,
}));
vi.mock('@/services/staff-employee-lifecycle', () => ({
  staffEmployeeLifecycleApi: { list: mocks.list, get: mocks.get, verify: mocks.verify, sendBack: mocks.sendBack },
}));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title }: { title: string }) => <h1>{title}</h1> }));

const item: VerificationDetails = {
  id: 11, company_id: 2, employee_id: 31, employee_name: 'Synthetic Worker', status: 'pending_verification',
  event_kind: 'termination', affects_pay: true, source_actor_name: 'Synthetic Manager',
  effective_on: '2026-11-17', created_at: '2026-11-28T11:00:00Z', updated_at: '2026-11-28T12:00:00.012345Z',
  changed_fields: ['ssn'], before_values: { ssn: '900-00-0199' }, after_values: { ssn: '900-00-0234' },
  return_note: 'Confirm the final date.', client_response_note: 'Confirmed.', verification_note: null, resubmitted_at: null,
  can_review: true, audit_references: [{ id: 3, return_note: 'Review the original date.', staff_edit_audit_id: null }],
  warnings: {
    committed_pay_period_ids: [20], possible_self_created_hire: true, review_final_pay: true,
    post_termination_committed_pay_period_ids: [21], direct_deposit_missing_bank_details: true,
    tax_filing_impact: { committed_tax_years: [2026], filed_quarters: ['2026-Q3'] }, approved_pay_period_ids: [24],
  },
  readiness_checklist: {
    status: 'incomplete', rates_on: '2026-11-22', w4_on: '2026-11-24', missing_keys: ['tax_form'],
    items: [{ key: 'tax_form', label: 'W-4', complete: false, applicable: true, missing_label: 'W-4 missing' }],
  },
};

function CurrentSearch() {
  return <output aria-label="Current URL query">{useLocation().search}</output>;
}

function open({ selected = true, fix = false, query = '' }: { selected?: boolean; fix?: boolean; query?: string } = {}) {
  const search = [selected ? 'item_id=11' : '', query].filter(Boolean).join('&');
  render(<MemoryRouter initialEntries={[{
    pathname: '/companies/2/verifications',
    search: search ? `?${search}` : '',
    state: fix ? { lifecycleFix: { id: 11, companyId: 2, employeeId: 31, revision: item.updated_at } } : null,
  }]}><CurrentSearch /><Routes>
    <Route path="/companies/:companyId/verifications" element={<EmployeeVerificationQueue />} />
    <Route path="/companies/:companyId/employees/:id/edit" element={<p>Edit destination</p>} />
  </Routes></MemoryRouter>);
}
beforeEach(() => {
  vi.resetAllMocks();
  mocks.granted = true;
  mocks.audit = true;
  mocks.managed = true;
  mocks.companyReadOnly = false;
  mocks.list.mockResolvedValue({ data: [item], meta: { current_page: 1, total_pages: 1, total_count: 1 } });
  mocks.get.mockResolvedValue({ data: item });
  mocks.verify.mockResolvedValue({ data: { ...item, status: 'verified', can_review: false } });
  mocks.sendBack.mockResolvedValue({ data: { ...item, status: 'returned_to_client' } });
});
afterEach(cleanup);

describe('To verify', () => {
  it('lists changes, supports selecting a card and renders context and masked tax IDs', async () => {
    open({ selected: false });
    fireEvent.click(await screen.findByRole('button', { name: /Synthetic Worker/ }));
    expect(await screen.findByRole('heading', { name: 'Synthetic Worker' })).toBeTruthy();
    for (const label of [/Paid in committed run #20/, /Possible self-created hire/, /Backdated termination/, /accrued PTO payout/, /Bank details are missing/, /Review W-2c/, /W-4 missing/, /Review the original date/]) {
      expect(screen.getByText(label)).toBeTruthy();
    }
    expect(screen.getByText('Ending in 0234')).toBeTruthy();
    expect(screen.queryByText('900-00-0234')).toBeNull();
    expect(screen.getByRole('link', { name: 'Create a final pay run' }).getAttribute('href')).toBe('/companies/2/pay-runs?new_final=1');
    const fix = screen.getByRole('link', { name: 'Fix & verify' });
    expect(fix.getAttribute('href')).toContain('verify_item_id=11');
  });

  it('loads the next and previous pages and preserves the chosen page in the URL', async () => {
    mocks.list.mockImplementation((_company, filters) => Promise.resolve({
      data: [{ ...item, employee_name: `Sample Worker on page ${filters.page}` }],
      meta: { current_page: filters.page, total_pages: 2, total_count: 26 },
    }));
    open({ selected: false });
    await screen.findByRole('button', { name: /page 1/ });
    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    await screen.findByRole('button', { name: /page 2/ });
    expect(screen.getByLabelText('Current URL query').textContent).toBe('?page=2');
    fireEvent.click(screen.getByRole('button', { name: 'Previous' }));
    await screen.findByRole('button', { name: /page 1/ });
    expect(screen.getByLabelText('Current URL query').textContent).toBe('');
    expect(mocks.list.mock.calls.map(([, filters]) => filters.page)).toEqual([1, 2, 1]);
  });

  it('debounces searches, keeps prior results visible, and drops search text from navigation', async () => {
    mocks.get.mockResolvedValue({ data: { ...item, audit_references: [{ id: 1, return_note: null, staff_edit_audit_id: 72 }] } });
    open({ selected: false, query: 'q=legacy-private-search&page=2' });
    await screen.findByRole('button', { name: /Synthetic Worker/ });
    expect(screen.getByLabelText('Current URL query').textContent).toBe('?page=2');
    expect(mocks.list).toHaveBeenLastCalledWith(2, expect.objectContaining({ search: undefined, page: 2 }), expect.any(AbortSignal));
    const input = screen.getByLabelText('Search by employee');
    fireEvent.change(input, { target: { value: 'Synth' } });
    fireEvent.change(input, { target: { value: 'Synthetic Worker' } });
    expect(mocks.list).toHaveBeenCalledTimes(1);
    expect(screen.getByText('Updating employee changes…')).toBeTruthy();
    expect(screen.getByRole('button', { name: /Synthetic Worker/ })).toBeTruthy();
    expect(screen.getByLabelText('Current URL query').textContent).toBe('');
    await waitFor(() => expect(mocks.list).toHaveBeenLastCalledWith(2, expect.objectContaining({ search: 'Synthetic Worker', page: 1 }), expect.any(AbortSignal)));
    expect(mocks.list).toHaveBeenCalledTimes(2);
    fireEvent.click(screen.getByRole('button', { name: /Synthetic Worker/ }));
    await screen.findByRole('heading', { name: 'Synthetic Worker' });
    for (const name of ['Open employee record', 'Fix & verify', 'View employee edit history']) {
      const href = screen.getByRole('link', { name }).getAttribute('href')!;
      expect(new URL(href, 'https://example.test').searchParams.get('return_to')).toBe('/companies/2/verifications?item_id=11');
    }
  });

  it('shows managers which verified items were fixed by staff without exposing edit history', async () => {
    mocks.audit = false;
    mocks.get.mockResolvedValue({ data: { ...item, status: 'verified', can_review: false, fixed_by_staff: true,
      audit_references: [{ id: 1, return_note: null, staff_edit_audit_id: 72 }] } });
    open();
    expect(await screen.findByText('Fixed by staff')).toBeTruthy();
    expect(screen.queryByRole('link', { name: 'View employee edit history' })).toBeNull();
  });

  it.each(['permission', 'workspace', 'item'])('requires the action permission from the %s', async (source) => {
    if (source === 'permission') mocks.granted = false;
    if (source === 'workspace') mocks.companyReadOnly = true;
    if (source === 'item') mocks.get.mockResolvedValue({ data: { ...item, can_review: false } });
    open();
    await screen.findByRole('heading', { name: item.employee_name });
    expect(screen.queryByRole('button', { name: 'Mark verified' })).toBeNull();
    expect(screen.queryByRole('link', { name: 'Fix & verify' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Send back to client' })).toBeNull();
  });

  it('sends back with a note and the displayed revision', async () => {
    open();
    fireEvent.click(await screen.findByRole('button', { name: 'Send back to client' }));
    const dialog = screen.getByRole('dialog');
    const send = within(dialog).getByRole('button', { name: 'Send back' }) as HTMLButtonElement;
    expect(send.disabled).toBe(true);
    fireEvent.change(within(dialog).getByRole('textbox'), { target: { value: '  Please check the final date.  ' } });
    fireEvent.click(send);
    await waitFor(() => expect(mocks.sendBack).toHaveBeenCalledWith(2, 11, { updated_at: item.updated_at, return_note: 'Please check the final date.' }));
  });

  it('can verify residual changes but cannot send them back after rollback', async () => {
    mocks.managed = false;
    open();
    expect(await screen.findByRole('button', { name: 'Mark verified' })).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Fix & verify' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Send back to client' })).toBeNull();
  });

  it.each([false, true])('supports marking verified after explicit confirmation (saved fix=%s)', async (fix) => {
    open({ fix });
    await screen.findByRole('heading', { name: item.employee_name });
    if (!fix) fireEvent.click(screen.getByRole('button', { name: 'Mark verified' }));
    const dialog = screen.getByRole('dialog', { name: fix ? 'Mark the saved fix verified?' : 'Mark verified' });
    expect(mocks.verify).not.toHaveBeenCalled();
    fireEvent.change(within(dialog).getByRole('textbox'), { target: { value: 'Reviewed source.' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Mark verified' }));
    await waitFor(() => expect(mocks.verify).toHaveBeenCalledWith(2, 11, {
      updated_at: item.updated_at, verification_note: 'Reviewed source.', fixed_by_staff: fix,
    }));
  });
});
