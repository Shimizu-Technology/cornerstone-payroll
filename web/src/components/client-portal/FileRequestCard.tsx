import { useRef, useState, type ReactElement } from 'react';
import { CheckCircle2, FileQuestion, RotateCcw, Upload, XCircle } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { LabeledTextarea } from '@/components/payroll-submissions/LabeledTextarea';
import { formatDate, formatGuam } from '@/lib/payrollSubmissionFormat';
import { adminPortalFileRequestsApi, clientPortalFileRequestsApi, type PortalFileRequest } from '@/services/api';
import { MessageComposer } from './MessageComposer';
import { CATEGORY_LABELS, type PortalDocumentsApi } from './portalFiles';

function badgeVariant(status: PortalFileRequest['status']): 'warning' | 'info' | 'success' | 'default' {
  if (status === 'requested') return 'warning';
  if (status === 'responded') return 'info';
  if (status === 'accepted') return 'success';
  return 'default';
}

// The request itself, with its current state for both sides. The client
// answers by attaching the file here; staff accept the exact file they
// reviewed, ask again with a note, or withdraw the request.
export function FileRequestCard({ request, audience, draftScope, documentsApi, onChanged }: {
  request: PortalFileRequest;
  audience: 'client' | 'staff';
  draftScope: string;
  documentsApi: PortalDocumentsApi;
  onChanged: () => void | Promise<void>;
}): ReactElement {
  const [answering, setAnswering] = useState(false);
  const [askingAgain, setAskingAgain] = useState(false);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const keys = useRef(new Map<string, { identity: string; key: string }>());
  const outstanding = request.status === 'requested' || request.status === 'responded';

  const retryKey = (action: string, identity: string): string => {
    const saved = keys.current.get(action);
    if (saved?.identity === identity) return saved.key;
    const key = crypto.randomUUID();
    keys.current.set(action, { identity, key });
    return key;
  };

  const staffStep = async (action: 'accept' | 'ask_again' | 'withdraw'): Promise<void> => {
    const body = note.trim();
    if (action === 'ask_again' && !body) { setError('Say what is still needed.'); return; }
    const responseId = request.last_response_message_id ?? 0;
    setBusy(true); setError(null);
    try {
      const idempotency_key = retryKey(action, JSON.stringify([request.id, responseId, body]));
      if (action === 'accept') await adminPortalFileRequestsApi.accept(request.id, { response_message_id: responseId, body: body || undefined, idempotency_key });
      else if (action === 'ask_again') await adminPortalFileRequestsApi.askAgain(request.id, { response_message_id: responseId, body, idempotency_key });
      else await adminPortalFileRequestsApi.withdraw(request.id, { body: body || undefined, idempotency_key });
      keys.current.delete(action);
      setNote(''); setAskingAgain(false);
      window.dispatchEvent(new Event('portal-work-changed'));
      await onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'That did not save. Try again.');
      // A newer file or someone else's decision: show the current state.
      if (err && typeof err === 'object' && 'status' in err && err.status === 409) await onChanged();
    } finally { setBusy(false); }
  };

  const details = [
    CATEGORY_LABELS[request.category] ?? request.category,
    request.employee_name ? `For ${request.employee_name}` : null,
    request.payroll_submission_period_label ? `Pay period ${request.payroll_submission_period_label}` : null,
    request.due_on ? `Needed by ${formatDate(request.due_on)}` : null,
  ].filter(Boolean);

  return (
    <section aria-label={`File request: ${request.title}`} className="mt-3 rounded-lg border border-warning-200 bg-warning-50/60 p-3 text-sm">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <p className="flex min-w-0 items-start gap-2 font-semibold text-neutral-950">
          <FileQuestion className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
          <span className="min-w-0 break-words [overflow-wrap:anywhere]">File requested: {request.title}</span>
        </p>
        <Badge variant={badgeVariant(request.status)} wrap>{request.status_label}</Badge>
      </div>
      {details.length > 0 && <p className="mt-1 break-words text-xs text-neutral-700">{details.join(' · ')}</p>}
      {request.responded_at && <p className="mt-1 text-xs text-neutral-700">Last file sent by {request.responded_by_name || 'the client'} on {formatGuam(request.responded_at)}</p>}
      {request.resolved_at && <p className="mt-1 text-xs text-neutral-700">{request.status === 'accepted' ? 'Accepted' : 'Closed'} by {request.resolved_by_name || 'Cornerstone'} on {formatGuam(request.resolved_at)}</p>}
      {error && <p role="alert" className="mt-2 text-sm text-danger-700">{error}</p>}

      {audience === 'client' && outstanding && (
        answering ? (
          <div className="mt-3 rounded-lg border border-neutral-200 bg-white p-3">
            <MessageComposer draftKey={`${draftScope}:request:${request.id}`} documentsApi={documentsApi} label="Note for Cornerstone (optional)"
              requireAttachment rows={2} submitLabel="Send requested file"
              uploadFields={{ category: request.category, ...(request.employee_id ? { employee_id: String(request.employee_id) } : {}) }}
              onSend={async payload => {
                await clientPortalFileRequestsApi.respond(request.id, { body: payload.body || undefined, document_ids: payload.document_ids, idempotency_key: payload.idempotency_key });
                setAnswering(false);
                window.dispatchEvent(new Event('portal-work-changed'));
                await onChanged();
              }}
              actions={<Button type="button" variant="ghost" onClick={() => setAnswering(false)}>Cancel</Button>} />
          </div>
        ) : (
          <Button type="button" size="sm" className="mt-3" onClick={() => setAnswering(true)}>
            <Upload className="mr-2 h-4 w-4" aria-hidden />{request.status === 'responded' ? 'Send a different file' : 'Upload requested file'}
          </Button>
        )
      )}

      {audience === 'staff' && outstanding && (
        <div className="mt-3 space-y-2">
          {(askingAgain || request.status === 'responded') && (
            <LabeledTextarea label={askingAgain ? 'What is still needed?' : 'Note to the client (optional)'} rows={2} value={note} maxLength={5000} onChange={event => setNote(event.target.value)} />
          )}
          <div className="flex flex-wrap gap-2">
            {request.status === 'responded' && !askingAgain && (
              <>
                <Button type="button" size="sm" disabled={busy} onClick={() => void staffStep('accept')}><CheckCircle2 className="mr-2 h-4 w-4" aria-hidden />Accept file</Button>
                <Button type="button" size="sm" variant="outline" disabled={busy} onClick={() => setAskingAgain(true)}><RotateCcw className="mr-2 h-4 w-4" aria-hidden />Ask again</Button>
              </>
            )}
            {askingAgain && (
              <>
                <Button type="button" size="sm" disabled={busy} onClick={() => void staffStep('ask_again')}>Send request again</Button>
                <Button type="button" size="sm" variant="ghost" disabled={busy} onClick={() => { setAskingAgain(false); setError(null); }}>Cancel</Button>
              </>
            )}
            {!askingAgain && (
              <Button type="button" size="sm" variant="ghost" disabled={busy} onClick={() => { if (window.confirm(`Withdraw the request for “${request.title}”? The client will see it is no longer needed.`)) void staffStep('withdraw'); }}>
                <XCircle className="mr-2 h-4 w-4" aria-hidden />Withdraw
              </Button>
            )}
          </div>
        </div>
      )}
    </section>
  );
}
