// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { MemoryRouter, Route, Routes } from 'react-router';
import { PayrollPeriodPage } from './PayrollPeriodPage';
import type { PeriodDetail, SubmissionRevision } from '@/services/payrollSubmissions';
import type { ClientDocument } from '@/services/api';

const mocks = vi.hoisted(() => ({
  get: vi.fn(), submit: vi.fn(), decide: vi.fn(), acknowledge: vi.fn(), createDraft: vi.fn(), seen: vi.fn(), employees: vi.fn(),
  threadGet: vi.fn(), message: vi.fn(), mosa: true,
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
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 2, activeCompany: { payroll_intake_source_types: mocks.mosa ? ['mosa_revel'] : [] } }) }));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title, description }: { title: string; description?: string }) => <header><h1>{title}</h1><p>{description}</p></header> }));

const doc = (id: number, name: string): ClientDocument => ({ id, title: name, file_name: name, content_type: 'application/pdf', file_size: 10, category: 'payroll_source', created_at: '2026-11-17T00:00:00Z', visible_to_client: true, shared_by_staff: false, uploaded_by_id: 1, preview_status: 'not_required', preview_available: true, scan_status: 'clean' } as ClientDocument);
const revision = (n: number, current: boolean): SubmissionRevision => ({
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
  mocks.mosa = true;
  mocks.employees.mockResolvedValue([{ id: 5, name: 'Sam Worker' }]);
  mocks.seen.mockResolvedValue(undefined);
  mocks.get.mockResolvedValue({ data: period() });
});
afterEach(cleanup);

it('shows the current revision and keeps the superseded one visible', async () => {
  renderAt('client');
  expect(await screen.findByRole('heading', { name: 'Payroll Nov 2 – 15, 2026' })).toBeTruthy();
  expect(screen.getByRole('heading', { name: 'What you sent' })).toBeTruthy();
  expect(screen.queryByRole('heading', { name: 'What the client sent' })).toBeNull();
  expect(screen.getByText(/Pay date Nov 20, 2026/)).toBeTruthy();
  const current = screen.getByRole('region', { name: 'Revision 2' });
  expect(within(current).getByText('Current')).toBeTruthy();
  expect(within(current).getByText(/Sam Worker · 35 hours paid leave/)).toBeTruthy();
  expect(screen.getByText('Superseded')).toBeTruthy();
  expect(screen.getByText('Sent to Cornerstone')).toBeTruthy();
});

it('links clients to Messages for the period conversation without rendering an inline composer', async () => {
  mocks.get.mockResolvedValue({ data: period({ thread_id: 55 }) });
  renderAt('client');
  const link = await screen.findByRole('link', { name: /Open this period’s conversation in Messages/ });
  expect(link.getAttribute('href')).toBe('/messages?thread_id=55');
  expect(screen.queryByRole('button', { name: 'Send message' })).toBeNull();
});

it('carries the period reference to Messages when no period conversation exists yet', async () => {
  mocks.get.mockResolvedValue({ data: period({ id: null, ref: '2026-11-02_2026-11-15', thread_id: null }) });
  renderAt('client', '/payroll-files/2026-11-02_2026-11-15');
  const link = await screen.findByRole('link', { name: /Start this period’s conversation in Messages/ });
  expect(link.getAttribute('href')).toBe('/messages?period_ref=2026-11-02_2026-11-15');
});

it('sends an update as a new revision carrying the Revel PDF forward with a stable retry key', async () => {
  mocks.submit.mockRejectedValueOnce(Object.assign(new Error('Network down'), { data: {} }))
    .mockResolvedValueOnce({ data: period({ current_revision: 3 }), outcome: 'created' });
  renderAt('client');
  fireEvent.click(await screen.findByRole('button', { name: 'Send an update or replace a file' }));
  expect(screen.getByText(/becomes revision 3/)).toBeTruthy();
  expect(screen.getByText(/Keeping revel-2.pdf from revision 2/)).toBeTruthy();
  fireEvent.click(screen.getByLabelText('No tips or loans this period'));
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await screen.findByText('Network down');
  fireEvent.click(screen.getByLabelText('No tips or loans this period'));
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await screen.findByText(/Sent. Revision 3 is with Cornerstone\./);
  const [first, second] = mocks.submit.mock.calls.map(call => call[1] as FormData);
  expect(first.get('idempotency_key')).toBe(second.get('idempotency_key'));
  expect(second.getAll('keep_document_ids[]')).toEqual(['102']);
  expect(second.get('based_on_revision')).toBe('2');
  expect(JSON.parse(String(second.get('changes')))).toEqual([{ kind: 'paid_leave', employee_id: 5, hours: '35' }]);
  expect(second.get('revel_payroll')).toBeNull();
});

it('keeps earlier drafts readable and directs decisions to the pay run preview', async () => {
  const draft = { id: 4, revision: 1, current: true, superseded: false, posted: true, paycheck_document: doc(201, 'MHI paychecks.pdf') };
  mocks.get.mockResolvedValue({ data: period({ review_pay_period_id: 12, drafts: [draft] }) });
  renderAt('client');
  expect(await screen.findByRole('link', { name: 'Open payroll preview' })).toHaveProperty('href', 'http://localhost:3000/companies/2/pay-runs/12/overview');
  expect(screen.getByText('MHI paychecks.pdf')).toBeTruthy();
  expect(screen.queryByRole('button', { name: /Approve draft/ })).toBeNull();
});

it('lets staff confirm the exact current revision and records the page as seen', async () => {
  vi.spyOn(document, 'hasFocus').mockReturnValue(true);
  mocks.get.mockResolvedValue({ data: period({ latest_client_event_id: 41, allowed_actions: ['acknowledge', 'save_draft', 'message'] }) });
  mocks.acknowledge.mockResolvedValue({ data: period({ status: 'received', status_label: 'Received', allowed_actions: ['start_review', 'post_draft', 'save_draft', 'message'] }) });
  renderAt('staff');
  fireEvent.click(await screen.findByRole('button', { name: 'Confirm receipt of revision 2' }));
  await waitFor(() => expect(mocks.acknowledge).toHaveBeenCalledWith('9', 2));
  expect(mocks.seen).toHaveBeenCalledWith('9', 41);
  expect(await screen.findByRole('button', { name: 'Start review' })).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Post draft for review' })).toBeNull();
});

it('holds the draft actions while a receipt confirmation is still saving', async () => {
  mocks.get.mockResolvedValue({ data: period({ allowed_actions: ['acknowledge', 'save_draft', 'message'] }) });
  let finish: (value: { data: ReturnType<typeof period> }) => void = () => {};
  mocks.acknowledge.mockReturnValue(new Promise(resolve => { finish = resolve; }));
  renderAt('staff');
  fireEvent.click(await screen.findByRole('button', { name: 'Confirm receipt of revision 2' }));
  expect((screen.getByRole('button', { name: 'Confirm receipt of revision 2' }) as HTMLButtonElement).disabled).toBe(true);
  finish({ data: period({ status: 'received', status_label: 'Received', allowed_actions: ['save_draft', 'message'] }) });
  await waitFor(() => expect(screen.queryByRole('button', { name: 'Confirm receipt of revision 2' })).toBeNull());
  expect(screen.queryByRole('button', { name: 'Save staff-only' })).toBeNull();
});

it('marks a period seen only once it is shown in the foreground, through the displayed update', async () => {
  const focus = vi.spyOn(document, 'hasFocus').mockReturnValue(false);
  mocks.get.mockResolvedValue({ data: period({ latest_client_event_id: 77 }) });
  renderAt('staff');
  await screen.findByRole('heading', { name: 'Payroll Nov 2 – 15, 2026' });
  expect(mocks.seen).not.toHaveBeenCalled();
  focus.mockReturnValue(true);
  window.dispatchEvent(new Event('focus'));
  await waitFor(() => expect(mocks.seen).toHaveBeenCalledWith('9', 77));
  window.dispatchEvent(new Event('focus'));
  expect(mocks.seen).toHaveBeenCalledTimes(1);
});

it('sends none independently of no structured changes and removes hidden workbook evidence', async () => {
  const withWorkbook = revision(2, true);
  withWorkbook.changes_link_url = 'https://example.test/sheet';
  withWorkbook.documents = [...withWorkbook.documents, { role: 'changes_workbook', file_name: 'changes.xlsx', file_size: 10, document: doc(150, 'changes.xlsx') }];
  mocks.get.mockResolvedValue({ data: period({ submissions: [withWorkbook] }) });
  mocks.submit.mockResolvedValue({ data: period({ current_revision: 3 }), outcome: 'created' });
  renderAt('client');
  fireEvent.click(await screen.findByRole('button', { name: 'Send an update or replace a file' }));
  fireEvent.click(screen.getByLabelText('No changes this period'));
  fireEvent.click(screen.getByLabelText('No tips or loans this period'));
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await waitFor(() => expect(mocks.submit).toHaveBeenCalled());
  const form = mocks.submit.mock.calls[0][1] as FormData;
  expect(form.get('no_changes')).toBe('true');
  expect(form.get('changes')).toBe('[]');
  expect(form.get('changes_link_url')).toBeNull();
  expect(form.getAll('keep_document_ids[]')).toEqual(['102']);
});

it('shows an employee-list failure with a retry instead of an empty picker', async () => {
  mocks.employees.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce([{ id: 5, name: 'Sam Worker' }]);
  mocks.get.mockResolvedValue({ data: period({ submissions: [], current_revision: null, status: 'waiting_for_files', status_label: 'Waiting for files' }) });
  renderAt('client');
  expect((await screen.findByRole('alert')).textContent).toContain('employee list did not load');
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  await waitFor(() => expect(screen.queryByText(/employee list did not load/)).toBeNull());
  expect(mocks.employees).toHaveBeenCalledTimes(2);
});

it('keeps a posted draft and approval available without a Send form for clients without intake', async () => {
  mocks.mosa = false;
  const draft = { id: 4, revision: 1, current: true, superseded: false, posted: true, paycheck_document: doc(201, 'Fixed pay draft.pdf') };
  mocks.get.mockResolvedValue({ data: period({ status: 'draft_ready', status_label: 'Draft ready', submissions: [], current_revision: null, drafts: [draft], allowed_actions: ['approve', 'request_changes', 'message'] }) });
  mocks.decide.mockResolvedValue({ data: period({ status: 'approved', status_label: 'Approved', submissions: [], drafts: [draft], allowed_actions: ['message'] }) });
  renderAt('client');
  expect(await screen.findByText('Fixed pay draft.pdf')).toBeTruthy();
  expect(screen.getByText('Fixed pay draft.pdf')).toBeTruthy();
  expect(screen.queryByRole('form', { name: /Send/ })).toBeNull();
  expect(screen.queryByText(/This period opens for files/)).toBeNull();
  expect(screen.queryByRole('button', { name: 'Send an update or replace a file' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Approve draft 1' })).toBeNull();
});
it('counts explicit skips separately from changes in the sent receipt', async () => {
  const standing = { kind: 'owner_pay' as const, standing_change_id: 1, employee_id: 5, employee_name: 'Sam Worker' };
  mocks.get.mockResolvedValue({ data: period({ standing_changes: [standing] }) });
  mocks.submit.mockResolvedValue({ data: period({ current_revision: 3, submissions: [{ ...revision(3, true), workbook_choice: 'none', no_changes: true, changes: [{ ...standing, skipped: true }] }] }), outcome: 'created' });
  renderAt('client');
  fireEvent.click(await screen.findByRole('button', { name: 'Send an update or replace a file' }));
  fireEvent.click(screen.getByLabelText('No changes this period'));
  fireEvent.click(screen.getByLabelText('No tips or loans this period'));
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await screen.findByText(/0 changes · 1 not this period/);
});

it('orders the six staff sections and hides the single-revision picker', async () => {
  mocks.get.mockResolvedValue({ data: period({ pay_period_id: 12, submissions: [revision(2, true)], history: [{ id: 1, event: 'submit', from_status: 'waiting_for_files', to_status: 'submitted', to_status_label: 'Sent to Cornerstone', actor_name: 'Emma', actor_audience: 'client', note: null, submission_id: 2, draft_id: null, created_at: '2026-11-15T00:00:00Z' }] }) });
  renderAt('staff');
  await screen.findByRole('heading', { name: 'Status' });
  expect(screen.getAllByRole('heading', { level: 2 }).map(node => node.textContent)).toEqual([
    'Status', 'What the client sent', 'Next step', 'Payroll preview review', 'Messages', 'History',
  ]);
  expect(screen.queryByLabelText('Client’s revision')).toBeNull();
});

it('warns staff, and only staff, when the linked pay run is voided or ambiguous', async () => {
  const warning = 'The linked pay run was voided. Link the replacement run before review.';
  mocks.get.mockResolvedValue({ data: period({ pay_period_link_error: warning }) });
  renderAt('staff');
  expect((await screen.findByRole('alert')).textContent).toBe(warning);
  cleanup();
  renderAt('client');
  await screen.findByRole('heading', { name: 'Payroll Nov 2 – 15, 2026' });
  expect(screen.queryByText(warning)).toBeNull();
});
