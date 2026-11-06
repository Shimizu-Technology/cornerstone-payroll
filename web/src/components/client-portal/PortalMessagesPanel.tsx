import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowLeft, CheckCircle2, MessageSquare, Paperclip, Send, Wifi } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { subscribeToClientPortalThreads } from '@/services/clientPortalCable';
import type { ClientDocument, ClientPortalMessage, ClientPortalThread } from '@/services/api';

type PortalThreadsApi = {
  list: (params?: { status?: string }) => Promise<{ data: ClientPortalThread[] }>;
  get: (id: number) => Promise<{ data: ClientPortalThread }>;
  create: (data: { subject: string; body?: string; document_id?: number }) => Promise<{ data: ClientPortalThread }>;
  update: (id: number, data: { subject?: string; status?: 'open' | 'resolved' }) => Promise<{ data: ClientPortalThread }>;
  createMessage: (threadId: number, data: { body?: string; document_id?: number }) => Promise<{ data: ClientPortalMessage }>;
};

type Props = {
  api: PortalThreadsApi;
  documents: ClientDocument[];
  audienceLabel: string;
  description: string;
  canResolve?: boolean;
};

function formatDateTime(value?: string | null) {
  if (!value) return 'No messages yet';
  return new Date(value).toLocaleString();
}

function upsertThread(threads: ClientPortalThread[], next: ClientPortalThread) {
  const exists = threads.some((thread) => thread.id === next.id);
  const merged = exists ? threads.map((thread) => (thread.id === next.id ? next : thread)) : [next, ...threads];
  return merged.sort((a, b) => {
    const aTime = new Date(a.last_message_at || a.created_at).getTime();
    const bTime = new Date(b.last_message_at || b.created_at).getTime();
    return bTime - aTime;
  });
}

export function PortalMessagesPanel(props: Props) {
  const { activeCompanyId, refreshCompanies } = useCompany();
  return <PortalMessagesContent key={activeCompanyId} {...props} companyId={activeCompanyId} refreshCompanies={refreshCompanies} />;
}

function PortalMessagesContent({ api, documents, audienceLabel, description, canResolve = false, companyId, refreshCompanies }: Props & {
  companyId: number | null;
  refreshCompanies: () => Promise<void>;
}) {
  const { user } = useAuth();
  const [threads, setThreads] = useState<ClientPortalThread[]>([]);
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const [selectedThread, setSelectedThread] = useState<ClientPortalThread | null>(null);
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [connected, setConnected] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [refreshingAccess, setRefreshingAccess] = useState(false);
  const [connectionAttempt, setConnectionAttempt] = useState(0);
  const unavailableRef = useRef(false);
  const dataGeneration = useRef(0);
  const [newThread, setNewThread] = useState({ subject: '', body: '', document_id: '' });
  const [reply, setReply] = useState({ body: '', document_id: '' });
  const [mobileConversationOpen, setMobileConversationOpen] = useState(false);

  const documentOptions = useMemo(
    () => documents.map((document) => ({ value: String(document.id), label: `${document.title} (${document.file_name})` })),
    [documents]
  );

  const loadThreads = useCallback(async () => {
    if (!companyId || unavailableRef.current) return;
    const generation = dataGeneration.current;
    try {
      setLoading(true);
      setError(null);
      const response = await api.list();
      if (generation !== dataGeneration.current || unavailableRef.current) return;
      setThreads(response.data.filter(thread => thread.company_id === companyId));
      setSelectedId((current) => current || response.data.find(thread => thread.company_id === companyId)?.id || null);
    } catch (err) {
      if (generation === dataGeneration.current && !unavailableRef.current) setError(err instanceof Error ? err.message : 'Failed to load messages');
    } finally {
      if (generation === dataGeneration.current && !unavailableRef.current) setLoading(false);
    }
  }, [api, companyId, setError]);

  useEffect(() => {
    void loadThreads();
  }, [loadThreads, connectionAttempt]);

  useEffect(() => {
    if (!companyId) return;
    let active = true;
    let unsubscribe: (() => void) | undefined;
    subscribeToClientPortalThreads(companyId, {
      onThread: ({ thread }) => {
        if (!active || unavailableRef.current) return;
        setConnected(true);
        setSelectedId((currentSelectedId) => {
          const latestAuthorId = thread.latest_message?.author_id;
          const unread = currentSelectedId === thread.id || latestAuthorId === user?.id ? false : true;
          const threadWithUnread = { ...thread, unread };
          setThreads((current) => upsertThread(current, threadWithUnread));
          setSelectedThread((current) => (current?.id === thread.id ? threadWithUnread : current));
          return currentSelectedId;
        });
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
  }, [companyId, connectionAttempt, loadThreads, user?.id]);

  useEffect(() => {
    if (!selectedId) {
      setSelectedThread(null);
      return;
    }

    let active = true;
    api.get(selectedId)
      .then((response) => {
        if (!active || unavailableRef.current || response.data.company_id !== companyId) return;
        setSelectedThread(response.data);
        setThreads((current) => upsertThread(current, response.data));
      })
      .catch((err) => { if (active && !unavailableRef.current) setError(err instanceof Error ? err.message : 'Failed to load conversation'); });

    return () => {
      active = false;
    };
  }, [api, companyId, selectedId, setError]);

  const createThread = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (unavailableRef.current) return;
    if (!newThread.subject.trim() && !newThread.body.trim()) {
      setError('Add a subject or message to start a conversation');
      return;
    }

    const generation = dataGeneration.current;
    try {
      setSending(true);
      setError(null);
      const response = await api.create({
        subject: newThread.subject.trim() || 'Portal message',
        body: newThread.body.trim() || undefined,
        document_id: newThread.document_id ? Number(newThread.document_id) : undefined,
      });
      if (generation !== dataGeneration.current || unavailableRef.current || response.data.company_id !== companyId) return;
      setNewThread({ subject: '', body: '', document_id: '' });
      setThreads((current) => upsertThread(current, response.data));
      setSelectedId(response.data.id);
      setSelectedThread(response.data);
      setMobileConversationOpen(true);
    } catch (err) {
      if (generation === dataGeneration.current && !unavailableRef.current) setError(err instanceof Error ? err.message : 'Failed to start conversation');
    } finally {
      setSending(false);
    }
  };

  const sendReply = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (unavailableRef.current || !selectedThread) return;
    if (!reply.body.trim() && !reply.document_id) {
      setError('Add a message or attach a document');
      return;
    }

    const generation = dataGeneration.current;
    try {
      setSending(true);
      setError(null);
      await api.createMessage(selectedThread.id, {
        body: reply.body.trim() || undefined,
        document_id: reply.document_id ? Number(reply.document_id) : undefined,
      });
      if (generation !== dataGeneration.current || unavailableRef.current) return;
      const response = await api.get(selectedThread.id);
      if (generation !== dataGeneration.current || unavailableRef.current || response.data.company_id !== companyId) return;
      setReply({ body: '', document_id: '' });
      setSelectedThread(response.data);
      setThreads((current) => upsertThread(current, response.data));
    } catch (err) {
      if (generation === dataGeneration.current && !unavailableRef.current) setError(err instanceof Error ? err.message : 'Failed to send message');
    } finally {
      setSending(false);
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

  return (
    <Card>
      <CardHeader>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <CardTitle>Portal Messages</CardTitle>
            <CardDescription>{description}</CardDescription>
          </div>
          <div className="flex items-center gap-2 rounded-full bg-neutral-100 px-3 py-1 text-xs text-neutral-600">
            <Wifi className="h-3.5 w-3.5" />
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
            <form onSubmit={createThread} className="space-y-3 rounded-lg border border-neutral-200 bg-neutral-50 p-4">
              <Input
                value={newThread.subject}
                onChange={(event) => setNewThread((current) => ({ ...current, subject: event.target.value }))}
                placeholder="Subject"
              />
              <Textarea
                value={newThread.body}
                onChange={(event) => setNewThread((current) => ({ ...current, body: event.target.value }))}
                rows={3}
                placeholder={`Message ${audienceLabel}`}
              />
              <Select
                value={newThread.document_id}
                onChange={(event) => setNewThread((current) => ({ ...current, document_id: event.target.value }))}
              >
                <option value="">Attach an existing document</option>
                {documentOptions.map((document) => (
                  <option key={document.value} value={document.value}>{document.label}</option>
                ))}
              </Select>
              <Button type="submit" disabled={sending || unavailable} className="w-full">
                <MessageSquare className="mr-2 h-4 w-4" />
                Start Conversation
              </Button>
            </form>

            <div className="overflow-hidden rounded-lg border border-neutral-200">
              {loading ? (
                <div className="p-4 text-sm text-neutral-500">Loading conversations...</div>
              ) : threads.length === 0 ? (
                <div className="p-4 text-sm text-neutral-500">No portal conversations yet.</div>
              ) : (
                threads.map((thread) => (
                  <button
                    key={thread.id}
                    type="button"
                    onClick={() => { setSelectedId(thread.id); setMobileConversationOpen(true); }}
                    className={`block w-full border-b border-neutral-100 px-4 py-3 text-left last:border-b-0 hover:bg-neutral-50 ${
                      selectedId === thread.id ? 'bg-primary-50' : 'bg-white'
                    }`}
                  >
                    <div className="flex items-center justify-between gap-3">
                      <p className="truncate text-sm font-semibold text-neutral-900">{thread.subject}</p>
                      {thread.unread && <span className="h-2 w-2 shrink-0 rounded-full bg-primary-600" />}
                    </div>
                    <p className="mt-1 truncate text-xs text-neutral-500">
                      {thread.latest_message?.body || thread.latest_message?.document?.title || 'No message body'}
                    </p>
                    <p className="mt-1 text-xs text-neutral-400">{formatDateTime(thread.last_message_at || thread.created_at)}</p>
                  </button>
                ))
              )}
            </div>
          </div>

          <div className={`${mobileConversationOpen ? 'block' : 'hidden lg:block'} min-w-0 rounded-lg border border-neutral-200`}>
            {selectedThread ? (
              <>
                <div className="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-200 px-4 py-3">
                  <div className="flex min-w-0 items-start gap-2">
                    <button type="button" className="-ml-1 inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-neutral-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 lg:hidden" onClick={() => setMobileConversationOpen(false)} aria-label="Back to conversations"><ArrowLeft className="h-5 w-5" /></button>
                    <div className="min-w-0 break-words">
                    <p className="font-semibold text-neutral-900">{selectedThread.subject}</p>
                    <p className="text-xs text-neutral-500">
                      {selectedThread.status === 'resolved' ? `Resolved ${formatDateTime(selectedThread.resolved_at)}` : 'Open conversation'}
                    </p>
                    </div>
                  </div>
                  {canResolve && (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      disabled={unavailable}
                      onClick={() => void updateStatus(selectedThread.status === 'resolved' ? 'open' : 'resolved')}
                    >
                      <CheckCircle2 className="mr-2 h-4 w-4" />
                      {selectedThread.status === 'resolved' ? 'Reopen' : 'Resolve'}
                    </Button>
                  )}
                </div>

                <div className="max-h-[520px] space-y-3 overflow-y-auto bg-neutral-50/60 p-4">
                  {(selectedThread.messages || []).map((message) => (
                    <MessageBubble key={message.id} message={message} />
                  ))}
                </div>

                <form onSubmit={sendReply} className="space-y-3 border-t border-neutral-200 p-4">
                  <Textarea
                    value={reply.body}
                    onChange={(event) => setReply((current) => ({ ...current, body: event.target.value }))}
                    rows={3}
                    placeholder={`Reply ${audienceLabel}`}
                  />
                  <div className="grid gap-3 md:grid-cols-[minmax(0,1fr)_auto]">
                    <Select value={reply.document_id} onChange={(event) => setReply((current) => ({ ...current, document_id: event.target.value }))}>
                      <option value="">Attach an existing document</option>
                      {documentOptions.map((document) => (
                        <option key={document.value} value={document.value}>{document.label}</option>
                      ))}
                    </Select>
                    <Button type="submit" disabled={sending || unavailable}>
                      <Send className="mr-2 h-4 w-4" />
                      Send
                    </Button>
                  </div>
                </form>
              </>
            ) : (
              <div className="p-10 text-center text-sm text-neutral-500">Select or start a conversation.</div>
            )}
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

function MessageBubble({ message }: { message: ClientPortalMessage }) {
  return (
    <div className="rounded-lg border border-neutral-200 bg-white px-4 py-3 shadow-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-semibold text-neutral-900">{message.author_name || 'Unknown user'}</p>
        <p className="text-xs text-neutral-500">{formatDateTime(message.created_at)}</p>
      </div>
      {message.body && <p className="mt-2 whitespace-pre-wrap text-sm text-neutral-700">{message.body}</p>}
      {message.document && (
        <div className="mt-3 flex items-center gap-2 rounded-md border border-primary-100 bg-primary-50 px-3 py-2 text-sm text-primary-800">
          <Paperclip className="h-4 w-4 shrink-0" />
          <span className="truncate">{message.document.title}</span>
        </div>
      )}
    </div>
  );
}
