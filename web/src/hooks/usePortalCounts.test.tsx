// @vitest-environment jsdom
import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { usePortalCounts } from './usePortalCounts';
const mocks = vi.hoisted(() => ({ role: 'manager', counts: vi.fn(), unreadCount: vi.fn(), subscribe: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 3, role: mocks.role } }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 2 }) }));
vi.mock('@/services/clientInbox', () => ({ clientInboxApi: { counts: mocks.counts } }));
vi.mock('@/services/api', () => ({ clientPortalThreadsApi: { unreadCount: mocks.unreadCount } }));
vi.mock('@/services/clientPortalCable', () => ({ subscribeToClientPortalThreads: mocks.subscribe }));
beforeEach(() => { vi.clearAllMocks(); mocks.role = 'manager'; mocks.subscribe.mockResolvedValue(vi.fn()); });
afterEach(cleanup);
it('uses summary counts for staff and refreshes after live invalidation', async () => {
  mocks.counts.mockResolvedValue({ data: { unread_count: 210, waiting_count: 220 } });
  const { result } = renderHook(usePortalCounts, { wrapper: MemoryRouter });
  await waitFor(() => expect(result.current?.waiting_count).toBe(220));
  expect(mocks.unreadCount).not.toHaveBeenCalled();
  mocks.counts.mockResolvedValue({ data: { unread_count: 211, waiting_count: 221 } });
  await act(async () => { window.dispatchEvent(new Event('portal-work-changed')); });
  await waitFor(() => expect(result.current?.waiting_count).toBe(221));
});
it('uses the personal unread-count endpoint for client Messages', async () => {
  mocks.role = 'client';
  mocks.unreadCount.mockResolvedValue({ data: { unread_count: 207 } });
  const { result } = renderHook(usePortalCounts, { wrapper: MemoryRouter });
  await waitFor(() => expect(result.current?.unread_count).toBe(207));
  expect(mocks.counts).not.toHaveBeenCalled();
});

it('coalesces duplicate org subscriptions and a thread/message event burst', async () => {
  mocks.counts.mockResolvedValue({ data: { unread_count: 1, waiting_count: 1 } });
  const first = renderHook(usePortalCounts, { wrapper: MemoryRouter });
  const second = renderHook(usePortalCounts, { wrapper: MemoryRouter });
  await waitFor(() => expect(second.result.current?.unread_count).toBe(1));
  await waitFor(() => expect(first.result.current?.unread_count).toBe(1));
  const before = mocks.counts.mock.calls.length;
  const event = vi.fn();
  window.addEventListener('portal-work-changed', event);
  try {
    mocks.counts.mockResolvedValue({ data: { unread_count: 2, waiting_count: 2 } });
    act(() => { for (const [, callbacks] of mocks.subscribe.mock.calls) { callbacks.onInboxChanged(); callbacks.onInboxChanged(); callbacks.onThread(); } });
    await waitFor(() => expect(first.result.current?.unread_count).toBe(2));
    expect(second.result.current?.unread_count).toBe(2);
    expect(event).toHaveBeenCalledOnce();
    expect(mocks.counts.mock.calls.length - before).toBe(2);
  } finally { window.removeEventListener('portal-work-changed', event); }
});
