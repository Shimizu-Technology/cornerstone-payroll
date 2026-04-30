import { useCallback, useEffect, useMemo, useState } from 'react';
import { CheckCircle2, MessageSquare, Paperclip, Send, Wifi } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { useAuth } from '@/contexts/AuthContext';
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

export function PortalMessagesPanel({ api, documents, audienceLabel, description, canResolve = false }: Props) {
  const { user } = useAuth();
  const [threads, setThreads] = useState<ClientPortalThread[]>([]);
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const [selectedThread, setSelectedThread] = useState<ClientPortalThread | null>(null);
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [connected, setConnected] = useState(false);
  const [newThread, setNewThread] = useState({ subject: '', body: '', document_id: '' });
  const [reply, setReply] = useState({ body: '', document_id: '' });

  const documentOptions = useMemo(
    () => documents.map((document) => ({ value: String(document.id), label: `${document.title} (${document.file_name})` })),
    [documents]
  );

  const loadThreads = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await api.list();
      setThreads(response.data);
      setSelectedId((current) => current || response.data[0]?.id || null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load messages');
    } finally {
      setLoading(false);
    }
  }, [api]);

  useEffect(() => {
    void loadThreads();
  }, [loadThreads]);

  useEffect(() => {
    let unsubscribe: (() => void) | undefined;
    subscribeToClientPortalThreads({
      onThread: ({ thread }) => {
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
      onError: () => setConnected(false),
    }).then((cleanup) => {
      unsubscribe = cleanup;
      setConnected(true);
    }).catch(() => setConnected(false));

    return () => {
      unsubscribe?.();
    };
  }, [user?.id]);

  useEffect(() => {
    if (!selectedId) {
      setSelectedThread(null);
      return;
    }

    let active = true;
    api.get(selectedId)
      .then((response) => {
        if (!active) return;
        setSelectedThread(response.data);
        setThreads((current) => upsertThread(current, response.data));
      })
      .catch((err) => setError(err instanceof Error ? err.message : 'Failed to load conversation'));

    return () => {
      active = false;
    };
  }, [api, selectedId]);

  const createThread = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!newThread.subject.trim() && !newThread.body.trim()) {
      setError('Add a subject or message to start a conversation');
      return;
    }

    try {
      setSending(true);
      setError(null);
      const response = await api.create({
        subject: newThread.subject.trim() || 'Portal message',
        body: newThread.body.trim() || undefined,
        document_id: newThread.document_id ? Number(newThread.document_id) : undefined,
      });
      setNewThread({ subject: '', body: '', document_id: '' });
      setThreads((current) => upsertThread(current, response.data));
      setSelectedId(response.data.id);
      setSelectedThread(response.data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to start conversation');
    } finally {
      setSending(false);
    }
  };

  const sendReply = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!selectedThread) return;
    if (!reply.body.trim() && !reply.document_id) {
      setError('Add a message or attach a document');
      return;
    }

    try {
      setSending(true);
      setError(null);
      await api.createMessage(selectedThread.id, {
        body: reply.body.trim() || undefined,
        document_id: reply.document_id ? Number(reply.document_id) : undefined,
      });
      setReply({ body: '', document_id: '' });
      const response = await api.get(selectedThread.id);
      setSelectedThread(response.data);
      setThreads((current) => upsertThread(current, response.data));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to send message');
    } finally {
      setSending(false);
    }
  };

  const updateStatus = async (status: 'open' | 'resolved') => {
    if (!selectedThread) return;
    const response = await api.update(selectedThread.id, { status });
    setSelectedThread(response.data);
    setThreads((current) => upsertThread(current, response.data));
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
            {connected ? 'Live updates on' : 'Live updates pending'}
          </div>
        </div>
      </CardHeader>
      <CardContent>
        {error && <div className="mb-4 rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{error}</div>}

        <div className="grid gap-5 lg:grid-cols-[320px_minmax(0,1fr)]">
          <div className="space-y-4">
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
              <Button type="submit" disabled={sending} className="w-full">
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
                    onClick={() => setSelectedId(thread.id)}
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

          <div className="rounded-lg border border-neutral-200">
            {selectedThread ? (
              <>
                <div className="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-200 px-4 py-3">
                  <div>
                    <p className="font-semibold text-neutral-900">{selectedThread.subject}</p>
                    <p className="text-xs text-neutral-500">
                      {selectedThread.status === 'resolved' ? `Resolved ${formatDateTime(selectedThread.resolved_at)}` : 'Open conversation'}
                    </p>
                  </div>
                  {canResolve && (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
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
                    <Button type="submit" disabled={sending}>
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
