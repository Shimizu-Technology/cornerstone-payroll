import { useEffect, useRef, type RefObject } from 'react';
import type { ClientPortalThread, PortalReadDisplay } from '@/services/api';

// DOM visibility, focus and the server-issued fetched range are all required.
// Cable/prefetch can update data, but cannot themselves acknowledge a message.
export function useDisplayedMessages(thread: ClientPortalThread | null, enabled: boolean,
  markRead: (id: number, data: PortalReadDisplay) => Promise<unknown>): RefObject<HTMLDivElement | null> {
  const container = useRef<HTMLDivElement>(null);
  // Every message shown in the foreground so far, per conversation. The server
  // advances the cursor only through a contiguous shown run, so reporting just
  // the current viewport would strand a message seen before scrolling away.
  const shownByThread = useRef(new Map<number, Set<number>>());
  useEffect(() => {
    const node = container.current;
    if (!node || !thread?.display_token || !enabled || !window.IntersectionObserver) return;
    const visible = new Set<number>();
    const shown = shownByThread.current.get(thread.id) ?? new Set<number>();
    shownByThread.current.set(thread.id, shown);
    const loaded = new Set((thread.messages || []).map(message => message.id));
    const sent = new Set<string>();
    let timer: ReturnType<typeof setTimeout>;
    let active = true;
    const flush = () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        if (!active || document.visibilityState !== 'visible' || !document.hasFocus() || node.closest('[inert]') || document.querySelector('[role="dialog"][aria-modal="true"]') || !node.getClientRects().length) return;
        visible.forEach(id => shown.add(id));
        const ids = [...shown].filter(id => loaded.has(id)).sort((a, b) => a - b);
        const key = ids.join(',');
        if (!visible.size || !ids.length || sent.has(key)) return;
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
    const overlays = new MutationObserver(flush);
    overlays.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['aria-modal', 'inert'] });
    window.addEventListener('focus', flush);
    document.addEventListener('visibilitychange', flush);
    return () => { active = false; observer.disconnect(); overlays.disconnect(); clearTimeout(timer); window.removeEventListener('focus', flush); document.removeEventListener('visibilitychange', flush); };
  }, [thread, enabled, markRead]);
  return container;
}
