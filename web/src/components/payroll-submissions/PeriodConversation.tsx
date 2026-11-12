import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactElement } from 'react';
import { Button } from '@/components/ui/button';
import { LabeledTextarea } from '@/components/payroll-submissions/LabeledTextarea';
import { useDisplayedMessages } from '@/components/client-portal/useDisplayedMessages';
import type { ClientPortalThread } from '@/services/api';
import type { PayrollSubmissionsApi } from '@/services/payrollSubmissions';
import { formatGuam } from '@/lib/payrollSubmissionFormat';

// Questions and answers about this period. Reuses the portal conversation,
// so per-person read state and Activity History work as in Messages.
export function PeriodConversation({ api, periodRef, threadId, onThreadCreated }: {
  api: PayrollSubmissionsApi; periodRef: string; threadId: number | null; onThreadCreated: () => void;
}): ReactElement {
  const [thread, setThread] = useState<ClientPortalThread | null>(null);
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const retry = useRef<{ body: string; key: string } | null>(null);
  const load = useCallback(async (): Promise<void> => {
    if (!threadId) { setThread(null); return; }
    try { setThread((await api.threads.get(threadId)).data); } catch (err) { setError(err instanceof Error ? err.message : 'Could not load the conversation'); }
  }, [api, threadId]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    const refresh = () => { if (document.visibilityState === 'visible') void load(); };
    window.addEventListener('focus', refresh);
    window.addEventListener('portal-work-changed', refresh);
    return () => { window.removeEventListener('focus', refresh); window.removeEventListener('portal-work-changed', refresh); };
  }, [load]);
  const container = useDisplayedMessages(thread, true, api.threads.markRead);

  const send = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    const text = body.trim();
    if (!text) return;
    if (retry.current?.body !== text) retry.current = { body: text, key: crypto.randomUUID() };
    setBusy(true); setError(null);
    try {
      await api.message(periodRef, { body: text, idempotency_key: retry.current.key });
      retry.current = null;
      // Keep anything typed while the message was sending.
      setBody(currentBody => (currentBody.trim() === text ? '' : currentBody));
      if (!threadId) onThreadCreated(); else await load();
    } catch (err) { setError(err instanceof Error ? err.message : 'Your message was not sent. Try again.'); } finally { setBusy(false); }
  };

  return (
    <section aria-labelledby="period-conversation" className="rounded-xl border border-neutral-200 bg-white p-4">
      <h2 id="period-conversation" className="text-base font-semibold text-neutral-950">Questions about this period</h2>
      <p className="text-sm text-neutral-600">Messages here stay with this pay period.</p>
      <div ref={container} className="mt-3 space-y-3">
        {!thread?.messages?.length && <p className="text-sm text-neutral-600">No messages yet.</p>}
        {thread?.messages?.map(message => (
          <article key={message.id} data-message-id={message.id} className="rounded-lg bg-neutral-50 p-3">
            <p className="text-xs font-semibold text-neutral-700">{message.author_name || 'Former portal user'} · <time dateTime={message.created_at}>{formatGuam(message.created_at)}</time></p>
            <p className="mt-1 whitespace-pre-wrap break-words text-sm text-neutral-900">{message.body}</p>
          </article>
        ))}
      </div>
      <form onSubmit={send} className="mt-3 space-y-2">
        <LabeledTextarea label="Message" value={body} onChange={e => setBody(e.target.value)} rows={3} />
        {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
        <Button type="submit" disabled={busy || !body.trim()}>{busy ? 'Sending…' : 'Send message'}</Button>
      </form>
    </section>
  );
}
