// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { MemoryRouter, Route, Routes } from 'react-router';
import { PayrollPeriodPage } from './PayrollPeriodPage';
import type { PeriodDetail } from '@/services/payrollSubmissions';
import type { ClientDocument } from '@/services/api';

const mocks = vi.hoisted(() => ({
  get: vi.fn(), submit: vi.fn(), decide: vi.fn(), acknowledge: vi.fn(), createDraft: vi.fn(), seen: vi.fn(), employees: vi.fn(),
  threadGet: vi.fn(), message: vi.fn(),
}));
vi.mock('@/services/payrollSubmissions', async original => {
  const actual = await original<typeof import('@/services/payrollSubmissions')>();
  const threads = { get: mocks.threadGet, markRead: vi.fn() };
  const documents = { download: vi.fn(), preview: vi.fn() };
  return {
    ...actual,
    clientPayrollSubmissionsApi: { get: mocks.get, submit: mocks.submit, decide: mocks.decide, employees: mocks.employees, message: mocks.message, threads, documents },
    adminPayrollSubmissionsApi: { get: mocks.get, acknowledge: mocks.acknowledge, createDraft: mocks.createDraft, seen: mocks.seen, employees: mocks.employees, message: mocks.message, threads, documents },
  };
});
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 2 }) }));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title, description }: { title: string; description?: string }) => <header><h1>{title}</h1><p>{description}</p></header> }));

const doc = (id: number, name: string): ClientDocument => ({ id, title: name, file_name: name, content_type: 'application/pdf', file_size: 10, category: 'payroll_source', created_at: '2026-11-17T00:00:00Z', visible_to_client: true, shared_by_staff: false, uploaded_by_id: 1, preview_status: 'not_required', preview_available: true, scan_status: 'clean' } as ClientDocument);
const revision = (n: number, current: boolean) => ({
  id: n, revision: n, current, superseded: !current, submitted_at: '2026-11-17T02:00:00Z', submitted_by_name: 'Emma Client',
  acknowledged_at: null, acknowledged_by_name: null, no_changes: n === 1, notes: null, changes_link_url: null,
  changes: n === 2 ? [{ kind: 'paid_leave' as const, label: 'Paid leave', employee_id: 5, employee_name: 'Sam Worker', hours: '35' }] : [],
  documents: [{ role: 'revel_payroll' as const, file_name: `revel-${n}.pdf`, file_size: 10, document: doc(100 + n, `revel-${n}.pdf`) }],
});
const period = (overrides: Partial<PeriodDetail> = {}): PeriodDetail => ({
  ref: '9', id: 9, start_date: '2026-11-02', end_date: '2026-11-15', label: 'Nov 2–15, 2026', pay_date: '2026-11-20', status: 'submitted', status_label: 'Sent to Cornerstone',
  open_for_files: true, opens_on: '2026-11-15', current_revision: 2, last_submitted_at: '2026-11-17T02:00:00Z', status_changed_at: null,
  schedule_note: '', thread_id: null, allowed_actions: ['submit', 'message'], submissions: [revision(2, true), revision(1, false)], drafts: [], history: [], ...overrides,
});
const renderAt = (audience: 'client' | 'staff', path = audience === 'client' ? '/payroll-files/9' : '/companies/2/payroll-submissions/9') => render(
  <MemoryRouter initialEntries={[path]}><Routes>
    <Route path="/payroll-files/:ref" element={<PayrollPeriodPage audience="client" />} />
    <Route path="/companies/:companyId/payroll-submissions/:ref" element={<PayrollPeriodPage audience="staff" />} />
  </Routes></MemoryRouter>);

beforeEach(() => {
  vi.clearAllMocks();
  mocks.employees.mockResolvedValue([{ id: 5, name: 'Sam Worker' }]);
  mocks.seen.mockResolvedValue(undefined);
  mocks.get.mockResolvedValue({ data: period() });
});
afterEach(cleanup);

it('shows the current revision and keeps the superseded one visible', async () => {
  renderAt('client');
  expect(await screen.findByRole('heading', { name: 'Payroll Nov 2–15, 2026' })).toBeTruthy();
  expect(screen.getByText('Pay date Nov 20, 2026')).toBeTruthy();
  const current = screen.getByRole('region', { name: 'Revision 2' });
  expect(within(current).getByText('Current')).toBeTruthy();
  expect(within(current).getByText(/Sam Worker · 35 hours paid leave/)).toBeTruthy();
  expect(screen.getByText('Superseded')).toBeTruthy();
  expect(screen.getByText('Sent, waiting for Cornerstone to confirm')).toBeTruthy();
});

it('sends an update as a new revision carrying the Revel PDF forward with a stable retry key', async () => {
  mocks.submit.mockRejectedValueOnce(Object.assign(new Error('Network down'), { data: {} }))
    .mockResolvedValueOnce({ data: period({ current_revision: 3 }), outcome: 'created' });
  renderAt('client');
  fireEvent.click(await screen.findByRole('button', { name: 'Send an update or replace a file' }));
  expect(screen.getByText(/becomes revision 3/)).toBeTruthy();
  expect(screen.getByText(/Keeping revel-2.pdf from revision 2/)).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await screen.findByText('Network down');
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await screen.findByText('Sent. Revision 3 is with Cornerstone.');
  const [first, second] = mocks.submit.mock.calls.map(call => call[1] as FormData);
  expect(first.get('idempotency_key')).toBe(second.get('idempotency_key'));
  expect(second.getAll('keep_document_ids[]')).toEqual(['102']);
  expect(second.get('based_on_revision')).toBe('2');
  expect(JSON.parse(String(second.get('changes')))).toEqual([{ kind: 'paid_leave', employee_id: 5, hours: '35' }]);
  expect(second.get('revel_payroll')).toBeNull();
});

it('lets the client approve the posted draft or request a change with a note', async () => {
  const draft = { id: 4, revision: 1, current: true, superseded: false, posted: true, posted_at: '2026-11-18T00:00:00Z', posted_by_name: 'Dafne Staff', paycheck_document: doc(201, 'MHI paychecks.pdf'), direct_deposit_document: null };
  mocks.get.mockResolvedValue({ data: period({ status: 'draft_ready', status_label: 'Draft ready', drafts: [draft], allowed_actions: ['submit', 'approve', 'request_changes', 'message'] }) });
  mocks.decide.mockResolvedValue({ data: period({ status: 'changes_requested', status_label: 'Changes requested', drafts: [draft] }) });
  renderAt('client');
  fireEvent.click(await screen.findByRole('button', { name: 'Request a change' }));
  fireEvent.click(screen.getByRole('button', { name: 'Send change request' }));
  expect(await screen.findByText('Describe the change you need.')).toBeTruthy();
  expect(mocks.decide).not.toHaveBeenCalled();
  fireEvent.change(screen.getByLabelText('What should change?'), { target: { value: 'Add 2 hours for Sam' } });
  fireEvent.click(screen.getByRole('button', { name: 'Send change request' }));
  await waitFor(() => expect(mocks.decide).toHaveBeenCalledWith('9', { decision: 'request_changes', draft_id: 4, note: 'Add 2 hours for Sam' }));
  expect(await screen.findByText('Change request sent to Cornerstone.')).toBeTruthy();
});

it('lets staff confirm the exact current revision and records the page as seen', async () => {
  mocks.get.mockResolvedValue({ data: period({ allowed_actions: ['acknowledge', 'save_draft', 'message'] }) });
  mocks.acknowledge.mockResolvedValue({ data: period({ status: 'received', status_label: 'Received', allowed_actions: ['start_review', 'post_draft', 'save_draft', 'message'] }) });
  renderAt('staff');
  fireEvent.click(await screen.findByRole('button', { name: 'Confirm receipt of revision 2' }));
  await waitFor(() => expect(mocks.acknowledge).toHaveBeenCalledWith('9', 2));
  expect(mocks.seen).toHaveBeenCalledWith('9');
  expect(await screen.findByRole('button', { name: 'Post draft for review' })).toBeTruthy();
});
