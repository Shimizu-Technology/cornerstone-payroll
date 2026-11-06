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
