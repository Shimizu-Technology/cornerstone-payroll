import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ClientPortalThread } from '@/services/api';
import { ApiError } from '@/services/api';
import { subscribeToClientPortalThreads } from './clientPortalCable';

type Mixin = {
  connected: () => void;
  received: (payload: { event: 'thread_updated'; thread: ClientPortalThread }) => void;
  disconnected: (options: { willAttemptReconnect: boolean }) => void;
  rejected: () => void;
};
const mocks = vi.hoisted(() => ({ ticket: vi.fn(), create: vi.fn(), mixins: [] as Mixin[], disconnects: [] as ReturnType<typeof vi.fn>[] }));
vi.mock('@/services/api', () => ({
  authApi: { createCableTicket: mocks.ticket }, getApiBaseUrl: () => 'http://localhost:44552/api/v1',
  ApiError: class extends Error { status: number; constructor(message: string, status: number) { super(message); this.status = status; } },
}));
vi.mock('@rails/actioncable', () => ({ createConsumer: mocks.create }));

beforeEach(() => {
  vi.useFakeTimers(); vi.clearAllMocks(); mocks.mixins.length = 0; mocks.disconnects.length = 0;
  mocks.ticket.mockResolvedValue({ ticket: 'synthetic-ticket', expires_in: 60 });
  mocks.create.mockImplementation(() => {
    const disconnect = vi.fn(); mocks.disconnects.push(disconnect);
    return { disconnect, subscriptions: { remove: vi.fn(), create: (_channel: unknown, mixin: Mixin) => { mocks.mixins.push(mixin); return {}; } } };
  });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); });

describe('client-scoped portal subscriptions', () => {
  it('pins every transient reconnect to the original company and ignores stale callbacks', async () => {
    const onThread = vi.fn(); const onConnected = vi.fn();
    const cleanup = await subscribeToClientPortalThreads(2, { onThread, onConnected });
    const old = mocks.mixins[0]; old.disconnected({ willAttemptReconnect: true });
    await vi.advanceTimersByTimeAsync(1000);
    expect(mocks.ticket.mock.calls).toEqual([[2], [2]]);
    old.connected(); old.received({ event: 'thread_updated', thread: { company_id: 2 } as ClientPortalThread });
    expect(onConnected).not.toHaveBeenCalled(); expect(onThread).not.toHaveBeenCalled();
    mocks.mixins[1].connected();
    expect(onConnected).toHaveBeenCalledOnce(); cleanup();
  });

  it.each(['revocation', 'rejection'])('stops instead of reconnecting after %s', async reason => {
    const onUnavailable = vi.fn();
    const cleanup = await subscribeToClientPortalThreads(2, { onThread: vi.fn(), onUnavailable });
    if (reason === 'revocation') mocks.mixins[0].disconnected({ willAttemptReconnect: false });
    else mocks.mixins[0].rejected();
    await vi.advanceTimersByTimeAsync(10000);
    expect(mocks.ticket).toHaveBeenCalledTimes(1); expect(onUnavailable).toHaveBeenCalledOnce();
    expect(mocks.disconnects[0]).toHaveBeenCalledOnce(); cleanup();
  });

  it.each([401, 403])('does not retry a terminal native ticket status %s', async status => {
    mocks.ticket.mockRejectedValue(new ApiError('Access unavailable', status));
    const onUnavailable = vi.fn();
    const cleanup = await subscribeToClientPortalThreads(2, { onThread: vi.fn(), onUnavailable });
    await vi.advanceTimersByTimeAsync(10000);
    expect(mocks.ticket).toHaveBeenCalledTimes(1); expect(mocks.create).not.toHaveBeenCalled();
    expect(onUnavailable).toHaveBeenCalledOnce(); cleanup();
  });

  it('retries a transient ticket outage with a fresh ticket for the same client', async () => {
    mocks.ticket.mockRejectedValueOnce(new ApiError('Temporary outage', 503));
    const cleanup = await subscribeToClientPortalThreads(2, { onThread: vi.fn() });
    await vi.advanceTimersByTimeAsync(2000);
    expect(mocks.ticket.mock.calls).toEqual([[2], [2]]); expect(mocks.create).toHaveBeenCalledOnce(); cleanup();
  });

  it('blocks another company payload and clears pending reconnect work on cleanup', async () => {
    const onThread = vi.fn(); const onUnavailable = vi.fn();
    const cleanup = await subscribeToClientPortalThreads(2, { onThread, onUnavailable });
    mocks.mixins[0].received({ event: 'thread_updated', thread: { company_id: 3 } as ClientPortalThread });
    await vi.advanceTimersByTimeAsync(10000);
    expect(onThread).not.toHaveBeenCalled(); expect(onUnavailable).toHaveBeenCalledOnce();
    expect(mocks.ticket).toHaveBeenCalledTimes(1); cleanup();
  });

  it('cancels a scheduled transient reconnect when the panel is removed', async () => {
    const cleanup = await subscribeToClientPortalThreads(2, { onThread: vi.fn() });
    mocks.mixins[0].disconnected({ willAttemptReconnect: true }); cleanup();
    await vi.advanceTimersByTimeAsync(10000); expect(mocks.ticket).toHaveBeenCalledTimes(1);
  });
});
