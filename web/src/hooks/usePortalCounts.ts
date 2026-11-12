import { useEffect, useState } from 'react';
import { useLocation } from 'react-router';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { clientPortalThreadsApi } from '@/services/api';
import { subscribeToClientPortalThreads } from '@/services/clientPortalCable';
import { clientInboxApi, type InboxCounts } from '@/services/clientInbox';

export function usePortalCounts() {
  const { user } = useAuth();
  const { activeCompanyId } = useCompany();
  const location = useLocation();
  const [counts, setCounts] = useState<{ identity: string; data: InboxCounts } | null>(null);
  const userId = user?.id;
  const role = user?.role;
  const identity = `${userId}:${role}:${activeCompanyId}`;
  useEffect(() => {
    if (!userId || (role === 'client' && !activeCompanyId)) return;
    let active = true;
    let version = 0;
    const refresh = async () => {
      if (document.visibilityState === 'hidden') return;
      const request = ++version;
      try {
        const data = role === 'client'
          ? { unread_count: (await clientPortalThreadsApi.unreadCount()).data.unread_count, waiting_count: 0, unread_messages: 0, unread_documents: 0, pending_changes: 0 }
          : (await clientInboxApi.counts()).data;
        if (active && version === request) setCounts({ identity, data });
      } catch { if (active && version === request) setCounts(null); }
    };
    void refresh();
    let unsubscribe: (() => void) | undefined;
    if (activeCompanyId) void subscribeToClientPortalThreads(activeCompanyId, {
      onThread: () => { void refresh(); },
      onInboxChanged: () => window.dispatchEvent(new Event('portal-work-changed')),
      onConnected: () => { void refresh(); },
    }, role === 'client' ? 'ClientPortalThreadChannel' : 'ClientInboxChannel').then(cleanup => { if (active) unsubscribe = cleanup; else cleanup(); });
    const timer = window.setInterval(() => void refresh(), 60_000);
    const onRefresh = () => void refresh();
    window.addEventListener('focus', onRefresh);
    window.addEventListener('portal-work-changed', onRefresh);
    document.addEventListener('visibilitychange', onRefresh);
    return () => {
      active = false;
      unsubscribe?.();
      clearInterval(timer);
      window.removeEventListener('focus', onRefresh);
      window.removeEventListener('portal-work-changed', onRefresh);
      document.removeEventListener('visibilitychange', onRefresh);
    };
  }, [identity, userId, role, activeCompanyId, location.key]);
  return counts?.identity === identity ? counts.data : null;
}
