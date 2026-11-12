// @vitest-environment jsdom
import { MemoryRouter, useNavigate } from 'react-router';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { AdminClientDocumentsPage } from './AdminClientDocumentsPage';
import type { ClientDocument } from '@/services/api';

const mocks = vi.hoisted(() => ({ prepare: vi.fn(), get: vi.fn(), preview: vi.fn(), review: vi.fn(), list: vi.fn(), employees: vi.fn(), upload: vi.fn(), delete: vi.fn(), unarchive: vi.fn(), capabilities: [] as string[], recipientCount: 0 }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { role: 'admin' }, isLoading: false }) }));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompany: { id: 1, client_capabilities: mocks.capabilities }, activeCompanyId: 1, loading: false }),
}));
vi.mock('@/components/client-portal/PortalAlertRecipientsPanel', async () => {
  const { useEffect } = await import('react');
  return {
    PortalAlertRecipientsPanel: ({ onRecipientCountChange }: { onRecipientCountChange?: (count: number) => void }) => {
      useEffect(() => { onRecipientCountChange?.(mocks.recipientCount); }, [onRecipientCountChange]);
      return <section aria-label="Portal alert recipients" />;
    },
  };
});
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/client-portal/PortalMessagesPanel', () => ({ PortalMessagesPanel: () => null }));
vi.mock('@/components/documents/DocumentPreviewModal', () => ({ DocumentPreviewModal: ({ open, onOpenChange, document, payload }: { open: boolean; onOpenChange: (open: boolean) => void; document: ClientDocument | null; payload: { message?: string } | null }) => open ? <section aria-label="Preview"><output>{document?.title}: {payload?.message}</output><button onClick={() => onOpenChange(false)}>Close preview</button></section> : null }));
vi.mock('@/lib/documentPreview', () => ({ prepareDocumentPreview: mocks.prepare }));
vi.mock('@/services/api', () => ({
  getActiveCompanyId: () => 1,
  adminClientDocumentsApi: { get: mocks.get, preview: mocks.preview, review: mocks.review, list: mocks.list, upload: mocks.upload, delete: mocks.delete, unarchive: mocks.unarchive },
  employeesApi: { list: mocks.employees }, adminPortalThreadsApi: {},
}));
const document = { id: 1, title: 'Payroll hours', file_name: 'hours.csv', category: 'payroll_source', created_at: '2026-11-11T00:00:00Z', file_size: 100, uploaded_by_id: 1, visible_to_client: true } as ClientDocument;
beforeEach(() => {
  vi.clearAllMocks();
  mocks.prepare.mockResolvedValue({ kind: 'unsupported' });
  mocks.preview.mockResolvedValue({ blob: new Blob(['synthetic']) });
  mocks.capabilities = [];
  mocks.recipientCount = 0;
  mocks.list.mockResolvedValue({ data: [document] });
  mocks.employees.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

it('keeps the chosen upload and shows its plain server error', async () => {
  const user = userEvent.setup();
  mocks.upload.mockRejectedValue(new Error('File notice.pdf does not match its file extension. Please export it again.'));
  const { container } = render(<MemoryRouter><AdminClientDocumentsPage /></MemoryRouter>);
  await screen.findAllByText('Payroll hours');
  await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, new File(['synthetic'], 'notice.pdf', { type: 'application/pdf' }));
  await user.click(screen.getByRole('button', { name: 'Share Document' }));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('does not match'));
  expect(screen.getByText('notice.pdf')).toBeTruthy();
});

it('keeps archived evidence readable and offers staff unarchive', async () => {
  const user = userEvent.setup();
  vi.spyOn(window, 'confirm').mockReturnValue(true);
  mocks.delete.mockResolvedValue({ message: 'File archived. It is kept with its messages.' });
  render(<MemoryRouter><AdminClientDocumentsPage /></MemoryRouter>);
  await screen.findAllByText('Payroll hours');
  mocks.list.mockResolvedValue({ data: [{ ...document, archived_at: '2026-11-11T00:00:00Z' }] });
  await user.click(screen.getAllByRole('button', { name: 'Delete' })[0]);
  expect(await screen.findByText('File archived. It is kept with its messages.')).toBeTruthy();
  expect(screen.getAllByText('File archived · kept as evidence')).toHaveLength(2);
  for (const button of screen.getAllByRole('button', { name: /^(Preview|Download)$/ })) expect((button as HTMLButtonElement).disabled).toBe(false);
  expect(screen.getAllByRole('button', { name: 'Unarchive' })).toHaveLength(2);
  mocks.unarchive.mockResolvedValue({ message: 'File unarchived.' });
  mocks.list.mockResolvedValue({ data: [document] });
  await user.click(screen.getAllByRole('button', { name: 'Unarchive' })[0]);
  expect(await screen.findByText('File unarchived.')).toBeTruthy();
  expect(mocks.unarchive).toHaveBeenCalledWith(1);
  expect(screen.queryByText('File archived · kept as evidence')).toBeNull();
});

it('uploads 30 images in three sequential requests and shows progress', async () => {
  const user = userEvent.setup();
  let finishFirst!: (value: unknown) => void;
  mocks.upload.mockImplementationOnce(() => new Promise((resolve) => { finishFirst = resolve; }))
    .mockResolvedValue({ data: [], message: 'Shared' });
  const { container } = render(<MemoryRouter><AdminClientDocumentsPage /></MemoryRouter>);
  await screen.findAllByText('Payroll hours');
  const files = Array.from({ length: 30 }, (_, i) => new File(['image'], `timesheet-${i}.jpg`, { type: 'image/jpeg' }));
  await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, files);
  await user.click(screen.getByRole('button', { name: 'Share Document' }));
  expect(mocks.upload).toHaveBeenCalledTimes(1);
  expect((mocks.upload.mock.calls[0][0] as FormData).getAll('files[]')).toHaveLength(10);
  expect(screen.getByRole('status').textContent).toContain('0 of 30');
  finishFirst({ data: [] });
  expect(await screen.findByText('30 documents shared successfully')).toBeTruthy();
  expect(mocks.upload).toHaveBeenCalledTimes(3);
  for (const [payload] of mocks.upload.mock.calls) expect(payload.getAll('files[]')).toHaveLength(10);
});


it('reports the failed filename and retains only that file after a mixed batch', async () => {
  const user = userEvent.setup();
  mocks.upload.mockImplementation(async (payload: FormData) => {
    const files = payload.getAll('files[]') as File[];
    if (files.some((file) => file.name === 'bad.jpg')) throw Object.assign(new Error('File does not match its extension.'), { status: 422 });
    return { data: [] };
  });
  const { container } = render(<MemoryRouter><AdminClientDocumentsPage /></MemoryRouter>);
  await screen.findAllByText('Payroll hours');
  await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement,
    [new File(['good'], 'good.jpg', { type: 'image/jpeg' }), new File(['bad'], 'bad.jpg', { type: 'image/jpeg' })]);
  await user.click(screen.getByRole('button', { name: 'Share Document' }));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('bad.jpg: File does not match'));
  expect(screen.getByText('Document shared successfully')).toBeTruthy();
  expect(screen.getByText('bad.jpg')).toBeTruthy();
  expect(screen.queryByText('good.jpg')).toBeNull();
});

it.each([false, true])('resets metadata only after complete success (failure: %s)', async (fails) => {
  const user = userEvent.setup();
  mocks.employees.mockResolvedValue({ data: [{ id: 7, first_name: 'Synthetic', last_name: 'Worker' }], meta: { total_pages: 1 } });
  mocks.upload.mockImplementation(async () => {
    if (fails) throw new Error('Please retry');
    return { data: [] };
  });
  const { container } = render(<MemoryRouter><AdminClientDocumentsPage /></MemoryRouter>);
  await screen.findAllByText('Payroll hours');
  const title = screen.getByPlaceholderText('Optional document title') as HTMLInputElement;
  const notes = screen.getByPlaceholderText('Optional note shown with the document') as HTMLTextAreaElement;
  const form = title.closest('form')!;
  const selects = form.querySelectorAll('select');
  fireEvent.change(title, { target: { value: 'Previous title' } });
  fireEvent.change(notes, { target: { value: 'Previous notes' } });
  fireEvent.change(selects[0], { target: { value: 'payroll_source' } });
  fireEvent.change(selects[1], { target: { value: '7' } });
  const visibility = form.querySelector('input[type="checkbox"]') as HTMLInputElement | null;
  if (visibility) fireEvent.click(visibility);
  await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, new File(['synthetic'], 'test.pdf', { type: 'application/pdf' }));
  await user.click(screen.getByRole('button', { name: 'Share Document' }));
  if (fails) await screen.findByRole('alert');
  else await screen.findByText('Document shared successfully');
  expect(title.value).toBe(fails ? 'Previous title' : '');
  expect(notes.value).toBe(fails ? 'Previous notes' : '');
  expect(selects[0].value).toBe(fails ? 'payroll_source' : 'misc');
  expect(selects[1].value).toBe(fails ? '7' : '');
  if (visibility) expect(visibility.checked).toBe(!fails);
  expect(screen.queryByText('test.pdf') !== null).toBe(fails);
});

it('shows alert recipients and the no-recipient warning only to client administrators', async () => {
  const { unmount } = render(<MemoryRouter><AdminClientDocumentsPage /></MemoryRouter>);
  await screen.findAllByText('Payroll hours');
  expect(screen.queryByLabelText('Portal alert recipients')).toBeNull();
  expect(screen.queryByText('No one receives portal alerts for this client.')).toBeNull();
  unmount();

  mocks.capabilities = ['manage_client_administration'];
  render(<MemoryRouter><AdminClientDocumentsPage /></MemoryRouter>);
  expect(await screen.findByLabelText('Portal alert recipients')).toBeTruthy();
  expect(await screen.findByText('No one receives portal alerts for this client.')).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Choose alert recipients' }).getAttribute('href')).toBe('#portal-alert-recipients');
});

it('hides the warning once the client has recipients', async () => {
  mocks.capabilities = ['manage_client_administration'];
  mocks.recipientCount = 2;
  render(<MemoryRouter><AdminClientDocumentsPage /></MemoryRouter>);
  expect(await screen.findByLabelText('Portal alert recipients')).toBeTruthy();
  expect(screen.queryByText('No one receives portal alerts for this client.')).toBeNull();
});


it('keeps the exact inbox document review action available after closing its preview', async () => {
  const user = userEvent.setup();
  mocks.get.mockResolvedValue({ data: document });
  mocks.preview.mockResolvedValue({ blob: new Blob(['synthetic']) });
  mocks.review.mockResolvedValue({ data: { ...document, reviewed_at: '2026-11-12T00:00:00Z' } });
  render(<MemoryRouter initialEntries={['/companies/1/client-documents?document_id=1&inbox=%2Fapp%2Fclient-inbox']}><AdminClientDocumentsPage /></MemoryRouter>);
  await user.click(await screen.findByRole('button', { name: 'Close preview' }));
  await user.click(screen.getByRole('button', { name: 'Mark reviewed' }));
  expect(await screen.findByText('Reviewed by staff')).toBeTruthy();
  expect(mocks.review).toHaveBeenCalledWith(1);
  expect((screen.getByRole('button', { name: 'Mark reviewed' }) as HTMLButtonElement).disabled).toBe(true);
});

it('keeps the newest manual preview when an inbox preview finishes later', async () => {
  let finishOld!: (value: { kind: string; message: string; objectUrl: string }) => void;
  const second = { ...document, id: 2, title: 'Second file' };
  mocks.get.mockResolvedValue({ data: document });
  mocks.list.mockResolvedValue({ data: [document, second] });
  mocks.prepare.mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve; }))
    .mockResolvedValue({ kind: 'unsupported', message: 'Second payload' });
  render(<MemoryRouter initialEntries={['/companies/1/client-documents?document_id=1']}><AdminClientDocumentsPage /></MemoryRouter>);
  await waitFor(() => expect(mocks.prepare).toHaveBeenCalledOnce());
  await screen.findAllByText('Second file');
  const row = screen.getAllByText('Second file').find(node => node.closest('tr'))!.closest('tr')!;
  fireEvent.click(row.querySelector('button')!);
  await screen.findByText('Second file: Second payload');
  const revoke = vi.spyOn(URL, 'revokeObjectURL');
  await act(async () => finishOld({ kind: 'image', message: 'Old payload', objectUrl: 'blob:old-preview' }));
  expect(screen.getByText('Second file: Second payload')).toBeTruthy();
  expect(screen.queryByText(/Old payload/)).toBeNull();
  expect(revoke).toHaveBeenCalledWith('blob:old-preview');
});

function NextDocument(): React.ReactElement {
  const navigate = useNavigate();
  return <button onClick={() => navigate('/companies/1/client-documents?document_id=2')}>Open second inbox file</button>;
}

it('does not let a late review of the previous inbox file replace the new one', async () => {
  const second = { ...document, id: 2, title: 'Second inbox file' };
  let finish!: (value: { data: ClientDocument }) => void;
  mocks.get.mockImplementation((id: number) => Promise.resolve({ data: id === 1 ? document : second }));
  mocks.review.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  render(<MemoryRouter initialEntries={['/companies/1/client-documents?document_id=1']}><NextDocument /><AdminClientDocumentsPage /></MemoryRouter>);
  fireEvent.click(await screen.findByRole('button', { name: 'Mark reviewed' }));
  await waitFor(() => expect(mocks.review).toHaveBeenCalledWith(1));
  fireEvent.click(screen.getByRole('button', { name: 'Open second inbox file' }));
  await screen.findByRole('heading', { name: 'Second inbox file' });
  await act(async () => finish({ data: { ...document, reviewed_at: '2026-11-12T00:00:00Z' } }));
  expect(screen.getByRole('heading', { name: 'Second inbox file' })).toBeTruthy();
  expect(screen.getByText('Waiting on staff review')).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Mark reviewed' }) as HTMLButtonElement).disabled).toBe(false);
});

it('blocks stale pagination while a new first-page document search is pending', async () => {
  const meta = { current_page: 1, per_page: 50, total_pages: 2, total_count: 51 };
  mocks.list.mockResolvedValueOnce({ data: [document], meta });
  let finish!: (value: { data: ClientDocument[]; meta: typeof meta }) => void;
  mocks.list.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  render(<MemoryRouter><AdminClientDocumentsPage /></MemoryRouter>);
  await screen.findByRole('button', { name: 'Load more files' });
  fireEvent.change(screen.getByPlaceholderText('Find older files by title or filename'), { target: { value: 'Second' } });
  expect(screen.queryByRole('button', { name: 'Load more files' })).toBeNull();
  await waitFor(() => expect(mocks.list).toHaveBeenCalledTimes(2));
  expect(mocks.list.mock.calls.map(([params]) => params.page)).toEqual([1, 1]);
  await act(async () => finish({ data: [{ ...document, id: 2, title: 'Second file' }], meta: { ...meta, total_count: 1, total_pages: 1 } }));
  await screen.findAllByText('Second file');
  expect(screen.queryByText('Payroll hours')).toBeNull();
  expect(screen.queryByRole('button', { name: 'Load more files' })).toBeNull();
});

it('clears previous file results when the new search fails', async () => {
  mocks.list.mockResolvedValueOnce({ data: [document] }).mockRejectedValueOnce(new Error('Search unavailable'));
  render(<MemoryRouter><AdminClientDocumentsPage /></MemoryRouter>);
  await screen.findAllByText('Payroll hours');
  fireEvent.change(screen.getByPlaceholderText('Find older files by title or filename'), { target: { value: 'Different files' } });
  await screen.findByText('Search unavailable');
  expect(screen.queryByText('Payroll hours')).toBeNull();
  expect(screen.getByText('No client uploads found')).toBeTruthy();
});
