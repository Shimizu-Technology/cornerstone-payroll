import { useCallback, useEffect, useId, useRef, useState, type FormEvent, type ReactElement, type ReactNode } from 'react';
import { FolderOpen, Paperclip, Send, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { LabeledTextarea } from '@/components/payroll-submissions/LabeledTextarea';
import type { ClientDocument } from '@/services/api';
import { FilePickerDialog } from './FilePickerDialog';
import { formatFileSize, type PortalDocumentsApi } from './portalFiles';
import { EMPTY_DRAFT, readDraft, writeDraft, type ComposerAttachment, type LocalAttachment, type MessageDraft } from './messageDrafts';

export const MAX_MESSAGE_FILES = 10;
const MAX_FILE_BYTES = 25 * 1024 * 1024;

export type ComposerSend = { subject: string; body: string; document_ids: number[]; idempotency_key: string };

type Props = {
  draftKey: string;
  documentsApi: PortalDocumentsApi;
  label: string;
  placeholder?: string;
  withSubject?: boolean;
  requireAttachment?: boolean;
  // Fields saved on files uploaded here, such as a requested file's type.
  uploadFields?: Record<string, string>;
  submitLabel: string;
  disabled?: boolean;
  rows?: number;
  actions?: ReactNode;
  onSend: (payload: ComposerSend) => Promise<void>;
};

function uploadMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return 'Upload failed. Check your connection and try again.';
}

// Text plus files from the device or the library, sent together. Device
// files upload first through the safe document upload, each with a retry key;
// the message is then sent with its own retry key. A failure at either step
// keeps the text and every file that already uploaded, and a retry reuses
// both keys, so nothing is saved twice.
export function MessageComposer({ draftKey, documentsApi, label, placeholder, withSubject = false, requireAttachment = false, uploadFields, submitLabel, disabled = false, rows = 3, actions, onSend }: Props): ReactElement {
  const statusId = useId();
  const fileInput = useRef<HTMLInputElement>(null);
  const [draft, setDraft] = useState<MessageDraft>(() => readDraft(draftKey));
  const keyRef = useRef(draftKey);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState('');
  const [pickerOpen, setPickerOpen] = useState(false);

  useEffect(() => {
    keyRef.current = draftKey;
    setDraft(readDraft(draftKey));
    setError(null);
    setStatus('');
  }, [draftKey]);

  // Writes to the draft for `key`, even after the person moved to another
  // conversation, so an upload that finishes late still lands in its draft.
  const mutate = useCallback((key: string, change: (current: MessageDraft) => MessageDraft): MessageDraft => {
    const next = change(readDraft(key));
    writeDraft(key, next);
    if (keyRef.current === key) setDraft(next);
    return next;
  }, []);

  const attachedCount = draft.attachments.length;
  const room = MAX_MESSAGE_FILES - attachedCount;

  const addFiles = (files: File[]): void => {
    setError(null);
    const accepted: LocalAttachment[] = [];
    const problems: string[] = [];
    files.forEach(file => {
      if (accepted.length >= room) { problems.push(`${file.name}: a message can have up to ${MAX_MESSAGE_FILES} files.`); return; }
      if (!file.size) { problems.push(`${file.name}: this file is empty.`); return; }
      if (file.size > MAX_FILE_BYTES) { problems.push(`${file.name}: choose a file 25 MB or smaller.`); return; }
      accepted.push({ kind: 'file', id: `file:${crypto.randomUUID()}`, file, uploadKey: crypto.randomUUID(), status: 'waiting' });
    });
    if (accepted.length) mutate(draftKey, current => ({ ...current, attachments: [...current.attachments, ...accepted] }));
    if (problems.length) setError(problems.join('\n'));
  };

  const addDocuments = (documents: ClientDocument[]): void => {
    mutate(draftKey, current => {
      const existing = new Set(current.attachments.flatMap(item => item.kind === 'document' ? [item.document.id] : []));
      const added = documents.filter(document => !existing.has(document.id)).slice(0, MAX_MESSAGE_FILES - current.attachments.length)
        .map(document => ({ kind: 'document' as const, id: `document:${document.id}`, document }));
      return { ...current, attachments: [...current.attachments, ...added] };
    });
  };

  const remove = (item: ComposerAttachment): void => {
    mutate(draftKey, current => ({ ...current, attachments: current.attachments.filter(candidate => candidate.id !== item.id) }));
  };

  const uploadPending = async (key: string): Promise<boolean> => {
    const pending = readDraft(key).attachments.filter((item): item is LocalAttachment => item.kind === 'file');
    let failed = 0;
    for (const [index, item] of pending.entries()) {
      setStatus(`Uploading ${index + 1} of ${pending.length}: ${item.file.name}`);
      mutate(key, current => ({ ...current, attachments: current.attachments.map(candidate => candidate.id === item.id ? { ...item, status: 'uploading', error: undefined } : candidate) }));
      try {
        const form = new FormData();
        form.append('files[]', item.file);
        Object.entries({ category: 'misc', ...uploadFields }).forEach(([name, value]) => form.append(name, value));
        form.append('for_message', 'true');
        form.append('upload_key', item.uploadKey);
        const response = await documentsApi.upload(form);
        const document = response.data[0];
        if (!document) throw new Error('Upload failed. Try again.');
        mutate(key, current => ({ ...current, attachments: current.attachments.map(candidate => candidate.id === item.id ? { kind: 'document', id: `document:${document.id}`, document } : candidate) }));
      } catch (err) {
        failed += 1;
        mutate(key, current => ({ ...current, attachments: current.attachments.map(candidate => candidate.id === item.id ? { ...item, status: 'failed', error: uploadMessage(err) } : candidate) }));
      }
    }
    setStatus('');
    return failed === 0;
  };

  const submit = async (event: FormEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault();
    if (sending || disabled) return;
    const key = draftKey;
    const current = readDraft(key);
    const body = current.body.trim();
    if (requireAttachment && !current.attachments.length) { setError('Attach the requested file first.'); return; }
    if (!body && !current.attachments.length && !(withSubject && current.subject.trim())) { setError('Write a message or attach a file.'); return; }
    setSending(true);
    setError(null);
    try {
      if (!(await uploadPending(key))) {
        setError('Some files did not upload. Try again, or remove them to send without them. Your message is kept.');
        return;
      }
      const ready = readDraft(key);
      const ids = ready.attachments.flatMap(item => item.kind === 'document' ? [item.document.id] : []);
      const subject = ready.subject.trim();
      const identity = JSON.stringify([subject, ready.body.trim(), ids]);
      const sendKey = ready.sendKey?.identity === identity ? ready.sendKey : { identity, key: crypto.randomUUID() };
      mutate(key, latest => ({ ...latest, sendKey }));
      setStatus('Sending…');
      await onSend({ subject, body: ready.body.trim(), document_ids: ids, idempotency_key: sendKey.key });
      // Keep anything typed or attached while the message was sending.
      mutate(key, latest => {
        const sentIds = new Set(ids);
        const remaining = latest.attachments.filter(item => item.kind !== 'document' || !sentIds.has(item.document.id));
        const unchanged = latest.body.trim() === ready.body.trim() && latest.subject.trim() === subject;
        return unchanged && !remaining.length ? EMPTY_DRAFT : { subject: unchanged ? '' : latest.subject, body: unchanged ? '' : latest.body, attachments: remaining };
      });
      setStatus('Sent');
    } catch (err) {
      setStatus('');
      setError(`${err instanceof Error && err.message ? err.message : 'Your message was not sent.'} Your text and files are kept, so you can try again.`);
    } finally {
      setSending(false);
    }
  };

  const busy = sending || disabled;
  return (
    <form onSubmit={event => void submit(event)} className="space-y-3" aria-describedby={statusId}>
      {withSubject && <Input label="Subject" value={draft.subject} onChange={event => { const value = event.target.value; mutate(draftKey, current => ({ ...current, subject: value })); }} maxLength={200} />}
      <LabeledTextarea label={label} value={draft.body} placeholder={placeholder} rows={rows} maxLength={5000}
        onChange={event => { const value = event.target.value; mutate(draftKey, current => ({ ...current, body: value })); }} />
      {draft.attachments.length > 0 && (
        <ul className="flex flex-wrap gap-2" aria-label="Files to send">
          {draft.attachments.map(item => (
            <li key={item.id} className={`inline-flex min-w-0 max-w-full items-center gap-2 rounded-xl py-1 pl-3 pr-1 text-xs ${item.kind === 'file' && item.status === 'failed' ? 'bg-danger-50 text-danger-800' : 'bg-neutral-100 text-neutral-800'}`}>
              <Paperclip className="h-3.5 w-3.5 shrink-0" aria-hidden />
              <span className="min-w-0 break-words [overflow-wrap:anywhere]">
                {item.kind === 'document' ? item.document.title : item.file.name}
                <span className="text-neutral-600"> · {formatFileSize(item.kind === 'document' ? item.document.file_size : item.file.size)}</span>
                {item.kind === 'file' && <span className="block">{item.status === 'uploading' ? 'Uploading…' : item.status === 'failed' ? `Not uploaded: ${item.error}` : 'Uploads when you send'}</span>}
              </span>
              <button type="button" onClick={() => remove(item)} disabled={sending} aria-label={`Remove ${item.kind === 'document' ? item.document.title : item.file.name}`}
                className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 disabled:opacity-50">
                <X className="h-3.5 w-3.5" aria-hidden />
              </button>
            </li>
          ))}
        </ul>
      )}
      <input ref={fileInput} type="file" multiple hidden accept=".pdf,.png,.jpg,.jpeg,.webp,.txt,.csv,.doc,.docx,.xls,.xlsx"
        onChange={event => { addFiles(Array.from(event.target.files || [])); event.target.value = ''; }} />
      {error && <p role="alert" className="whitespace-pre-line text-sm text-danger-700">{error}</p>}
      <p id={statusId} role="status" aria-live="polite" className="text-sm text-neutral-600">{status}</p>
      <div className="flex flex-wrap items-center gap-2">
        <Button type="button" variant="outline" disabled={busy || room <= 0} onClick={() => fileInput.current?.click()}>
          <Paperclip className="mr-2 h-4 w-4" aria-hidden />Upload and attach
        </Button>
        <Button type="button" variant="outline" disabled={busy || room <= 0} onClick={() => setPickerOpen(true)}>
          <FolderOpen className="mr-2 h-4 w-4" aria-hidden />Choose existing file
        </Button>
        {actions}
        <Button type="submit" disabled={busy} className="ml-auto">
          <Send className="mr-2 h-4 w-4" aria-hidden />{sending ? 'Sending…' : submitLabel}
        </Button>
      </div>
      <FilePickerDialog open={pickerOpen} onOpenChange={setPickerOpen} api={documentsApi}
        selectedIds={draft.attachments.flatMap(item => item.kind === 'document' ? [item.document.id] : [])}
        maxSelectable={room} onChoose={addDocuments} />
    </form>
  );
}
