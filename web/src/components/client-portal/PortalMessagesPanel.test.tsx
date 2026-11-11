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
  window.matchMedia = vi.fn().mockReturnValue({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() });
  vi.clearAllMocks(); mocks.company = 2; mocks.callbacks.length = 0; mocks.refresh.mockResolvedValue(undefined);
  mocks.subscribe.mockImplementation((_company: number, callbacks: Callbacks) => { mocks.callbacks.push(callbacks); return Promise.resolve(vi.fn()); });
  api = { activity: vi.fn().mockResolvedValue({ data: [], meta: {} }), markRead: vi.fn(), list: vi.fn<ThreadsApi['list']>().mockResolvedValue({ data: [] }), get: vi.fn<ThreadsApi['get']>(), create: vi.fn<ThreadsApi['create']>(), update: vi.fn<ThreadsApi['update']>(), createMessage: vi.fn<ThreadsApi['createMessage']>() };
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
