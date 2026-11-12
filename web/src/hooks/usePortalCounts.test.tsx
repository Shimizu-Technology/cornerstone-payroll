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
