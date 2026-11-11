// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi, type Mock } from 'vitest';
import type { ComponentProps } from 'react';
import type { ClientPortalThread } from '@/services/api';
import { PortalMessagesPanel } from './PortalMessagesPanel';

type Callbacks = { onConnected: () => void; onUnavailable: () => void; onError: () => void; onThread: (value: { thread: ClientPortalThread }) => void };
const mocks = vi.hoisted(() => ({ company: 2, refresh: vi.fn(), subscribe: vi.fn(), callbacks: [] as Callbacks[] }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 5 } }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: mocks.company, refreshCompanies: mocks.refresh }) }));
vi.mock('@/services/clientPortalCable', () => ({ subscribeToClientPortalThreads: mocks.subscribe }));
const thread = (companyId: number, subject: string) => ({ id: companyId, company_id: companyId, subject, status: 'open', created_at: '2026-10-12T00:00:00Z', updated_at: '2026-10-12T00:00:00Z', unread: false, messages: [] } as ClientPortalThread);
type ThreadsApi = ComponentProps<typeof PortalMessagesPanel>['api'];
let api: { [Key in keyof ThreadsApi]: Mock<ThreadsApi[Key]> };
const view = () => <PortalMessagesPanel api={api} documents={[]} audienceLabel="client" description="Client messages" />;

beforeEach(() => {
  vi.clearAllMocks(); mocks.company = 2; mocks.callbacks.length = 0; mocks.refresh.mockResolvedValue(undefined);
  mocks.subscribe.mockImplementation((_company: number, callbacks: Callbacks) => { mocks.callbacks.push(callbacks); return Promise.resolve(vi.fn()); });
  api = { list: vi.fn<ThreadsApi['list']>().mockResolvedValue({ data: [] }), get: vi.fn<ThreadsApi['get']>(), create: vi.fn<ThreadsApi['create']>(), update: vi.fn<ThreadsApi['update']>(), createMessage: vi.fn<ThreadsApi['createMessage']>() };
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
  fireEvent.change(screen.getByPlaceholderText('Subject'), { target: { value: 'Pending conversation' } });
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

it('keeps a named file-archived tombstone and excludes archived files from attachment choices', async () => {
  const archived = { id: 9, title: 'Payroll hours', file_name: 'hours.csv', archived_at: '2026-11-11T00:00:00Z' } as import('@/services/api').ClientDocument;
  const conversation = { ...thread(2, 'Payroll files'), messages: [{ id: 1, thread_id: 2, body: 'For payroll', author_name: 'Client', created_at: '2026-11-11T00:00:00Z', document: archived }] } as ClientPortalThread;
  api.list.mockResolvedValue({ data: [conversation] });
  api.get.mockResolvedValue({ data: conversation });
  render(<PortalMessagesPanel api={api} documents={[archived]} audienceLabel="client" description="Client messages" />);
  expect(await screen.findByText('File archived: Payroll hours (hours.csv)')).toBeTruthy();
  expect(screen.queryByRole('option', { name: 'Payroll hours (hours.csv)' })).toBeNull();
  expect(screen.queryByRole('option', { name: 'Payroll hours (hours.csv)' })).toBeNull();
});

it.each(['archived', 'pending', 'infected', 'error', 'removed'])('clears both attachment selections when a document becomes %s', async (state) => {
  const document = { id: 9, title: 'Payroll hours', file_name: 'hours.csv', scan_status: 'clean' } as import('@/services/api').ClientDocument;
  const conversation = thread(2, 'Payroll files');
  api.list.mockResolvedValue({ data: [conversation] });
  api.get.mockResolvedValue({ data: conversation });
  const panel = (documents: import('@/services/api').ClientDocument[]) => <PortalMessagesPanel api={api} documents={documents} audienceLabel="client" description="Client messages" />;
  const rendered = render(panel([document]));
  await screen.findByPlaceholderText('Reply client');
  const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
  selects.forEach(select => fireEvent.change(select, { target: { value: '9' } }));
  // A refresh which keeps this document usable must preserve both selections.
  rendered.rerender(panel([{ ...document }]));
  selects.forEach(select => expect(select.value).toBe('9'));
  const next = state === 'removed' ? [] : [{ ...document, ...(state === 'archived' ? { archived_at: '2026-11-12T00:00:00Z' } : { scan_status: state as 'pending' | 'infected' | 'error' }) }];
  rendered.rerender(panel(next));
  await waitFor(() => selects.forEach(select => expect(select.value).toBe('')));
  if (['pending', 'infected', 'error'].includes(state)) {
    const options = screen.getAllByRole('option', { name: /Safety check unavailable/ }) as HTMLOptionElement[];
    expect(options).toHaveLength(2);
    options.forEach(option => expect(option.disabled).toBe(true));
  }
  fireEvent.change(screen.getByPlaceholderText('Subject'), { target: { value: 'New message' } });
  fireEvent.change(screen.getByPlaceholderText('Reply client'), { target: { value: 'Reply text' } });
  api.create.mockResolvedValue({ data: conversation });
  api.createMessage.mockResolvedValue({ data: {} as import('@/services/api').ClientPortalMessage });
  fireEvent.click(screen.getByRole('button', { name: 'Start Conversation' }));
  await waitFor(() => expect(api.create).toHaveBeenCalledWith(expect.objectContaining({ document_id: undefined })));
  // Start conversation completion clears its draft, but must not restore a stale reply attachment.
  fireEvent.click(screen.getByRole('button', { name: 'Send' }));
  await waitFor(() => expect(api.createMessage).toHaveBeenCalledWith(2, expect.objectContaining({ document_id: undefined })));
});

it('keeps the thread response archive tombstone when the document list is stale', async () => {
  const stale = { id: 9, title: 'Payroll hours', file_name: 'hours.csv', archived_at: null } as import('@/services/api').ClientDocument;
  const conversation = { ...thread(2, 'Payroll files'), messages: [{ id: 1, thread_id: 2, body: 'For payroll', author_name: 'Client', created_at: '2026-11-11T00:00:00Z', document: { ...stale, archived_at: '2026-11-12T00:00:00Z' } }] } as ClientPortalThread;
  api.list.mockResolvedValue({ data: [conversation] });
  api.get.mockResolvedValue({ data: conversation });
  render(<PortalMessagesPanel api={api} documents={[stale]} audienceLabel="client" description="Client messages" />);
  expect(await screen.findByText('File archived: Payroll hours (hours.csv)')).toBeTruthy();
  expect(screen.queryByRole('option', { name: 'Payroll hours (hours.csv)' })).toBeNull();
});

it('re-reads the open conversation after unarchive so the restored file can be attached again', async () => {
  const archived = { id: 9, title: 'Payroll hours', file_name: 'hours.csv', archived_at: '2026-11-12T00:00:00Z' } as import('@/services/api').ClientDocument;
  const restored = { ...archived, archived_at: null };
  const messageWith = (document: typeof archived) => ({ ...thread(2, 'Payroll files'), messages: [{ id: 1, thread_id: 2, body: 'For payroll', author_name: 'Client', created_at: '2026-11-11T00:00:00Z', document }] } as ClientPortalThread);
  api.list.mockResolvedValue({ data: [messageWith(archived)] });
  api.get.mockResolvedValue({ data: messageWith(archived) });
  const rendered = render(<PortalMessagesPanel api={api} documents={[archived]} audienceLabel="client" description="Client messages" />);
  expect(await screen.findByText('File archived: Payroll hours (hours.csv)')).toBeTruthy();
  const reads = api.get.mock.calls.length;

  api.get.mockResolvedValue({ data: messageWith(restored) });
  rendered.rerender(<PortalMessagesPanel api={api} documents={[restored]} audienceLabel="client" description="Client messages" />);
  await waitFor(() => expect(screen.queryByText('File archived: Payroll hours (hours.csv)')).toBeNull());
  expect(api.get.mock.calls.length).toBe(reads + 1);
  expect(screen.getAllByRole('option', { name: 'Payroll hours (hours.csv)' }).length).toBeGreaterThan(0);

  // An unchanged list does not re-read the conversation.
  rendered.rerender(<PortalMessagesPanel api={api} documents={[{ ...restored }]} audienceLabel="client" description="Client messages" />);
  expect(api.get.mock.calls.length).toBe(reads + 1);
});
