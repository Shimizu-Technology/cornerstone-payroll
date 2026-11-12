import type { ClientDocument } from '@/services/api';

// A file picked from the device. Its upload key stays the same across
// retries, so a retried upload returns the files the server already saved.
export type LocalAttachment = { kind: 'file'; id: string; file: File; uploadKey: string; status: 'waiting' | 'uploading' | 'failed'; error?: string };
export type SavedAttachment = { kind: 'document'; id: string; document: ClientDocument };
export type ComposerAttachment = LocalAttachment | SavedAttachment;

export type MessageDraft = {
  subject: string;
  body: string;
  attachments: ComposerAttachment[];
  // The send retry key and the exact content it was first used for.
  sendKey?: { identity: string; key: string };
};

export const EMPTY_DRAFT: MessageDraft = { subject: '', body: '', attachments: [] };
const STORAGE_PREFIX = 'portal-message-draft:';

// Drafts are keyed by company and conversation, so text or files never move
// to another client or topic. Text and uploaded files also survive a reload
// in this tab; device files that have not uploaded yet stay in memory only.
const memory = new Map<string, MessageDraft>();

function storageKey(key: string): string {
  return `${STORAGE_PREFIX}${key}`;
}

export function readDraft(key: string): MessageDraft {
  const cached = memory.get(key);
  if (cached) return cached;
  try {
    const raw = window.sessionStorage.getItem(storageKey(key));
    if (!raw) return EMPTY_DRAFT;
    const parsed = JSON.parse(raw) as { subject?: string; body?: string; documents?: ClientDocument[]; sendKey?: MessageDraft['sendKey'] };
    const draft: MessageDraft = {
      subject: typeof parsed.subject === 'string' ? parsed.subject : '',
      body: typeof parsed.body === 'string' ? parsed.body : '',
      attachments: Array.isArray(parsed.documents) ? parsed.documents.map(document => ({ kind: 'document' as const, id: `document:${document.id}`, document })) : [],
      sendKey: parsed.sendKey,
    };
    memory.set(key, draft);
    return draft;
  } catch {
    return EMPTY_DRAFT;
  }
}

export function writeDraft(key: string, draft: MessageDraft): void {
  const empty = !draft.subject && !draft.body && !draft.attachments.length;
  if (empty) memory.delete(key); else memory.set(key, draft);
  try {
    if (empty) {
      window.sessionStorage.removeItem(storageKey(key));
      return;
    }
    const documents = draft.attachments.filter((item): item is SavedAttachment => item.kind === 'document').map(item => item.document);
    window.sessionStorage.setItem(storageKey(key), JSON.stringify({ subject: draft.subject, body: draft.body, documents, sendKey: draft.sendKey }));
  } catch {
    // Storage can be full or disabled; the in-memory draft still works.
  }
}

export function clearDraft(key: string): void {
  writeDraft(key, EMPTY_DRAFT);
}

export function hasDraft(key: string): boolean {
  const draft = readDraft(key);
  return Boolean(draft.subject.trim() || draft.body.trim() || draft.attachments.length);
}

// Forgets every draft in this tab, for example after signing out.
export function clearAllDrafts(): void {
  memory.clear();
  try {
    Object.keys(window.sessionStorage).filter(key => key.startsWith(STORAGE_PREFIX)).forEach(key => window.sessionStorage.removeItem(key));
  } catch {
    // Storage unavailable; memory is already cleared.
  }
}
