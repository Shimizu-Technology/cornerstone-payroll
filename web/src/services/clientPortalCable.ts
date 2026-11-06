import { createConsumer, type Cable, type Channel } from '@rails/actioncable';
import { ApiError, authApi, getApiBaseUrl } from '@/services/api';
import type { ClientPortalThread } from '@/services/api';

type PortalCablePayload = {
  event: 'thread_created' | 'thread_updated' | 'message_created';
  thread: Omit<ClientPortalThread, 'unread'> & { unread?: boolean };
};

type PortalCableCallbacks = {
  onThread: (payload: PortalCablePayload) => void;
  onConnected?: () => void;
  onError?: () => void;
  onUnavailable?: () => void;
};

function cableUrl(ticket: string) {
  const apiBase = getApiBaseUrl();
  const httpUrl = new URL(apiBase);
  const protocol = httpUrl.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = new URL(`${protocol}//${httpUrl.host}/cable`);
  url.searchParams.set('ticket', ticket);
  return url.toString();
}

export async function subscribeToClientPortalThreads(companyId: number, callbacks: PortalCableCallbacks) {
  let consumer: Cable | undefined;
  let channel: Channel | undefined;
  let stopped = false;
  let connecting = false;
  let connectionGeneration = 0;
  let reconnectTimer: ReturnType<typeof setTimeout> | undefined;

  const disconnectCurrent = () => {
    if (channel && consumer) {
      consumer.subscriptions.remove(channel);
    }
    consumer?.disconnect();
    channel = undefined;
    consumer = undefined;
  };

  const stopUnavailable = (generation: number) => {
    if (stopped || generation !== connectionGeneration) return;
    stopped = true;
    connectionGeneration += 1;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    disconnectCurrent();
    callbacks.onError?.();
    callbacks.onUnavailable?.();
  };

  const scheduleReconnect = (generation: number, delay = 1000) => {
    if (stopped || generation !== connectionGeneration) return;

    callbacks.onError?.();
    connectionGeneration += 1;
    disconnectCurrent();
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(() => {
      void connect();
    }, delay);
  };

  const connect = async () => {
    if (stopped || connecting) return;
    connecting = true;
    const generation = connectionGeneration + 1;
    connectionGeneration = generation;

    try {
      const { ticket } = await authApi.createCableTicket(companyId);
      if (stopped || generation !== connectionGeneration) return;

      disconnectCurrent();
      consumer = createConsumer(cableUrl(ticket));
      channel = consumer.subscriptions.create(
        { channel: 'ClientPortalThreadChannel' },
        {
          connected() {
            if (!stopped && generation === connectionGeneration) callbacks.onConnected?.();
          },
          received(payload: PortalCablePayload) {
            if (stopped || generation !== connectionGeneration) return;
            if (payload.thread.company_id !== companyId) {
              stopUnavailable(generation);
              return;
            }
            callbacks.onThread(payload);
          },
          disconnected({ willAttemptReconnect }: { willAttemptReconnect?: boolean } = {}) {
            if (willAttemptReconnect === false) stopUnavailable(generation);
            else scheduleReconnect(generation);
          },
          rejected() {
            stopUnavailable(generation);
          },
        }
      );
    } catch (error) {
      if (error instanceof ApiError && (error.status === 401 || error.status === 403)) {
        stopUnavailable(generation);
      } else if (!stopped && generation === connectionGeneration) {
        callbacks.onError?.();
        if (reconnectTimer) clearTimeout(reconnectTimer);
        reconnectTimer = setTimeout(() => {
          void connect();
        }, 2000);
      }
    } finally {
      connecting = false;
    }
  };

  await connect();

  return () => {
    stopped = true;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    disconnectCurrent();
  };
}
