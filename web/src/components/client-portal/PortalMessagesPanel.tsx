import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { ArrowLeft, CheckCircle2, FileQuestion, MessageSquare, Plus, Wifi } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Select } from '@/components/ui/select';
import { LoadMoreFooter } from '@/components/ui/load-more';
import { appendUniqueById, hasMorePages } from '@/lib/paged-list';
import { InboxReturnLink } from './InboxReturnLink';
import { ResourceActivity, type ResourceActivityApi } from './ResourceActivity';
import { useDisplayedMessages } from './useDisplayedMessages';
import { MessageComposer, type ComposerSend } from './MessageComposer';
import { MessageAttachments } from './MessageAttachments';
import { FileRequestCard } from './FileRequestCard';
import { stepLabel, type PortalDocumentsApi } from './portalFiles';
import { RequestFileDialog } from './RequestFileDialog';
import { hasDraft } from './messageDrafts';
import { useCompany } from '@/contexts/CompanyContext';
import { subscribeToClientPortalThreads } from '@/services/clientPortalCable';
import type { BoundedListMeta, ClientDocument, ClientPortalMessage, ClientPortalThread, PortalReadDisplay } from '@/services/api';

type PortalThreadsApi = ResourceActivityApi & {
  unreadCount: () => Promise<{ data: { unread_count: number } }>;
  list: (params?: { status?: string; page?: number }) => Promise<{ data: ClientPortalThread[]; meta?: BoundedListMeta & { unread_count?: number } }>;
  markRead: (id: number, data: PortalReadDisplay) => Promise<{ data: ClientPortalThread }>;
  get: (id: number) => Promise<{ data: ClientPortalThread }>;
  create: (data: { subject: string; body?: string; document_ids?: number[]; idempotency_key: string }) => Promise<{ data: ClientPortalThread }>;
  update: (id: number, data: { subject?: string; status?: 'open' | 'resolved' }) => Promise<{ data: ClientPortalThread }>;
  createMessage: (threadId: number, data: { body?: string; document_ids?: number[]; idempotency_key: string }) => Promise<{ data: ClientPortalMessage }>;
};

type Props = {
  api: PortalThreadsApi;
  documents: ClientDocument[];
  documentsApi?: PortalDocumentsApi;
  audience?: 'client' | 'staff';
  audienceLabel: string;
  description: string;
  canResolve?: boolean;
  initialThreadId?: number | null;
};

const FILTERS = [{ value: '', label: 'All conversations' }, { value: 'open', label: 'Open' }, { value: 'resolved', label: 'Resolved' }];
const noDocumentsApi: PortalDocumentsApi = {
  list: () => Promise.resolve({ data: [] }),
  upload: () => Promise.reject(new Error('Uploads are not available here.')),
  preview: () => Promise.reject(new Error('Preview is not available here.')),
  download: () => Promise.reject(new Error('Download is not available here.')),
  opened: () => Promise.resolve(),
  activity: () => Promise.resolve({ data: [], meta: { current_page: 1, total_pages: 1, total_count: 0, per_page: 25 } as BoundedListMeta }),
};

function formatDateTime(value?: string | null) {
  if (!value) return 'No messages yet';
  return new Date(value).toLocaleString('en-US', { timeZone: 'Pacific/Guam' });
}

function upsertThread(threads: ClientPortalThread[], next: ClientPortalThread) {
  const exists = threads.some((thread) => thread.id === next.id);
  const merged = exists ? threads.map((thread) => (thread.id === next.id ? next : thread)) : [next, ...threads];
  return merged.sort((a, b) => {
    const aTime = new Date(a.last_message_at || a.created_at).getTime();
    const bTime = new Date(b.last_message_at || b.created_at).getTime();
    return bTime - aTime || b.id - a.id;
  });
}

function messageDocuments(message: ClientPortalMessage): ClientDocument[] {
  if (message.documents) return message.documents;
  return message.document ? [message.document] : [];
}

function preview(message?: ClientPortalMessage | null): string {
  if (!message) return 'No message body';
  if (message.kind === 'file_request' && message.file_request) return `File requested: ${message.file_request.title}`;
  return stepLabel(message) || message.body || messageDocuments(message)[0]?.title || 'No message body';
}

export function PortalMessagesPanel(props: Props) {
  const { activeCompanyId, refreshCompanies } = useCompany();
  return <PortalMessagesContent key={activeCompanyId} {...props} companyId={activeCompanyId} refreshCompanies={refreshCompanies} />;
}

function PortalMessagesContent({ api, documents, documentsApi = noDocumentsApi, audience = 'client', initialThreadId = null, audienceLabel, description, canResolve = false, companyId, refreshCompanies }: Props & {
  companyId: number | null;
  refreshCompanies: () => Promise<void>;
}) {
  const panelRef = useRef<HTMLDivElement>(null);
  const [searchParams, setSearchParams] = useSearchParams();
  const navigate = useNavigate();
  const filter = FILTERS.some(option => option.value === searchParams.get('conversations')) ? searchParams.get('conversations') || '' : '';
  const urlThreadId = Number(searchParams.get('thread_id')) || null;
  useEffect(() => {
    if (initialThreadId) panelRef.current?.scrollIntoView?.({ block: 'start' });
  }, [initialThreadId]);
  const [unreadCount, setUnreadCount] = useState<number | null>(null);
  const unreadFetchVersion = useRef(0);
  const threadFetchVersions = useRef(new Map<number, number>());
  const [threads, setThreads] = useState<ClientPortalThread[]>([]);
  const [threadsMeta, setThreadsMeta] = useState<BoundedListMeta | null>(null);
  // Ids already included in meta.total_count: rows from list pages, plus live
  // rows a later page response has since counted. A conversation that arrives
  // live, is not counted, and has an id above every listed id was created after
  // the list was read, so it is added to the shown total until a page counts it.
  // A live update to an older, not-yet-loaded conversation (lower id) is
  // already in total_count and is not added.
  const countedThreadIds = useRef(new Set<number>());
  const maxListedThreadId = useRef(0);
  const [liveNewThreadIds, setLiveNewThreadIds] = useState<number[]>([]);
  const liveNewThreadIdsRef = useRef<number[]>([]);
  const [loadingMore, setLoadingMore] = useState(false);
  const [loadMoreError, setLoadMoreError] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<number | null>(initialThreadId || urlThreadId);
  const [selectedThread, setSelectedThread] = useState<ClientPortalThread | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [connected, setConnected] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [refreshingAccess, setRefreshingAccess] = useState(false);
  const [connectionAttempt, setConnectionAttempt] = useState(0);
  const unavailableRef = useRef(false);
  const dataGeneration = useRef(0);
  const [mobileConversationOpen, setMobileConversationOpen] = useState(Boolean(initialThreadId || urlThreadId));
  const [newFormOpen, setNewFormOpen] = useState(() => hasDraft(`${companyId}:new`));
  const [requestOpen, setRequestOpen] = useState<{ threadId: number | null; subject: string | null } | null>(null);
  // Phone history: opening a conversation pushes an entry, so the browser's
  // Back and the in-page Back both return to the same filtered list.
  const pushedConversation = useRef(false);
  const listScroll = useRef(0);
  const restoreListFocus = useRef<number | null>(null);
  const rowRefs = useRef(new Map<number, HTMLButtonElement>());
  const conversationHeading = useRef<HTMLParagraphElement>(null);
  const scrollToEnd = useRef(false);

  const [desktop, setDesktop] = useState(() => window.matchMedia('(min-width: 1024px)').matches);
  useEffect(() => {
    const query = window.matchMedia('(min-width: 1024px)');
    const update = () => setDesktop(query.matches);
    query.addEventListener('change', update);
    return () => query.removeEventListener('change', update);
  }, []);
  const scrollContainer = (): HTMLElement | null => panelRef.current?.closest('main') ?? null;

  const openConversation = useCallback((id: number): void => {
    setSelectedId(id);
    setMobileConversationOpen(true);
    if (desktop) return;
    listScroll.current = scrollContainer()?.scrollTop ?? window.scrollY;
    restoreListFocus.current = id;
    if (Number(searchParams.get('thread_id')) === id) return;
    const next = new URLSearchParams(searchParams);
    next.set('thread_id', String(id));
    pushedConversation.current = true;
    setSearchParams(next);
  }, [desktop, searchParams, setSearchParams]);

  const closeConversation = useCallback((): void => {
    setMobileConversationOpen(false);
    if (!searchParams.get('thread_id')) return;
    if (pushedConversation.current) {
      pushedConversation.current = false;
      navigate(-1);
      return;
    }
    const next = new URLSearchParams(searchParams);
    next.delete('thread_id');
    setSearchParams(next, { replace: true });
  }, [navigate, searchParams, setSearchParams]);

  // The browser's Back and Forward drive the phone view.
  const previousUrlThread = useRef(urlThreadId);
  useEffect(() => {
    const previous = previousUrlThread.current;
    previousUrlThread.current = urlThreadId;
    if (previous === urlThreadId) return;
    if (urlThreadId) { setSelectedId(urlThreadId); setMobileConversationOpen(true); }
    else { pushedConversation.current = false; setMobileConversationOpen(false); }
  }, [urlThreadId]);

  // Back on a phone restores the list's scroll position and focus.
  useLayoutEffect(() => {
    if (desktop || mobileConversationOpen) return;
    const container = scrollContainer();
    if (container) container.scrollTop = listScroll.current; else if (listScroll.current) window.scrollTo(0, listScroll.current);
    const id = restoreListFocus.current;
    restoreListFocus.current = null;
    if (id) rowRefs.current.get(id)?.focus({ preventScroll: true });
  }, [desktop, mobileConversationOpen]);

  const selectedThreadId = selectedThread?.id;
  useEffect(() => {
    if (!desktop && mobileConversationOpen && selectedThreadId) conversationHeading.current?.focus({ preventScroll: true });
  }, [desktop, mobileConversationOpen, selectedThreadId]);

  const fetchThread = useCallback(async (id: number): Promise<{ data: ClientPortalThread } | null> => {
    const version = (threadFetchVersions.current.get(id) ?? 0) + 1;
    threadFetchVersions.current.set(id, version);
    const response = await api.get(id);
    return threadFetchVersions.current.get(id) === version ? response : null;
  }, [api]);
  // List pages also carry an unread count. Apply one only if no count request
  // started after the page was requested, and retire any older one in flight.
  const applyPageUnreadCount = useCallback((requestedAt: number, count: number | undefined): void => {
    if (requestedAt !== unreadFetchVersion.current) return;
    unreadFetchVersion.current += 1;
    setUnreadCount(count ?? null);
  }, []);

  const refreshUnreadCount = useCallback(async (): Promise<void> => {
    const generation = dataGeneration.current;
    const version = ++unreadFetchVersion.current;
    const response = await api.unreadCount();
    if (generation === dataGeneration.current && version === unreadFetchVersion.current && !unavailableRef.current) setUnreadCount(response.data.unread_count);
  }, [api]);
  const markDisplayed = useCallback(async (id: number, data: PortalReadDisplay): Promise<void> => {
    const response = await api.markRead(id, data);
    if (unavailableRef.current) return;
    setThreads(current => current.map(thread => thread.id === id ? { ...thread, unread: response.data.unread } : thread));
    await refreshUnreadCount();
    window.dispatchEvent(new Event('portal-work-changed'));
  }, [api, refreshUnreadCount]);
  const messagesContainer = useDisplayedMessages(selectedThread, !unavailable && (desktop || mobileConversationOpen), markDisplayed);

  const updateLiveNewThreadIds = useCallback((update: (ids: number[]) => number[]): void => {
    liveNewThreadIdsRef.current = update(liveNewThreadIdsRef.current);
    setLiveNewThreadIds(liveNewThreadIdsRef.current);
  }, []);

  const resetThreadCounts = useCallback((listed: ClientPortalThread[]): void => {
    countedThreadIds.current = new Set(listed.map(thread => thread.id));
    maxListedThreadId.current = listed.reduce((max, thread) => Math.max(max, thread.id), 0);
    updateLiveNewThreadIds(() => []);
  }, [updateLiveNewThreadIds]);

  const noteLiveThread = useCallback((thread: ClientPortalThread): void => {
    if (countedThreadIds.current.has(thread.id) || thread.id <= maxListedThreadId.current) return;
    updateLiveNewThreadIds(ids => (ids.includes(thread.id) ? ids : [...ids, thread.id]));
  }, [updateLiveNewThreadIds]);

  const listParams = useCallback((page?: number) => {
    const params: { status?: string; page?: number } = {};
    if (filter) params.status = filter;
    if (page) params.page = page;
    return Object.keys(params).length ? params : undefined;
  }, [filter]);

  const loadThreads = useCallback(async () => {
    if (!companyId || unavailableRef.current) return;
    const generation = dataGeneration.current;
    const unreadRequestedAt = unreadFetchVersion.current;
    try {
      setLoading(true);
      setError(null);
      const response = await api.list(listParams());
      if (generation !== dataGeneration.current || unavailableRef.current) return;
      const companyThreads = response.data.filter(thread => thread.company_id === companyId);
      setThreads(companyThreads);
      setThreadsMeta(response.meta ?? null);
      applyPageUnreadCount(unreadRequestedAt, response.meta?.unread_count);
      resetThreadCounts(companyThreads);
      setLoadMoreError(null);
      setSelectedId((current) => current || response.data.find(thread => thread.company_id === companyId)?.id || null);
    } catch (err) {
      if (generation === dataGeneration.current && !unavailableRef.current) setError(err instanceof Error ? err.message : 'Failed to load messages');
    } finally {
      if (generation === dataGeneration.current && !unavailableRef.current) setLoading(false);
    }
  }, [api, applyPageUnreadCount, companyId, listParams, resetThreadCounts, setError]);

  useEffect(() => {
    void loadThreads();
  }, [loadThreads, connectionAttempt]);

  const loadMoreThreads = async () => {
    if (!companyId || !threadsMeta || unavailableRef.current) return;
    const generation = dataGeneration.current;
    // Live conversations that arrived before this request are in its total_count.
    const countedByRequest = [...liveNewThreadIdsRef.current];
    const unreadRequestedAt = unreadFetchVersion.current;
    try {
      setLoadingMore(true);
      setLoadMoreError(null);
      const response = await api.list(listParams(threadsMeta.current_page + 1));
      if (generation !== dataGeneration.current || unavailableRef.current) return;
      const pageThreads = response.data.filter(thread => thread.company_id === companyId);
      const nowCounted = new Set([...countedByRequest, ...pageThreads.map(thread => thread.id)]);
      nowCounted.forEach(id => countedThreadIds.current.add(id));
      updateLiveNewThreadIds(ids => ids.filter(id => !nowCounted.has(id)));
      setThreads((current) => appendUniqueById(current, pageThreads));
      setThreadsMeta(response.meta ?? null);
      applyPageUnreadCount(unreadRequestedAt, response.meta?.unread_count);
    } catch (err) {
      if (generation === dataGeneration.current) setLoadMoreError(err instanceof Error ? err.message : 'Failed to load more conversations');
    } finally {
      setLoadingMore(false);
    }
  };

  useEffect(() => {
    if (!companyId) return;
    let active = true;
    let unsubscribe: (() => void) | undefined;
    subscribeToClientPortalThreads(companyId, {
      onThread: ({ thread }) => {
        if (!active || unavailableRef.current) return;
        setConnected(true);
        // Company broadcasts carry no personal read state or display proof.
        const generation = dataGeneration.current;
        void fetchThread(thread.id).then(response => {
          if (!response || !active || generation !== dataGeneration.current || unavailableRef.current || response.data.company_id !== companyId) return;
          noteLiveThread(response.data);
          setThreads(current => upsertThread(current, response.data));
          setSelectedThread(current => current?.id === thread.id ? response.data : current);
          void refreshUnreadCount();
        }).catch(() => setConnected(false));
      },
      onConnected: () => {
        if (!active) return;
        const wasUnavailable = unavailableRef.current;
        unavailableRef.current = false;
        setUnavailable(false);
        setConnected(true);
        if (wasUnavailable) void loadThreads();
      },
      onError: () => { if (active) setConnected(false); },
      onUnavailable: () => {
        if (!active) return;
        unavailableRef.current = true;
        dataGeneration.current += 1;
        setUnavailable(true);
        setConnected(false);
        setLoading(false);
        setThreads([]);
        setThreadsMeta(null);
        resetThreadCounts([]);
        setLoadMoreError(null);
        setSelectedId(null);
        setSelectedThread(null);
        setMobileConversationOpen(false);
      },
    }).then((cleanup) => {
      if (active) unsubscribe = cleanup;
      else cleanup();
    }).catch(() => { if (active) setConnected(false); });

    return () => {
      active = false;
      unsubscribe?.();
    };
  }, [companyId, connectionAttempt, loadThreads, noteLiveThread, resetThreadCounts, fetchThread, refreshUnreadCount]);

  useEffect(() => {
    if (!selectedId) {
      setSelectedThread(null);
      return;
    }

    let active = true;
    fetchThread(selectedId)
      .then((response) => {
        if (!response || !active || unavailableRef.current || response.data.company_id !== companyId) return;
        setSelectedThread(response.data);
        setThreads((current) => upsertThread(current, response.data));
      })
      .catch((err) => { if (active && !unavailableRef.current) { setMobileConversationOpen(false); setError(err instanceof Error ? err.message : 'Failed to load conversation'); } });

    return () => {
      active = false;
    };
  }, [fetchThread, companyId, selectedId, setError]);

  // After a send, show the newest message without animated scrolling.
  useEffect(() => {
    if (!scrollToEnd.current) return;
    scrollToEnd.current = false;
    const node = messagesContainer.current;
    if (node) node.scrollTop = node.scrollHeight;
  }, [selectedThread, messagesContainer]);

  // A changed archive marker in the documents list follows an archive or
  // unarchive, so re-read the open conversation. Its own markers stay
  // authoritative over list data that has not changed.
  const documentArchiveSignature = useMemo(
    () => documents.map(document => `${document.id}:${document.archived_at ?? ''}`).join(','),
    [documents]
  );
  const seenArchiveSignature = useRef(documentArchiveSignature);
  useEffect(() => {
    if (seenArchiveSignature.current === documentArchiveSignature) return;
    seenArchiveSignature.current = documentArchiveSignature;
    if (!selectedId || unavailableRef.current) return;

    let active = true;
    api.get(selectedId)
      .then((response) => {
        if (!active || unavailableRef.current || response.data.company_id !== companyId) return;
        setSelectedThread(current => (current?.id === response.data.id ? response.data : current));
      })
      .catch(() => undefined);

    return () => {
      active = false;
    };
  }, [api, companyId, documentArchiveSignature, selectedId]);

  const refreshSelected = useCallback(async (id: number): Promise<void> => {
    const generation = dataGeneration.current;
    const response = await fetchThread(id);
    if (!response || generation !== dataGeneration.current || unavailableRef.current || response.data.company_id !== companyId) return;
    scrollToEnd.current = true;
    setSelectedThread(current => (current?.id === id ? response.data : current));
    setThreads((current) => upsertThread(current, response.data));
  }, [companyId, fetchThread]);

  const createThread = async ({ subject, body, document_ids, idempotency_key }: ComposerSend): Promise<void> => {
    if (unavailableRef.current) throw new Error('This client is unavailable.');
    if (!subject && !body && !document_ids.length) throw new Error('Add a subject or message to start a conversation.');
    const generation = dataGeneration.current;
    const response = await api.create({ subject: subject || 'Portal message', body: body || undefined, document_ids: document_ids.length ? document_ids : undefined, idempotency_key });
    if (generation !== dataGeneration.current || unavailableRef.current || response.data.company_id !== companyId) return;
    noteLiveThread(response.data);
    setThreads((current) => upsertThread(current, response.data));
    setSelectedThread(response.data);
    setNewFormOpen(false);
    openConversation(response.data.id);
  };

  const sendReply = async (thread: ClientPortalThread, { body, document_ids, idempotency_key }: ComposerSend): Promise<void> => {
    if (unavailableRef.current) throw new Error('This client is unavailable.');
    const generation = dataGeneration.current;
    await api.createMessage(thread.id, { body: body || undefined, document_ids: document_ids.length ? document_ids : undefined, idempotency_key });
    if (generation !== dataGeneration.current || unavailableRef.current) return;
    setError(null);
    window.dispatchEvent(new Event('portal-work-changed'));
    try {
      await refreshSelected(thread.id);
    } catch {
      setError('Message sent. The conversation could not refresh. Reload to see it.');
    }
  };

  const updateStatus = async (status: 'open' | 'resolved') => {
    if (unavailableRef.current || !selectedThread) return;

    const generation = dataGeneration.current;
    try {
      setError(null);
      const response = await api.update(selectedThread.id, { status });
      if (generation !== dataGeneration.current || unavailableRef.current || response.data.company_id !== companyId) return;
      setSelectedThread(response.data);
      setThreads((current) => upsertThread(current, response.data));
    } catch (err) {
      if (generation === dataGeneration.current && !unavailableRef.current) setError(err instanceof Error ? err.message : 'Failed to update conversation status');
    }
  };

  const refreshAccess = async () => {
    setRefreshingAccess(true);
    try {
      await refreshCompanies();
      setError(null);
      setConnectionAttempt(attempt => attempt + 1);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to refresh client access');
    } finally {
      setRefreshingAccess(false);
    }
  };

  const changeFilter = (value: string): void => {
    const next = new URLSearchParams(searchParams);
    if (value) next.set('conversations', value); else next.delete('conversations');
    setSearchParams(next, { replace: true });
  };

  // Library copies win for archive state, except that the conversation's own
  // archived marker is authoritative.
  const libraryById = useMemo(() => new Map(documents.map(document => [document.id, document])), [documents]);
  const bubbleDocuments = (message: ClientPortalMessage): ClientDocument[] => messageDocuments(message)
    .map(document => (document.archived_at ? document : libraryById.get(document.id) || document));

  const staff = audience === 'staff';
  const openRequests = selectedThread?.open_file_request_count ?? 0;

  return (
    <div ref={panelRef} className="scroll-mt-40"><Card>
      <CardHeader>
        {initialThreadId && <InboxReturnLink />}
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <CardTitle>Portal Messages <span className="text-sm font-normal text-neutral-500">{unreadCount === null ? null : `${unreadCount} unread`}</span></CardTitle>
            <CardDescription>{description}</CardDescription>
          </div>
          <div className="flex items-center gap-2 rounded-full bg-neutral-100 px-3 py-1 text-xs text-neutral-600">
            <Wifi className="h-3.5 w-3.5" aria-hidden />
            {connected ? 'Live updates on' : unavailable ? 'Live updates unavailable' : 'Live updates pending'}
          </div>
        </div>
      </CardHeader>
      <CardContent>
        {error && <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />}

        {unavailable && <div className="mb-4 space-y-2" role="status">
          <p className="text-sm text-neutral-700">This client's connection is unavailable. Refresh access before sending messages.</p>
          <Button type="button" variant="outline" disabled={refreshingAccess} onClick={() => void refreshAccess()}>
            {refreshingAccess ? 'Refreshing access…' : 'Refresh access'}
          </Button>
        </div>}
        <div className="grid gap-5 lg:grid-cols-[320px_minmax(0,1fr)]">
          <div className={`${mobileConversationOpen ? 'hidden lg:block' : 'block'} min-w-0 space-y-4`}>
            <div className="flex flex-wrap gap-2 lg:hidden">
              <Button type="button" variant={newFormOpen ? 'outline' : 'primary'} aria-expanded={newFormOpen} aria-controls="portal-new-conversation" onClick={() => setNewFormOpen(open => !open)}>
                <Plus className="mr-2 h-4 w-4" aria-hidden />{newFormOpen ? 'Hide new conversation' : 'New conversation'}
              </Button>
              {staff && <Button type="button" variant="outline" disabled={unavailable} onClick={() => setRequestOpen({ threadId: null, subject: null })}><FileQuestion className="mr-2 h-4 w-4" aria-hidden />Request a file</Button>}
            </div>
            <div id="portal-new-conversation" className={`${newFormOpen ? 'block' : 'hidden lg:block'} rounded-lg border border-neutral-200 bg-neutral-50 p-4`}>
              <MessageComposer draftKey={`${companyId}:new`} documentsApi={documentsApi} withSubject label={`Message ${audienceLabel}`}
                placeholder={`Message ${audienceLabel}`} submitLabel="Start Conversation" disabled={unavailable} onSend={createThread}
                actions={staff ? <Button type="button" variant="ghost" className="hidden lg:inline-flex" disabled={unavailable} onClick={() => setRequestOpen({ threadId: null, subject: null })}><FileQuestion className="mr-2 h-4 w-4" aria-hidden />Request a file</Button> : undefined} />
            </div>

            <label className="block text-xs font-medium text-neutral-600">Show
              <Select value={filter} onChange={event => changeFilter(event.target.value)}>
                {FILTERS.map(option => <option key={option.value} value={option.value}>{option.label}</option>)}
              </Select>
            </label>
            <div className="overflow-hidden rounded-lg border border-neutral-200">
              {loading ? (
                <div className="p-4 text-sm text-neutral-500" role="status">Loading conversations...</div>
              ) : threads.length === 0 ? (
                <div className="p-4 text-sm text-neutral-500">{filter ? 'No conversations match this filter.' : 'No portal conversations yet.'}</div>
              ) : (
                threads.map((thread) => (
                  <button
                    key={thread.id}
                    ref={node => { if (node) rowRefs.current.set(thread.id, node); else rowRefs.current.delete(thread.id); }}
                    type="button"
                    aria-current={selectedId === thread.id ? 'true' : undefined}
                    onClick={() => openConversation(thread.id)}
                    className={`block min-h-11 w-full border-b border-neutral-100 px-4 py-3 text-left last:border-b-0 hover:bg-neutral-50 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-primary-500 ${
                      selectedId === thread.id ? 'bg-primary-50' : 'bg-white'
                    }`}
                  >
                    <div className="flex items-center justify-between gap-3">
                      <p className="min-w-0 break-words text-sm font-semibold text-neutral-900 [overflow-wrap:anywhere]">{thread.subject}</p>
                      {thread.unread && <span aria-label="Unread conversation" className="h-2 w-2 shrink-0 rounded-full bg-primary-600" />}
                    </div>
                    <p className="mt-1 truncate text-xs text-neutral-500">{preview(thread.latest_message)}</p>
                    <p className="mt-1 text-xs text-neutral-500">
                      {formatDateTime(thread.last_message_at || thread.created_at)}
                      {thread.status === 'resolved' ? ' · Resolved' : ''}
                      {thread.open_file_request_count ? ` · ${thread.open_file_request_count === 1 ? '1 file requested' : `${thread.open_file_request_count} files requested`}` : ''}
                    </p>
                  </button>
                ))
              )}
              {!loading && (
                <LoadMoreFooter
                  shown={threads.length}
                  total={threadsMeta ? threadsMeta.total_count + liveNewThreadIds.length : threads.length}
                  noun="conversations"
                  hasMore={hasMorePages(threadsMeta)}
                  loading={loadingMore}
                  error={loadMoreError}
                  onLoadMore={() => void loadMoreThreads()}
                />
              )}
            </div>
          </div>

          <div className={`${mobileConversationOpen ? 'block' : 'hidden lg:block'} min-w-0 rounded-lg border border-neutral-200`}>
            {selectedThread ? (
              <>
                <div className="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-200 px-4 py-3">
                  <div className="flex min-w-0 items-start gap-2">
                    <button type="button" className="-ml-1 inline-flex min-h-11 items-center justify-center gap-1 rounded-lg px-1 text-sm font-medium text-neutral-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 lg:hidden" onClick={closeConversation} aria-label="Back to conversations"><ArrowLeft className="h-5 w-5" aria-hidden /><span aria-hidden>Back</span></button>
                    <div className="min-w-0 break-words">
                    <p ref={conversationHeading} tabIndex={-1} className="font-semibold text-neutral-900 focus:outline-none [overflow-wrap:anywhere]">{selectedThread.subject}</p>
                    <p className="text-xs text-neutral-500">
                      {selectedThread.status === 'resolved' ? `Resolved ${formatDateTime(selectedThread.resolved_at)}. A new message reopens it.` : 'Open conversation'}
                      {openRequests ? ` · ${openRequests === 1 ? '1 file requested' : `${openRequests} files requested`}` : ''}
                    </p>
                    </div>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    {staff && (
                      <Button type="button" variant="outline" size="sm" disabled={unavailable} onClick={() => setRequestOpen({ threadId: selectedThread.id, subject: selectedThread.subject })}>
                        <FileQuestion className="mr-2 h-4 w-4" aria-hidden />Request a file
                      </Button>
                    )}
                    {canResolve && (
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        disabled={unavailable}
                        onClick={() => void updateStatus(selectedThread.status === 'resolved' ? 'open' : 'resolved')}
                      >
                        <CheckCircle2 className="mr-2 h-4 w-4" aria-hidden />
                        {selectedThread.status === 'resolved' ? 'Reopen' : 'Resolve'}
                      </Button>
                    )}
                  </div>
                </div>

                <div ref={messagesContainer} className="max-h-[min(520px,60dvh)] space-y-3 overflow-y-auto bg-neutral-50/60 p-4">
                  {(selectedThread.messages || []).map((message) => (
                    <MessageBubble key={message.id} message={message} documents={bubbleDocuments(message)} documentsApi={documentsApi}
                      audience={audience} companyId={companyId} onChanged={() => refreshSelected(selectedThread.id)} />
                  ))}
                </div>

                <ResourceActivity key={selectedThread.id} id={selectedThread.id} api={api} revision={selectedThread.updated_at} />
                <div className="border-t border-neutral-200 p-4">
                  <MessageComposer key={selectedThread.id} draftKey={`${companyId}:thread:${selectedThread.id}`} documentsApi={documentsApi}
                    label={`Reply ${audienceLabel}`} placeholder={`Reply ${audienceLabel}`} submitLabel="Send" disabled={unavailable}
                    onSend={payload => sendReply(selectedThread, payload)} />
                </div>
              </>
            ) : (
              <div className="p-10 text-center text-sm text-neutral-500">
                <MessageSquare className="mx-auto mb-2 h-5 w-5" aria-hidden />Select or start a conversation.
              </div>
            )}
          </div>
        </div>
      </CardContent>
      {staff && requestOpen && (
        <RequestFileDialog open onOpenChange={open => { if (!open) setRequestOpen(null); }} threadId={requestOpen.threadId} threadSubject={requestOpen.subject}
          onCreated={thread => {
            noteLiveThread(thread);
            setThreads(current => upsertThread(current, thread));
            setSelectedThread(thread);
            scrollToEnd.current = true;
            openConversation(thread.id);
          }} />
      )}
    </Card></div>
  );
}

function MessageBubble({ message, documents, documentsApi, audience, companyId, onChanged }: {
  message: ClientPortalMessage;
  documents: ClientDocument[];
  documentsApi: PortalDocumentsApi;
  audience: 'client' | 'staff';
  companyId: number | null;
  onChanged: () => Promise<void>;
}) {
  const fromStaff = message.author_audience === 'staff';
  const step = stepLabel(message);
  return (
    <article data-message-id={message.id} className={`rounded-lg border px-4 py-3 shadow-sm ${fromStaff ? 'border-neutral-200 bg-white' : 'border-primary-100 bg-white'}`}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-semibold text-neutral-900">
          {message.author_name || 'Unknown user'}
          {fromStaff && audience === 'client' ? <span className="font-normal text-neutral-600"> · Cornerstone</span> : null}
        </p>
        <p className="text-xs text-neutral-500"><time dateTime={message.created_at}>{formatDateTime(message.created_at)}</time></p>
      </div>
      {step && <p className="mt-2 text-xs font-semibold text-neutral-700">{step}</p>}
      {message.body && <p className="mt-2 whitespace-pre-wrap break-words text-sm text-neutral-700">{message.body}</p>}
      <MessageAttachments documents={documents} api={documentsApi} />
      {message.kind === 'file_request' && message.file_request && (
        <FileRequestCard request={message.file_request} audience={audience} companyId={companyId} documentsApi={documentsApi} onChanged={onChanged} />
      )}
    </article>
  );
}
