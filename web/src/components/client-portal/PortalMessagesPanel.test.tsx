// @vitest-environment jsdom

import { MemoryRouter, useLocation } from 'react-router';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi, type Mock } from 'vitest';
import type { ComponentProps, ReactElement } from 'react';
import type { ClientPortalThread } from '@/services/api';
import { PortalMessagesPanel } from './PortalMessagesPanel';
import { clearAllDrafts } from './messageDrafts';
import type { PortalDocumentsApi } from './portalFiles';

type Callbacks = { onConnected: () => void; onUnavailable: () => void; onError: () => void; onThread: (value: { thread: ClientPortalThread }) => void };
const mocks = vi.hoisted(() => ({ company: 2, refresh: vi.fn(), subscribe: vi.fn(), callbacks: [] as Callbacks[] }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 5 } }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: mocks.company, refreshCompanies: mocks.refresh }) }));
vi.mock('@/services/clientPortalCable', () => ({ subscribeToClientPortalThreads: mocks.subscribe }));
const thread = (companyId: number, subject: string) => ({ id: companyId, company_id: companyId, subject, status: 'open', created_at: '2026-10-12T00:00:00Z', updated_at: '2026-10-12T00:00:00Z', unread: false, messages: [] } as ClientPortalThread);
type ThreadsApi = ComponentProps<typeof PortalMessagesPanel>['api'];
let api: { [Key in keyof ThreadsApi]: Mock<ThreadsApi[Key]> };
const routed = (node: ReactElement): ReactElement => <MemoryRouter>{node}</MemoryRouter>;
const view = (): ReactElement => routed(<PortalMessagesPanel api={api} documents={[]} audienceLabel="client" description="Client messages" />);

beforeEach(() => {
  window.matchMedia = vi.fn().mockReturnValue({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() });
  vi.clearAllMocks(); clearAllDrafts(); mocks.company = 2; mocks.callbacks.length = 0; mocks.refresh.mockResolvedValue(undefined);
  mocks.subscribe.mockImplementation((_company: number, callbacks: Callbacks) => { mocks.callbacks.push(callbacks); return Promise.resolve(vi.fn()); });
  api = { unreadCount: vi.fn().mockResolvedValue({ data: { unread_count: 0 } }), activity: vi.fn().mockResolvedValue({ data: [], meta: {} }), markRead: vi.fn(), list: vi.fn<ThreadsApi['list']>().mockResolvedValue({ data: [] }), get: vi.fn<ThreadsApi['get']>(), create: vi.fn<ThreadsApi['create']>(), update: vi.fn<ThreadsApi['update']>(), createMessage: vi.fn<ThreadsApi['createMessage']>() };
});
afterEach(cleanup);

it('clears revoked conversations, blocks sending, and lets the operator refresh access', async () => {
  api.list.mockResolvedValue({ data: [thread(2, 'Former client conversation')] });
  api.get.mockResolvedValue({ data: thread(2, 'Former client conversation') });
  render(view()); await screen.findAllByText('Former client conversation');
  await waitFor(() => expect(mocks.callbacks).toHaveLength(1));
  await act(async () => mocks.callbacks[0].onUnavailable());
  expect(screen.queryByText('Former client conversation')).toBeNull();
  expect(screen.getByText('Live updates unavailable')).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Start Conversation' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: 'Start Conversation' })); expect(api.create).not.toHaveBeenCalled();
  api.list.mockResolvedValue({ data: [] });
  fireEvent.click(screen.getByRole('button', { name: 'Refresh access' }));
  await waitFor(() => expect(mocks.refresh).toHaveBeenCalledOnce());
  await waitFor(() => expect(mocks.subscribe).toHaveBeenCalledTimes(2));
  expect((screen.getByRole('button', { name: 'Start Conversation' }) as HTMLButtonElement).disabled).toBe(true);
  await act(async () => mocks.callbacks[1].onConnected());
  expect(screen.getByText('Live updates on')).toBeTruthy();
});

it('immediately cleans up a subscription whose setup finishes after unmount', async () => {
  let finish!: (cleanup: () => void) => void;
  mocks.subscribe.mockImplementation((_company: number, callbacks: Callbacks) => { mocks.callbacks.push(callbacks); return new Promise<() => void>(resolve => { finish = resolve; }); });
  const rendered = render(view()); await waitFor(() => expect(mocks.subscribe).toHaveBeenCalledOnce());
  rendered.unmount(); const stop = vi.fn(); await act(async () => finish(stop));
  expect(stop).toHaveBeenCalledOnce();
});

it('resets client conversations and pins a new subscription when the company changes', async () => {
  const stop = vi.fn(); mocks.subscribe.mockResolvedValue(stop);
  api.list.mockResolvedValue({ data: [thread(2, 'Client B conversation')] }); api.get.mockResolvedValue({ data: thread(2, 'Client B conversation') });
  const rendered = render(view()); await screen.findAllByText('Client B conversation');
  mocks.company = 3; api.list.mockResolvedValue({ data: [thread(3, 'Client A conversation')] }); api.get.mockResolvedValue({ data: thread(3, 'Client A conversation') });
  rendered.rerender(view()); await screen.findAllByText('Client A conversation');
  expect(screen.queryByText('Client B conversation')).toBeNull(); expect(stop).toHaveBeenCalledOnce();
  expect(mocks.subscribe.mock.calls.map(call => call[0])).toEqual([2, 3]);
});

it('keeps a late list response from restoring conversations after revocation', async () => {
  let finish!: (value: { data: ClientPortalThread[] }) => void;
  api.list.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  render(view()); await waitFor(() => expect(mocks.callbacks).toHaveLength(1));
  await act(async () => mocks.callbacks[0].onUnavailable());
  await act(async () => finish({ data: [thread(2, 'Late inaccessible conversation')] }));
  expect(screen.queryByText('Late inaccessible conversation')).toBeNull();
  expect(screen.getByText('Live updates unavailable')).toBeTruthy();
});

it('does not restore a newly created conversation when its response arrives after revocation', async () => {
  let finish!: (value: { data: ClientPortalThread }) => void;
  api.create.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  render(view()); await waitFor(() => expect(mocks.callbacks).toHaveLength(1));
  fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'Pending conversation' } });
  fireEvent.click(screen.getByRole('button', { name: 'Start Conversation' }));
  await waitFor(() => expect(api.create).toHaveBeenCalledOnce());
  await act(async () => mocks.callbacks[0].onUnavailable());
  await act(async () => finish({ data: thread(2, 'Late saved conversation') }));
  expect(screen.queryByText('Late saved conversation')).toBeNull();
  expect((screen.getByRole('button', { name: 'Start Conversation' }) as HTMLButtonElement).disabled).toBe(true);
});

it('keeps sending blocked when refreshed client access is still denied', async () => {
  render(view()); await waitFor(() => expect(mocks.callbacks).toHaveLength(1));
  await act(async () => mocks.callbacks[0].onUnavailable());
  fireEvent.click(screen.getByRole('button', { name: 'Refresh access' }));
  await waitFor(() => expect(mocks.callbacks).toHaveLength(2));
  await act(async () => mocks.callbacks[1].onUnavailable());
  expect((screen.getByRole('button', { name: 'Start Conversation' }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getByText('Live updates unavailable')).toBeTruthy();
});

it('keeps sending blocked when refreshing available clients fails', async () => {
  mocks.refresh.mockRejectedValue(new Error('Client access refresh unavailable'));
  render(view()); await waitFor(() => expect(mocks.callbacks).toHaveLength(1));
  await act(async () => mocks.callbacks[0].onUnavailable());
  fireEvent.click(screen.getByRole('button', { name: 'Refresh access' }));
  await screen.findByText('Client access refresh unavailable');
  expect((screen.getByRole('button', { name: 'Start Conversation' }) as HTMLButtonElement).disabled).toBe(true);
  expect(mocks.subscribe).toHaveBeenCalledOnce();
});

it('pages older conversations with a server total and Load more', async () => {
  const older = (id: number, subject: string) => ({ ...thread(2, subject), id });
  const meta = (page: number) => ({ current_page: page, total_pages: 2, total_count: 3, per_page: 2 });
  api.list.mockImplementation((params) => Promise.resolve(
    params?.page === 2 ? { data: [older(1, 'Oldest conversation')], meta: meta(2) } : { data: [older(3, 'Newest conversation'), older(2, 'Middle conversation')], meta: meta(1) },
  ));
  api.get.mockImplementation((id) => Promise.resolve({ data: older(id, 'Selected') }));
  render(view());

  expect((await screen.findByText(/Showing/)).textContent).toBe('Showing 2 of 3 conversations');
  expect(screen.queryByText('Oldest conversation')).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Load more conversations' }));

  expect(await screen.findByText('Oldest conversation')).toBeTruthy();
  expect(api.list).toHaveBeenLastCalledWith({ page: 2 });
  expect(screen.queryByRole('button', { name: 'Load more conversations' })).toBeNull();
});

const listed = (id: number, subject: string): ClientPortalThread => ({ ...thread(2, subject), id, last_message_at: `2026-10-${10 + id}T00:00:00Z` });

it('counts a live new conversation once, including after the next page already counts it', async () => {
  const meta = (page: number, total: number) => ({ current_page: page, total_pages: 3, total_count: total, per_page: 2 });
  api.list.mockImplementation((params) => Promise.resolve(
    params?.page === 2
      ? { data: [listed(4, 'Fourth'), listed(3, 'Third')], meta: meta(2, 6) }
      : { data: [listed(5, 'Fifth'), listed(4, 'Fourth')], meta: meta(1, 5) },
  ));
  api.get.mockImplementation((id) => Promise.resolve({ data: listed(id, 'Fifth') }));
  render(view());
  expect((await screen.findByText(/Showing/)).textContent).toBe('Showing 2 of 5 conversations');
  await waitFor(() => expect(mocks.callbacks).toHaveLength(1));

  await act(async () => mocks.callbacks[0].onThread({ thread: listed(6, 'Brand new') }));
  expect(screen.getByText(/Showing/).textContent).toBe('Showing 3 of 6 conversations');

  fireEvent.click(screen.getByRole('button', { name: 'Load more conversations' }));
  expect(await screen.findByText('Third')).toBeTruthy();
  expect(screen.getByText(/Showing/).textContent).toBe('Showing 4 of 6 conversations');

  await act(async () => mocks.callbacks[0].onThread({ thread: { ...listed(6, 'Brand new'), last_message_at: '2026-10-30T00:00:00Z' } }));
  expect(screen.getByText(/Showing/).textContent).toBe('Showing 4 of 6 conversations');
});

it('does not change the total when a live update arrives for a conversation the server already counted', async () => {
  api.list.mockResolvedValue({ data: [listed(5, 'Fifth'), listed(4, 'Fourth')], meta: { current_page: 1, total_pages: 3, total_count: 5, per_page: 2 } });
  api.get.mockImplementation((id) => Promise.resolve({ data: listed(id, 'Fifth') }));
  render(view());
  expect((await screen.findByText(/Showing/)).textContent).toBe('Showing 2 of 5 conversations');
  await waitFor(() => expect(mocks.callbacks).toHaveLength(1));

  await act(async () => mocks.callbacks[0].onThread({ thread: { ...listed(4, 'Fourth'), last_message_at: '2026-10-30T00:00:00Z' } }));
  await act(async () => mocks.callbacks[0].onThread({ thread: { ...listed(1, 'Oldest, not loaded yet'), last_message_at: '2026-10-31T00:00:00Z' } }));

  expect(screen.getByText(/Showing/).textContent).toBe('Showing 3 of 5 conversations');
});

it('reports send success distinctly when refreshing the saved reply fails', async () => {
  const current = thread(2, 'Saved conversation');
  api.list.mockResolvedValue({ data: [current] }); api.get.mockResolvedValue({ data: current });
  api.createMessage.mockResolvedValue({ data: { id: 10, thread_id: 2, body: 'Saved reply', created_at: '2026-11-12T00:00:00Z' } });
  render(view()); await waitFor(() => expect(api.get).toHaveBeenCalledOnce()); await screen.findByPlaceholderText('Reply client');
  api.get.mockRejectedValueOnce(new Error('refresh offline'));
  fireEvent.change(screen.getByPlaceholderText('Reply client'), { target: { value: 'Saved reply' } });
  fireEvent.click(screen.getByRole('button', { name: 'Send' }));
  await screen.findByText('Message sent. The conversation could not refresh. Reload to see it.');
  expect((screen.getByPlaceholderText('Reply client') as HTMLTextAreaElement).value).toBe('');
  expect(api.createMessage).toHaveBeenCalledOnce();
});

it('ignores an earlier broadcast fetch that finishes after a newer one', async () => {
  const current = thread(2, 'Starting conversation');
  api.list.mockResolvedValue({ data: [current] }); api.get.mockResolvedValue({ data: current });
  render(view()); await screen.findByPlaceholderText('Reply client'); await waitFor(() => expect(mocks.callbacks).toHaveLength(1));
  let older!: (response: { data: ClientPortalThread }) => void;
  let newer!: (response: { data: ClientPortalThread }) => void;
  api.get.mockImplementationOnce(() => new Promise(resolve => { older = resolve; })).mockImplementationOnce(() => new Promise(resolve => { newer = resolve; }));
  await act(async () => { mocks.callbacks[0].onThread({ thread: current }); mocks.callbacks[0].onThread({ thread: current }); });
  await act(async () => newer({ data: thread(2, 'Newest broadcast') }));
  expect(screen.getAllByText('Newest broadcast').length).toBeGreaterThan(0);
  await act(async () => older({ data: thread(2, 'Stale broadcast') }));
  expect(screen.queryByText('Stale broadcast')).toBeNull();
});

it('keeps a named file-archived tombstone and excludes archived files from attachment choices', async () => {
  const archived = { id: 9, title: 'Payroll hours', file_name: 'hours.csv', visible_to_client: true, archived_at: '2026-11-11T00:00:00Z' } as import('@/services/api').ClientDocument;
  const conversation = { ...thread(2, 'Payroll files'), messages: [{ id: 1, thread_id: 2, body: 'For payroll', author_name: 'Client', created_at: '2026-11-11T00:00:00Z', document: archived }] } as ClientPortalThread;
  api.list.mockResolvedValue({ data: [conversation] });
  api.get.mockResolvedValue({ data: conversation });
  render(routed(<PortalMessagesPanel api={api} documents={[archived]} audienceLabel="client" description="Client messages" />));
  expect(await screen.findByText('File archived: Payroll hours (hours.csv)')).toBeTruthy();
  expect(screen.queryByRole('option', { name: 'Payroll hours (hours.csv)' })).toBeNull();
  expect(screen.queryByRole('option', { name: 'Payroll hours (hours.csv)' })).toBeNull();
});

it('keeps the thread response archive tombstone when the document list is stale', async () => {
  const stale = { id: 9, title: 'Payroll hours', file_name: 'hours.csv', visible_to_client: true, archived_at: null } as import('@/services/api').ClientDocument;
  const conversation = { ...thread(2, 'Payroll files'), messages: [{ id: 1, thread_id: 2, body: 'For payroll', author_name: 'Client', created_at: '2026-11-11T00:00:00Z', document: { ...stale, archived_at: '2026-11-12T00:00:00Z' } }] } as ClientPortalThread;
  api.list.mockResolvedValue({ data: [conversation] });
  api.get.mockResolvedValue({ data: conversation });
  render(routed(<PortalMessagesPanel api={api} documents={[stale]} audienceLabel="client" description="Client messages" />));
  expect(await screen.findByText('File archived: Payroll hours (hours.csv)')).toBeTruthy();
  expect(screen.queryByRole('option', { name: 'Payroll hours (hours.csv)' })).toBeNull();
});

it('re-reads the open conversation after unarchive so the restored file can be attached again', async () => {
  const archived = { id: 9, title: 'Payroll hours', file_name: 'hours.csv', visible_to_client: true, archived_at: '2026-11-12T00:00:00Z' } as import('@/services/api').ClientDocument;
  const restored = { ...archived, archived_at: null };
  const messageWith = (document: typeof archived) => ({ ...thread(2, 'Payroll files'), messages: [{ id: 1, thread_id: 2, body: 'For payroll', author_name: 'Client', created_at: '2026-11-11T00:00:00Z', document }] } as ClientPortalThread);
  api.list.mockResolvedValue({ data: [messageWith(archived)] });
  api.get.mockResolvedValue({ data: messageWith(archived) });
  const rendered = render(routed(<PortalMessagesPanel api={api} documents={[archived]} audienceLabel="client" description="Client messages" />));
  expect(await screen.findByText('File archived: Payroll hours (hours.csv)')).toBeTruthy();
  const reads = api.get.mock.calls.length;

  api.get.mockResolvedValue({ data: messageWith(restored) });
  rendered.rerender(routed(<PortalMessagesPanel api={api} documents={[restored]} audienceLabel="client" description="Client messages" />));
  await waitFor(() => expect(screen.queryByText('File archived: Payroll hours (hours.csv)')).toBeNull());
  expect(api.get.mock.calls.length).toBe(reads + 1);
  expect(screen.getByRole('button', { name: 'Download hours.csv' })).toBeTruthy();

  // An unchanged list does not re-read the conversation.
  rendered.rerender(routed(<PortalMessagesPanel api={api} documents={[{ ...restored }]} audienceLabel="client" description="Client messages" />));
  expect(api.get.mock.calls.length).toBe(reads + 1);
});

it('reuses a conversation retry key after losing the create response', async () => {
  api.create.mockRejectedValueOnce(new Error('response lost')).mockResolvedValueOnce({ data: thread(2, 'Retry topic') });
  render(view()); await waitFor(() => expect(api.list).toHaveBeenCalledOnce());
  fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'Retry topic' } });
  fireEvent.click(screen.getByRole('button', { name: 'Start Conversation' }));
  await screen.findByText(/response lost/);
  fireEvent.click(screen.getByRole('button', { name: 'Start Conversation' }));
  await waitFor(() => expect(api.create).toHaveBeenCalledTimes(2));
  expect(api.create.mock.calls[0][0].idempotency_key).toBeTruthy();
  expect(api.create.mock.calls[1][0]).toEqual(api.create.mock.calls[0][0]);
});

it('refreshes the personal badge without loading conversation lists on a broadcast', async () => {
  const current = thread(2, 'Count only');
  api.list.mockResolvedValue({ data: [current] }); api.get.mockResolvedValue({ data: current });
  api.unreadCount.mockResolvedValue({ data: { unread_count: 3 } });
  render(view()); await screen.findByPlaceholderText('Reply client');
  const lists = api.list.mock.calls.length;
  await act(async () => mocks.callbacks[0].onThread({ thread: current }));
  await screen.findByText('3 unread');
  expect(api.list.mock.calls.length).toBe(lists);
  expect(api.unreadCount).toHaveBeenCalledOnce();
});

it('keeps a newer badge count when an older Load more page finishes last', async () => {
  const meta = (page: number) => ({ current_page: page, total_pages: 2, total_count: 2, per_page: 1, unread_count: 1 });
  const first = { ...thread(2, 'Newest conversation'), id: 2 };
  let finishPage!: (value: Awaited<ReturnType<ThreadsApi['list']>>) => void;
  api.list.mockImplementation((params) => params?.page === 2
    ? new Promise(resolve => { finishPage = resolve; })
    : Promise.resolve({ data: [first], meta: meta(1) }));
  api.get.mockResolvedValue({ data: first });
  render(view());
  await screen.findByText('1 unread');

  fireEvent.click(screen.getByRole('button', { name: 'Load more conversations' }));
  await waitFor(() => expect(api.list).toHaveBeenLastCalledWith({ page: 2 }));
  api.unreadCount.mockResolvedValue({ data: { unread_count: 0 } });
  await act(async () => mocks.callbacks[0].onThread({ thread: first }));
  await screen.findByText('0 unread');

  await act(async () => finishPage({ data: [{ ...thread(2, 'Older conversation'), id: 1 }], meta: meta(2) }));
  await screen.findByText('Older conversation');
  expect(screen.getByText('0 unread')).toBeTruthy();
});


it('recovers the phone conversation list when the exact inbox thread is unavailable', async () => {
  window.matchMedia = vi.fn().mockReturnValue({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() });
  api.list.mockResolvedValue({ data: [thread(2, 'Accessible conversation')] });
  api.get.mockRejectedValueOnce(new Error('Conversation is unavailable'));
  render(<MemoryRouter><PortalMessagesPanel api={api} documents={[]} initialThreadId={99} audienceLabel="client" description="Client messages" /></MemoryRouter>);
  await screen.findByText('Conversation is unavailable');
  const start = screen.getByRole('button', { name: 'New conversation' });
  expect(start.closest('.min-w-0.space-y-4')?.classList.contains('hidden')).toBe(false);
  api.get.mockResolvedValue({ data: thread(2, 'Accessible conversation') });
  fireEvent.click(screen.getByRole('button', { name: /Accessible conversation/ }));
  await screen.findByPlaceholderText('Reply client');
});


const doc = (id: number, title: string, extra: Partial<import('@/services/api').ClientDocument> = {}): import('@/services/api').ClientDocument => ({ id, title, file_name: `${title}.pdf`, file_size: 2048, content_type: 'application/pdf', visible_to_client: true, scan_status: 'not_scanned', preview_available: true, created_at: '2026-11-12T00:00:00Z', ...extra }) as import('@/services/api').ClientDocument;
type DocumentsApiMock = { [Key in keyof PortalDocumentsApi]: Mock<PortalDocumentsApi[Key]> };
const documentsApi = (): DocumentsApiMock => ({
  list: vi.fn<PortalDocumentsApi['list']>().mockResolvedValue({ data: [], meta: { total_pages: 1 } }),
  upload: vi.fn<PortalDocumentsApi['upload']>(),
  preview: vi.fn<PortalDocumentsApi['preview']>().mockResolvedValue({ blob: new Blob(['%PDF'], { type: 'application/pdf' }) }),
  download: vi.fn<PortalDocumentsApi['download']>().mockResolvedValue({ blob: new Blob(['%PDF'], { type: 'application/pdf' }), filename: 'hours.pdf' }),
  opened: vi.fn<PortalDocumentsApi['opened']>().mockResolvedValue(undefined),
  activity: vi.fn<PortalDocumentsApi['activity']>().mockResolvedValue({ data: [], meta: { current_page: 1, total_pages: 1, total_count: 0, per_page: 25 } as import('@/services/api').BoundedListMeta }),
});

it('uploads a device file once and reuses both retry keys when the send fails', async () => {
  const files = documentsApi();
  const current = thread(2, 'Hours');
  api.list.mockResolvedValue({ data: [current] }); api.get.mockResolvedValue({ data: current });
  files.upload.mockResolvedValue({ data: [doc(41, 'hours')] });
  api.createMessage.mockRejectedValueOnce(new Error('Network unavailable')).mockResolvedValueOnce({ data: { id: 5, thread_id: 2, created_at: '2026-11-12T00:00:00Z' } });
  const { container } = render(routed(<PortalMessagesPanel api={api} documents={[]} documentsApi={files} audienceLabel="client" description="Client messages" />));
  await screen.findByPlaceholderText('Reply client');
  const inputs = container.querySelectorAll('input[type="file"]');
  const replyInput = inputs[inputs.length - 1] as HTMLInputElement;
  fireEvent.change(replyInput, { target: { files: [new File(['%PDF-1.4'], 'hours.pdf', { type: 'application/pdf' })] } });
  expect(await screen.findByText('Uploads when you send')).toBeTruthy();
  fireEvent.change(screen.getByPlaceholderText('Reply client'), { target: { value: 'Hours attached' } });
  const sendButton = screen.getByRole('button', { name: 'Send' });
  fireEvent.click(sendButton);
  expect(await screen.findByText(/Network unavailable.*Your text and files are kept/)).toBeTruthy();
  expect(files.upload).toHaveBeenCalledOnce();
  const form = files.upload.mock.calls[0][0] as FormData;
  expect(form.get('for_message')).toBe('true');
  expect(form.get('upload_key')).toBeTruthy();
  expect((screen.getByPlaceholderText('Reply client') as HTMLTextAreaElement).value).toBe('Hours attached');

  fireEvent.click(sendButton);
  await waitFor(() => expect(api.createMessage).toHaveBeenCalledTimes(2));
  // The uploaded file is not sent again, and the message keeps its key.
  expect(files.upload).toHaveBeenCalledOnce();
  expect(api.createMessage.mock.calls[1][1]).toEqual(api.createMessage.mock.calls[0][1]);
  expect(api.createMessage.mock.calls[0][1]).toEqual(expect.objectContaining({ body: 'Hours attached', document_ids: [41] }));
  await waitFor(() => expect((screen.getByPlaceholderText('Reply client') as HTMLTextAreaElement).value).toBe(''));
});

it('keeps a failed upload visible with its key, so a retry cannot save the file twice', async () => {
  const files = documentsApi();
  const current = thread(2, 'Hours');
  api.list.mockResolvedValue({ data: [current] }); api.get.mockResolvedValue({ data: current });
  files.upload.mockRejectedValueOnce(new Error('Connection lost')).mockResolvedValueOnce({ data: [doc(42, 'timesheet')] });
  api.createMessage.mockResolvedValue({ data: { id: 6, thread_id: 2, created_at: '2026-11-12T00:00:00Z' } });
  const { container } = render(routed(<PortalMessagesPanel api={api} documents={[]} documentsApi={files} audienceLabel="client" description="Client messages" />));
  await screen.findByPlaceholderText('Reply client');
  const inputs = container.querySelectorAll('input[type="file"]');
  fireEvent.change(inputs[inputs.length - 1], { target: { files: [new File(['%PDF'], 'a-very-long-file-name-without-any-spaces-for-the-november-payroll-period.pdf', { type: 'application/pdf' })] } });
  fireEvent.click(screen.getByRole('button', { name: 'Send' }));
  expect(await screen.findByText('Not uploaded: Connection lost')).toBeTruthy();
  expect(api.createMessage).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Send' }));
  await waitFor(() => expect(api.createMessage).toHaveBeenCalledOnce());
  const keys = files.upload.mock.calls.map(call => (call[0] as FormData).get('upload_key'));
  expect(keys[0]).toBe(keys[1]);
});

it('attaches several existing files found by server search', async () => {
  const files = documentsApi();
  files.list.mockResolvedValue({ data: [doc(70, 'Riley timesheet'), doc(71, 'Sam timesheet')], meta: { total_pages: 1 } });
  const current = thread(2, 'Hours');
  api.list.mockResolvedValue({ data: [current] }); api.get.mockResolvedValue({ data: current });
  api.createMessage.mockResolvedValue({ data: { id: 7, thread_id: 2, created_at: '2026-11-12T00:00:00Z' } });
  render(routed(<PortalMessagesPanel api={api} documents={[]} documentsApi={files} audienceLabel="client" description="Client messages" />));
  await screen.findByPlaceholderText('Reply client');
  const pickers = screen.getAllByRole('button', { name: 'Choose existing file' });
  fireEvent.click(pickers[pickers.length - 1]);
  fireEvent.change(await screen.findByLabelText('Search files'), { target: { value: 'timesheet' } });
  await waitFor(() => expect(files.list).toHaveBeenLastCalledWith({ search: 'timesheet', attachable: true, page: 1, per_page: 20 }));
  fireEvent.click(await screen.findByRole('checkbox', { name: /Riley timesheet/ }));
  fireEvent.click(screen.getByRole('checkbox', { name: /Sam timesheet/ }));
  fireEvent.click(screen.getByRole('button', { name: 'Attach 2 files' }));
  fireEvent.click(screen.getByRole('button', { name: 'Send' }));
  await waitFor(() => expect(api.createMessage).toHaveBeenCalledWith(2, expect.objectContaining({ document_ids: [70, 71] })));
  expect(files.upload).not.toHaveBeenCalled();
});

it('shows every attachment with preview and download from the bubble', async () => {
  const files = documentsApi();
  const conversation = { ...thread(2, 'Files'), messages: [{ id: 1, thread_id: 2, kind: 'message', body: 'Two files', author_name: 'Client', created_at: '2026-11-11T00:00:00Z', documents: [doc(1, 'Week one'), doc(2, 'Week two')] }] } as ClientPortalThread;
  api.list.mockResolvedValue({ data: [conversation] }); api.get.mockResolvedValue({ data: conversation });
  render(routed(<PortalMessagesPanel api={api} documents={[]} documentsApi={files} audienceLabel="client" description="Client messages" />));
  fireEvent.click(await screen.findByRole('button', { name: 'Download Week two.pdf' }));
  await waitFor(() => expect(files.download).toHaveBeenCalledWith(2));
  fireEvent.click(screen.getByRole('button', { name: 'Preview Week one.pdf' }));
  await waitFor(() => expect(files.preview).toHaveBeenCalledWith(1));
});

it('returns from a phone conversation to the same filter and keeps the reply draft', async () => {
  window.matchMedia = vi.fn().mockReturnValue({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() });
  const first = { ...thread(2, 'First topic'), id: 21 };
  const second = { ...thread(2, 'Second topic'), id: 22 };
  api.list.mockResolvedValue({ data: [first, second] });
  api.get.mockImplementation(id => Promise.resolve({ data: id === 21 ? first : second }));
  render(<MemoryRouter initialEntries={['/messages?conversations=open']}><PortalMessagesPanel api={api} documents={[]} audienceLabel="client" description="Client messages" /></MemoryRouter>);
  await waitFor(() => expect(api.list).toHaveBeenCalledWith({ status: 'open' }));
  const shown = async (subject: string) => waitFor(() => expect(screen.getAllByText(subject)).toHaveLength(2));
  fireEvent.click(await screen.findByRole('button', { name: /Second topic/ }));
  await shown('Second topic');
  fireEvent.change(screen.getByPlaceholderText('Reply client'), { target: { value: 'Half-written answer' } });
  fireEvent.click(screen.getByRole('button', { name: 'Back to conversations' }));
  await waitFor(() => expect(screen.getByRole('button', { name: /Second topic/ }).closest('.min-w-0.space-y-4')?.classList.contains('hidden')).toBe(false));
  expect((screen.getByLabelText('Show') as HTMLSelectElement).value).toBe('open');
  await waitFor(() => expect(document.activeElement?.textContent).toContain('Second topic'));
  fireEvent.click(screen.getByRole('button', { name: /First topic/ }));
  await shown('First topic');
  expect((screen.getByPlaceholderText('Reply client') as HTMLTextAreaElement).value).toBe('');
  fireEvent.click(screen.getByRole('button', { name: 'Back to conversations' }));
  fireEvent.click(screen.getByRole('button', { name: /Second topic/ }));
  await shown('Second topic');
  await waitFor(() => expect((screen.getByPlaceholderText('Reply client') as HTMLTextAreaElement).value).toBe('Half-written answer'));
});

it('lets the client answer a file request with an upload, scoped to the requested file type', async () => {
  const files = documentsApi();
  files.upload.mockResolvedValue({ data: [doc(90, 'riley')] });
  const request = { id: 3, thread_id: 2, title: 'Riley timesheet', category: 'payroll_source', employee_id: 8, employee_name: 'Riley Cook', payroll_submission_period_label: 'Nov 2–15, 2026', due_on: '2026-11-18', status: 'requested', status_label: 'Waiting for the file', created_at: '2026-11-12T00:00:00Z', lock_version: 0 } as import('@/services/api').PortalFileRequest;
  const conversation = { ...thread(2, 'Payroll Nov 2–15'), open_file_request_count: 1, messages: [{ id: 1, thread_id: 2, kind: 'file_request', body: 'Please send it', author_name: 'Dafne', author_audience: 'staff', created_at: '2026-11-11T00:00:00Z', file_request: request }] } as ClientPortalThread;
  api.list.mockResolvedValue({ data: [conversation] }); api.get.mockResolvedValue({ data: conversation });
  const respond = vi.spyOn((await import('@/services/api')).clientPortalFileRequestsApi, 'respond').mockResolvedValue({ data: { ...request, status: 'responded', status_label: 'File sent' }, message: { id: 2, thread_id: 2, created_at: '2026-11-12T00:00:00Z' } });
  const { container } = render(routed(<PortalMessagesPanel api={api} documents={[]} documentsApi={files} audienceLabel="client" description="Client messages" />));
  expect(await screen.findByText('Waiting for the file')).toBeTruthy();
  expect(screen.getByText(/For Riley Cook · Pay period Nov 2–15, 2026 · Needed by Nov 18, 2026/)).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Upload requested file' }));
  fireEvent.click(screen.getByRole('button', { name: 'Send requested file' }));
  expect(await screen.findByText('Attach the requested file first.')).toBeTruthy();
  const section = screen.getByRole('region', { name: 'File request: Riley timesheet' });
  const input = section.querySelector('input[type="file"]') as HTMLInputElement;
  fireEvent.change(input, { target: { files: [new File(['%PDF'], 'riley.pdf', { type: 'application/pdf' })] } });
  fireEvent.click(screen.getByRole('button', { name: 'Send requested file' }));
  await waitFor(() => expect(respond).toHaveBeenCalledWith(3, expect.objectContaining({ document_ids: [90] })));
  const form = files.upload.mock.calls[0][0] as FormData;
  expect(form.get('category')).toBe('payroll_source');
  expect(form.get('employee_id')).toBe('8');
  expect(container).toBeTruthy();
  respond.mockRestore();
});

it('keeps the selected conversation in the URL on desktop without adding history', async () => {
  const first = { ...thread(2, 'First desk'), id: 31 };
  const second = { ...thread(2, 'Second desk'), id: 32 };
  api.list.mockResolvedValue({ data: [first, second] });
  api.get.mockImplementation(id => Promise.resolve({ data: id === 31 ? first : second }));
  let location = '';
  const Probe = (): null => { location = useLocation().search; return null; };
  render(<MemoryRouter initialEntries={['/messages']}><PortalMessagesPanel api={api} documents={[]} audienceLabel="client" description="Client messages" /><Probe /></MemoryRouter>);
  fireEvent.click(await screen.findByRole('button', { name: /Second desk/ }));
  await waitFor(() => expect(location).toBe('?thread_id=32'));
});

it('drops a live update that leaves the selected filter, and keeps the header on the all-conversations count', async () => {
  const listed = { ...thread(2, 'Resolved topic'), id: 41, status: 'resolved' as const };
  api.list.mockResolvedValue({ data: [listed], meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 25, unread_count: 0 } });
  api.unreadCount.mockResolvedValue({ data: { unread_count: 4 } });
  api.get.mockResolvedValue({ data: listed });
  render(<MemoryRouter initialEntries={['/messages?conversations=resolved']}><PortalMessagesPanel api={api} documents={[]} audienceLabel="client" description="Client messages" /></MemoryRouter>);
  await waitFor(() => expect(api.list).toHaveBeenCalledWith({ status: 'resolved' }));
  expect(await screen.findByText('4 unread')).toBeTruthy();
  await waitFor(() => expect(mocks.callbacks).toHaveLength(1));
  const reopened = { ...listed, status: 'open' as const };
  api.get.mockResolvedValue({ data: reopened });
  await act(async () => mocks.callbacks[0].onThread({ thread: reopened }));
  await waitFor(() => expect(screen.queryByRole('button', { name: /Resolved topic/ })).toBeNull());
  expect(screen.getByText('4 unread')).toBeTruthy();
});

it('ignores Load more from an old search while a new search is waiting for its first page', async () => {
  const files = documentsApi();
  files.list.mockImplementation(params => Promise.resolve(params?.search === 'new'
    ? { data: [doc(60, 'New match')], meta: { total_pages: 1 } }
    : { data: [doc(50, params?.page === 2 ? 'Old page two' : 'Old match')], meta: { total_pages: 2 } }));
  const current = thread(2, 'Hours');
  api.list.mockResolvedValue({ data: [current] }); api.get.mockResolvedValue({ data: current });
  render(routed(<PortalMessagesPanel api={api} documents={[]} documentsApi={files} audienceLabel="client" description="Client messages" />));
  await screen.findByPlaceholderText('Reply client');
  const pickers = screen.getAllByRole('button', { name: 'Choose existing file' });
  fireEvent.click(pickers[pickers.length - 1]);
  expect(await screen.findByRole('button', { name: 'Load more files' })).toBeTruthy();
  fireEvent.change(screen.getByLabelText('Search files'), { target: { value: 'new' } });
  // Pagination for the old search is gone as soon as the search changes.
  expect(screen.queryByRole('button', { name: 'Load more files' })).toBeNull();
  expect(await screen.findByRole('checkbox', { name: /New match/ })).toBeTruthy();
  expect(screen.queryByText('Old page two')).toBeNull();
  expect(files.list).not.toHaveBeenCalledWith(expect.objectContaining({ page: 2 }));
});

it.each(['pending', 'infected', 'error'] as const)('offers no preview or download for a %s file', async status => {
  const conversation = { ...thread(2, 'Files'), messages: [{ id: 1, thread_id: 2, kind: 'message', body: 'File', author_name: 'Client', created_at: '2026-11-11T00:00:00Z', documents: [doc(7, 'Scan', { scan_status: status })] }] } as ClientPortalThread;
  api.list.mockResolvedValue({ data: [conversation] }); api.get.mockResolvedValue({ data: conversation });
  render(routed(<PortalMessagesPanel api={api} documents={[]} documentsApi={documentsApi()} audienceLabel="client" description="Client messages" />));
  expect(await screen.findByText(status === 'pending' ? 'Safety check in progress' : /^Not available:/)).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Download Scan.pdf' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Preview Scan.pdf' })).toBeNull();
});

it('discards a preview that finishes after the preview was closed', async () => {
  const files = documentsApi();
  let finish!: (value: { blob: Blob }) => void;
  files.preview.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  const revoke = vi.fn(); const create = vi.fn().mockReturnValue('blob:late');
  Object.assign(URL, { createObjectURL: create, revokeObjectURL: revoke });
  const conversation = { ...thread(2, 'Files'), messages: [{ id: 1, thread_id: 2, kind: 'message', body: 'File', author_name: 'Client', created_at: '2026-11-11T00:00:00Z', documents: [doc(8, 'Week')] }] } as ClientPortalThread;
  api.list.mockResolvedValue({ data: [conversation] }); api.get.mockResolvedValue({ data: conversation });
  render(routed(<PortalMessagesPanel api={api} documents={[]} documentsApi={files} audienceLabel="client" description="Client messages" />));
  fireEvent.click(await screen.findByRole('button', { name: 'Preview Week.pdf' }));
  await screen.findByRole('dialog');
  fireEvent.keyDown(document.activeElement || document.body, { key: 'Escape' });
  await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  await act(async () => finish({ blob: new Blob(['%PDF'], { type: 'application/pdf' }) }));
  expect(create).toHaveBeenCalledOnce();
  expect(revoke).toHaveBeenCalledWith('blob:late');
  expect(screen.queryByRole('dialog')).toBeNull();
});

it('lets staff cancel asking again without sending that note with an acceptance, and reports a failed refresh after saving', async () => {
  const request = { id: 3, thread_id: 2, title: 'Timesheet', category: 'payroll_source', status: 'responded', status_label: 'File sent, waiting for Cornerstone', last_response_message_id: 9, created_at: '2026-11-12T00:00:00Z', lock_version: 0 } as import('@/services/api').PortalFileRequest;
  const conversation = { ...thread(2, 'Hours'), messages: [{ id: 1, thread_id: 2, kind: 'file_request', author_name: 'Dafne', author_audience: 'staff', created_at: '2026-11-11T00:00:00Z', file_request: request }] } as ClientPortalThread;
  api.list.mockResolvedValue({ data: [conversation] }); api.get.mockResolvedValue({ data: conversation });
  const services = await import('@/services/api');
  const accept = vi.spyOn(services.adminPortalFileRequestsApi, 'accept').mockResolvedValue({ data: { ...request, status: 'accepted', status_label: 'Accepted' }, message: { id: 10, thread_id: 2, created_at: '2026-11-12T00:00:00Z' } });
  render(routed(<PortalMessagesPanel api={api} documents={[]} documentsApi={documentsApi()} audience="staff" audienceLabel="to the client" description="Client messages" />));
  fireEvent.click(await screen.findByRole('button', { name: 'Ask again' }));
  fireEvent.change(screen.getByLabelText('What is still needed?'), { target: { value: 'Wrong week' } });
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  api.get.mockRejectedValueOnce(new Error('offline'));
  fireEvent.click(screen.getByRole('button', { name: 'Accept file' }));
  await waitFor(() => expect(accept).toHaveBeenCalledOnce());
  expect(accept.mock.calls[0][1]).toEqual(expect.objectContaining({ response_message_id: 9, body: undefined }));
  expect(await screen.findByText(/Saved\. The conversation could not refresh/)).toBeTruthy();
  expect(screen.queryByText('That did not save. Try again.')).toBeNull();
  accept.mockRestore();
});
