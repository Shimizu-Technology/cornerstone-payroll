// @vitest-environment jsdom
import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import { EmployeeDocumentsPanel } from './EmployeeDocumentsPanel';

const mocks = vi.hoisted(() => ({
  documents: vi.fn(), requirements: vi.fn(), update: vi.fn(),
  upload: vi.fn(), delete: vi.fn(), preview: vi.fn(), download: vi.fn(),
  auth: { user: { id: 1, role: 'admin' } },
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => mocks.auth }));
vi.mock('@/services/api', () => ({
  adminClientDocumentsApi: { list: mocks.documents, upload: mocks.upload, delete: mocks.delete, preview: mocks.preview, download: mocks.download },
  clientDocumentsApi: { list: mocks.documents },
  adminEmployeeDocumentRequirementsApi: { list: mocks.requirements, update: mocks.update },
  clientEmployeeDocumentRequirementsApi: { list: mocks.requirements },
}));
vi.mock('@/components/documents/DocumentPreviewModal', () => ({ DocumentPreviewModal: () => null }));
vi.mock('@/lib/documentPreview', () => ({ prepareDocumentPreview: vi.fn() }));

const identity = 'Identity and work authorization';
const withholding = 'Signed withholding election';
const requirement = (id: number, label: string, status = 'missing', review_note = '', lock_version = 0) => ({
  id, employee_id: 27, label, status, review_note, lock_version,
  required_for_payroll: true, client_document_id: null, document_attached: false, history: [],
});
const missing = [requirement(1, identity), requirement(2, withholding)];
const response = (data = missing) => ({
  data,
  readiness: { ready_for_payroll: data.every(row => row.status === 'waived' || row.status === 'verified'), required: data.length },
});
const document = { id: 8, title: 'Synthetic identity', file_name: 'synthetic.pdf', content_type: 'application/pdf', file_size: 100, created_at: '2026-01-01T00:00:00Z' };
const row = (label: string) => within(screen.getByRole('button', { name: `Save ${label} status` }).parentElement!);
const card = (label: string) => within(screen.getByRole('button', { name: `Save ${label} status` }).parentElement!.parentElement!);
const select = (label: string) => row(label).getByLabelText('Readiness outcome') as HTMLSelectElement;
const note = (label: string) => row(label).getByLabelText('Review note') as HTMLInputElement;
const save = (label: string) => screen.getByRole('button', { name: `Save ${label} status` });
async function waive(user: ReturnType<typeof userEvent.setup>, label: string, text: string) {
  await user.selectOptions(select(label), 'waived');
  await user.clear(note(label));
  await user.type(note(label), text);
}
function mount(employeeId = 27, onReadinessChange = vi.fn()) {
  const content = (id: number) => <FeedbackProvider scopeKey="readiness-test"><EmployeeDocumentsPanel employeeId={id} employeeName="Synthetic employee" isClient={false} onReadinessChange={onReadinessChange} /></FeedbackProvider>;
  const view = render(content(employeeId));
  return { ...view, changeEmployee: (id: number) => view.rerender(content(id)), onReadinessChange };
}
beforeEach(() => {
  vi.resetAllMocks();
  mocks.auth = { user: { id: 1, role: 'admin' } };
  mocks.documents.mockResolvedValue({ data: [document] });
  mocks.requirements.mockResolvedValue(response());
});
afterEach(cleanup);

it('saves one real outcome while preserving the neighboring unsaved waiver and its next submitted note', async () => {
  const user = userEvent.setup();
  const firstSaved = [requirement(1, identity, 'waived', 'Identity fixture waiver', 1), missing[1]];
  const bothSaved = [firstSaved[0], requirement(2, withholding, 'waived', 'Withholding fixture waiver', 1)];
  mocks.update.mockResolvedValueOnce(response(firstSaved)).mockResolvedValueOnce(response(bothSaved));
  mocks.requirements.mockResolvedValueOnce(response()).mockResolvedValueOnce(response(firstSaved)).mockResolvedValue(response(bothSaved));
  const { onReadinessChange } = mount();
  await screen.findByRole('button', { name: `Save ${identity} status` });
  await waive(user, identity, 'Identity fixture waiver');
  await waive(user, withholding, 'Withholding fixture waiver');
  await user.click(save(identity));
  await waitFor(() => expect(card(identity).getByText('Waived with reason', { selector: 'span' })).toBeTruthy());
  expect(select(withholding).value).toBe('waived');
  expect(note(withholding).value).toBe('Withholding fixture waiver');
  expect(card(withholding).getByText('Missing', { selector: 'span' })).toBeTruthy();
  expect(mocks.update).toHaveBeenCalledTimes(1);
  await user.click(save(withholding));
  await waitFor(() => expect(screen.getByText('Ready for payroll', { exact: true })).toBeTruthy());
  expect(mocks.update).toHaveBeenNthCalledWith(2, 27, 2, {
    status: 'waived', client_document_id: undefined, review_note: 'Withholding fixture waiver', lock_version: 0,
  });
  expect(onReadinessChange).toHaveBeenLastCalledWith(response(bothSaved).readiness);
});

it('preserves edits made after submission, refreshes clean server rows and removes deleted checklist rows', async () => {
  const user = userEvent.setup();
  const third = requirement(3, 'Removed checklist item');
  mocks.requirements.mockResolvedValue(response([...missing, third]));
  let finish!: (value: ReturnType<typeof response>) => void;
  mocks.update.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  mount();
  await screen.findByRole('button', { name: `Save ${identity} status` });
  await waive(user, identity, 'Submitted reason');
  await waive(user, third.label, 'Unsubmitted third-row reason');
  await user.click(save(identity));
  await waitFor(() => expect(mocks.update).toHaveBeenCalledTimes(1));
  expect((save(withholding) as HTMLButtonElement).disabled).toBe(true);
  await user.type(note(identity), ' plus a later edit');
  const fresh = response([requirement(1, identity, 'waived', 'Submitted reason', 1), requirement(2, withholding, 'waived', 'Other reviewed outcome', 4)]);
  mocks.requirements.mockResolvedValue(fresh);
  await act(async () => { finish(fresh); });
  await waitFor(() => expect(note(identity).value).toBe('Submitted reason plus a later edit'));
  expect(note(withholding).value).toBe('Other reviewed outcome');
  expect(select(withholding).value).toBe('waived');
  expect(screen.queryByText(third.label, { exact: true })).toBeNull();
  const savedLaterEdit = response([requirement(1, identity, 'waived', 'Submitted reason plus a later edit', 2), fresh.data[1]]);
  mocks.update.mockResolvedValue(savedLaterEdit);
  mocks.requirements.mockResolvedValue(savedLaterEdit);
  await user.click(save(identity));
  await waitFor(() => expect(mocks.update).toHaveBeenCalledTimes(2));
  expect(mocks.update.mock.calls[1][2]).toMatchObject({ review_note: 'Submitted reason plus a later edit', lock_version: 1 });
});

it('retains both drafts after a genuine failed mutation and retries the selected draft only', async () => {
  const user = userEvent.setup();
  mocks.update.mockRejectedValueOnce(new Error('Review changed; try again.'));
  mount();
  await screen.findByRole('button', { name: `Save ${identity} status` });
  await waive(user, identity, 'First draft');
  await waive(user, withholding, 'Second draft');
  await user.click(save(identity));
  expect(within(await screen.findByRole('alert')).getByText('Review changed; try again.', { exact: true })).toBeTruthy();
  expect(note(identity).value).toBe('First draft');
  expect(note(withholding).value).toBe('Second draft');
  expect(screen.queryByText(`${identity} readiness updated`)).toBeNull();
  const fresh = response([requirement(1, identity, 'waived', 'First draft', 1), missing[1]]);
  mocks.update.mockResolvedValue(fresh);
  mocks.requirements.mockResolvedValue(fresh);
  await user.click(save(identity));
  await waitFor(() => expect(card(identity).getByText('Waived with reason', { selector: 'span' })).toBeTruthy());
  expect(mocks.update.mock.calls[1]).toEqual(mocks.update.mock.calls[0]);
  expect(note(withholding).value).toBe('Second draft');
});

it('keeps unsaved drafts through a failed refresh after a successful save and an explicit readiness retry', async () => {
  const user = userEvent.setup();
  const fresh = response([requirement(1, identity, 'waived', 'Saved reason', 1), missing[1]]);
  mocks.update.mockResolvedValue(fresh);
  mocks.requirements.mockResolvedValueOnce(response()).mockRejectedValueOnce(new Error('Readiness GET unavailable')).mockResolvedValue(fresh);
  mount();
  await screen.findByRole('button', { name: `Save ${identity} status` });
  await waive(user, identity, 'Saved reason');
  await waive(user, withholding, 'Preserved pending reason');
  await user.click(save(identity));
  const retry = await screen.findByRole('button', { name: 'Retry payroll readiness' });
  expect(screen.getByRole('alert').textContent).toContain('Readiness GET unavailable');
  expect(screen.getByText(`${identity} readiness updated`, { exact: true })).toBeTruthy();
  expect(screen.queryByText('Ready for payroll', { exact: true })).toBeNull();
  await user.click(retry);
  await waitFor(() => expect(note(withholding).value).toBe('Preserved pending reason'));
  expect(card(identity).getByText('Waived with reason', { selector: 'span' })).toBeTruthy();
  expect(select(withholding).value).toBe('waived');
  expect(mocks.update).toHaveBeenCalledTimes(1);
});

it.each(['employee', 'access'])('resets drafts on an actual %s scope change and ignores an old save response', async (kind) => {
  const user = userEvent.setup();
  let finish!: (value: ReturnType<typeof response>) => void;
  mocks.update.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  const view = mount();
  await screen.findByRole('button', { name: `Save ${identity} status` });
  await waive(user, identity, 'Old scope reason');
  await user.click(save(identity));
  await waitFor(() => expect(mocks.update).toHaveBeenCalledTimes(1));
  if (kind === 'access') mocks.auth = { user: { id: 2, role: 'accountant' } };
  view.changeEmployee(kind === 'employee' ? 28 : 27);
  await waitFor(() => expect(note(identity).value).toBe(''));
  expect(select(identity).value).toBe('received');
  if (kind === 'access') expect(row(identity).queryByRole('option', { name: 'Waived with reason' })).toBeNull();
  // Returning to the original employee/actor must not adopt its older in-flight save.
  mocks.auth = { user: { id: 1, role: 'admin' } };
  view.changeEmployee(27);
  await waitFor(() => expect(select(identity).value).toBe('received'));
  await act(async () => { finish(response([requirement(1, identity, 'waived', 'Old scope reason', 1), missing[1]])); });
  expect(note(identity).value).toBe('');
  expect(screen.queryByText(`${identity} readiness updated`)).toBeNull();
});

it('retains a dirty review note but exposes a selected document removed by the refreshed document list', async () => {
  const user = userEvent.setup();
  const fresh = response([requirement(1, identity, 'waived', 'Identity waiver', 1), missing[1]]);
  mocks.update.mockResolvedValue(fresh);
  mocks.requirements.mockResolvedValueOnce(response()).mockResolvedValue(fresh);
  mocks.documents.mockResolvedValueOnce({ data: [document] }).mockResolvedValue({ data: [] });
  mount();
  await screen.findByRole('button', { name: `Save ${identity} status` });
  await user.selectOptions(row(withholding).getByLabelText('Attached document'), '8');
  await user.type(note(withholding), 'Pending document review');
  await waive(user, identity, 'Identity waiver');
  await user.click(save(identity));
  await waitFor(() => expect(row(withholding).getByRole('option', { name: 'Selected document is no longer available — choose another' })).toBeTruthy());
  expect(note(withholding).value).toBe('Pending document review');
  expect((save(withholding) as HTMLButtonElement).disabled).toBe(true);
  expect(mocks.update).toHaveBeenCalledTimes(1);
});
