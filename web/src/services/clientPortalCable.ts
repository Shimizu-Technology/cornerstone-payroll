import { createConsumer, type Cable, type Channel } from '@rails/actioncable';
import { authApi, getApiBaseUrl } from '@/services/api';
import type { ClientPortalThread } from '@/services/api';

type PortalCablePayload = {
  event: 'thread_created' | 'thread_updated' | 'message_created';
  thread: Omit<ClientPortalThread, 'unread'> & { unread?: boolean };
};

type PortalCableCallbacks = {
  onThread: (payload: PortalCablePayload) => void;
  onError?: () => void;
};

function cableUrl(ticket: string) {
  const apiBase = getApiBaseUrl();
  const httpUrl = new URL(apiBase);
  const protocol = httpUrl.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = new URL(`${protocol}//${httpUrl.host}/cable`);
  url.searchParams.set('ticket', ticket);
  return url.toString();
}

export async function subscribeToClientPortalThreads(callbacks: PortalCableCallbacks) {
  const { ticket } = await authApi.createCableTicket();
  const consumer: Cable = createConsumer(cableUrl(ticket));
  const channel: Channel = consumer.subscriptions.create(
    { channel: 'ClientPortalThreadChannel' },
    {
      received(payload: PortalCablePayload) {
        callbacks.onThread(payload);
      },
      rejected() {
        callbacks.onError?.();
      },
    }
  );

  return () => {
    consumer.subscriptions.remove(channel);
    consumer.disconnect();
  };
}
