import { useEffect, useRef } from 'react';
import type { ClientPortalThread, PortalReadDisplay } from '@/services/api';

// DOM visibility, focus and the server-issued fetched range are all required.
// Cable/prefetch can update data, but cannot themselves acknowledge a message.
export function useDisplayedMessages(thread: ClientPortalThread | null, enabled: boolean,
  markRead: (id: number, data: PortalReadDisplay) => Promise<unknown>) {
  const container = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const node = container.current;
    if (!node || !thread?.display_token || !enabled || !window.IntersectionObserver) return;
    const visible = new Set<number>();
    const sent = new Set<string>();
    let timer: ReturnType<typeof setTimeout>;
    let active = true;
    const flush = () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        if (!active || document.visibilityState !== 'visible' || !document.hasFocus() || node.closest('[inert]') || !node.getClientRects().length) return;
        const ids = [...visible].sort((a, b) => a - b);
        const key = ids.join(',');
        if (!ids.length || sent.has(key)) return;
        sent.add(key);
        void markRead(thread.id, { foreground: true, display_token: thread.display_token!, displayed_message_ids: ids })
          .catch(() => { sent.delete(key); });
      }, 200);
    };
    const observer = new IntersectionObserver(entries => {
      for (const entry of entries) {
        const id = Number((entry.target as HTMLElement).dataset.messageId);
        if (entry.isIntersecting && entry.intersectionRatio >= 0.5) visible.add(id);
        else visible.delete(id);
      }
      flush();
    }, { threshold: [0, 0.5, 1] });
    node.querySelectorAll('[data-message-id]').forEach(element => observer.observe(element));
    window.addEventListener('focus', flush);
    document.addEventListener('visibilitychange', flush);
    return () => { active = false; observer.disconnect(); clearTimeout(timer); window.removeEventListener('focus', flush); document.removeEventListener('visibilitychange', flush); };
  }, [thread, enabled, markRead]);
  return container;
}
