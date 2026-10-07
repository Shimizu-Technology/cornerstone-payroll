/* eslint-disable react-refresh/only-export-components */
import { createContext, useCallback, useContext, useEffect, useId, useMemo, useRef, useState, type ReactNode, type Dispatch, type SetStateAction } from 'react';
import { createPortal } from 'react-dom';
import { errorRecovery } from '@/lib/error-recovery';
import { AlertCircle, CheckCircle2, Info, TriangleAlert, X } from 'lucide-react';

// Legacy check dialogs use a body portal above the shared dialog tier.
export const ACTION_OVERLAY_LAYERS = { legacyDialog: 'z-[9999]', feedback: 'z-[10000]' } as const;

export type FeedbackTone = 'error' | 'success' | 'warning' | 'info';
type FeedbackInput = { tone: FeedbackTone; message: string; children?: ReactNode };
type FeedbackEntry = FeedbackInput & { id: string; scope: string; owners: string[]; content?: () => ReactNode };
interface FeedbackContextValue {
  notify: (input: FeedbackInput, owner?: string) => void;
  publish: (input: FeedbackInput, owner: string, content: () => ReactNode) => void;
  release: (owner: string) => void;
}
const FeedbackContext = createContext<FeedbackContextValue | null>(null);
const tones = {
  error: { label: 'Action needs attention', icon: AlertCircle, style: 'border-red-300 bg-white text-red-950', accent: 'bg-red-100 text-red-700' },
  success: { label: 'Completed', icon: CheckCircle2, style: 'border-emerald-300 bg-white text-emerald-950', accent: 'bg-emerald-100 text-emerald-700' },
  warning: { label: 'Review this action', icon: TriangleAlert, style: 'border-amber-300 bg-white text-amber-950', accent: 'bg-amber-100 text-amber-700' },
  info: { label: 'Update', icon: Info, style: 'border-blue-300 bg-white text-blue-950', accent: 'bg-blue-100 text-blue-700' },
};

/** Scoped to the signed-in user and company, so notices never cross client boundaries. */
export function FeedbackProvider({ children, scopeKey = 'default' }: { children: ReactNode; scopeKey?: string }) {
  const [entries, setEntries] = useState<FeedbackEntry[]>([]);
  const sequence = useRef(0);
  const currentScope = useRef(scopeKey);
  currentScope.current = scopeKey;
  const enqueue = useCallback((input: FeedbackInput, owner?: string, content?: () => ReactNode, replaceOwner = false) => {
    if (!input.message.trim() || currentScope.current !== scopeKey) return;
    setEntries((current) => {
      if (currentScope.current !== scopeKey) return current;
      const scoped = current.filter((entry) => entry.scope === scopeKey).flatMap((entry) => {
        if (!replaceOwner || !owner || !entry.owners.includes(owner) || (entry.tone !== 'error' && entry.tone !== 'warning')) return [entry];
        const owners = entry.owners.filter((value) => value !== owner);
        return owners.length ? [{ ...entry, owners }] : [];
      });
      const rich = Boolean(input.children || content?.());
      const existing = scoped.find((entry) => entry.tone === input.tone && entry.message === input.message &&
        ((!rich && !entry.children && !entry.content?.()) || (owner && entry.owners.includes(owner))));
      if (existing) return scoped.map((entry) => entry.id === existing.id
        ? { ...entry, ...input, content: content || entry.content, owners: owner ? [...new Set([...entry.owners, owner])] : entry.owners }
        : entry);
      return [{ ...input, scope: scopeKey, id: `feedback-${++sequence.current}`, owners: owner ? [owner] : [], content }, ...scoped];
    });
  }, [scopeKey]);
  const notify = useCallback((input: FeedbackInput, owner?: string) => enqueue(input, owner, undefined, true), [enqueue]);
  const publish = useCallback((input: FeedbackInput, owner: string, content: () => ReactNode) => enqueue(input, owner, content), [enqueue]);
  const release = useCallback((owner: string) => {
    setEntries((current) => current.flatMap((entry) => {
      if (!entry.owners.includes(owner)) return [entry];
      const owners = entry.owners.filter((value) => value !== owner);
      // Successes remain visible across navigation. Errors disappear when their source resolves.
      return owners.length || entry.tone === 'success' || entry.tone === 'info' ? [{ ...entry, owners }] : [];
    }));
  }, []);
  const dismiss = useCallback((id: string) => {
    const active = document.activeElement;
    if (active instanceof HTMLElement && active.closest('[data-feedback-portal]')) {
      document.querySelector<HTMLElement>('[data-dialog-portal]:not([inert]) [role="dialog"]')?.focus();
    }
    setEntries((current) => current.filter((entry) => entry.id !== id));
  }, []);
  const value = useMemo(() => ({ notify, publish, release }), [notify, publish, release]);
  useEffect(() => { setEntries((current) => current.filter((entry) => entry.scope === scopeKey)); }, [scopeKey]);
  const visible = entries.filter((entry) => entry.scope === scopeKey);
  return <FeedbackContext.Provider value={value}>
    {children}
    {typeof document !== 'undefined' && createPortal(
      <div data-feedback-portal aria-label="Action notifications" className={`pointer-events-none fixed inset-x-0 top-[max(1rem,env(safe-area-inset-top))] ${ACTION_OVERLAY_LAYERS.feedback} mx-auto flex max-h-[min(60dvh,36rem)] w-[min(36rem,calc(100vw-2rem))] flex-col gap-3 overflow-y-auto overscroll-contain p-1`}>
        {visible.map((entry) => <FeedbackToast key={entry.id} entry={entry} dismiss={dismiss} />)}
      </div>, document.body)}
  </FeedbackContext.Provider>;
}

function FeedbackToast({ entry, dismiss }: { entry: FeedbackEntry; dismiss: (id: string) => void }) {
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  const remaining = useRef(10_000);
  const paused = hovered || focused;
  useEffect(() => {
    if (paused || (entry.tone !== 'success' && entry.tone !== 'info')) return;
    const started = Date.now();
    const timer = window.setTimeout(() => dismiss(entry.id), remaining.current);
    return () => { window.clearTimeout(timer); remaining.current = Math.max(0, remaining.current - (Date.now() - started)); };
  }, [dismiss, entry.id, entry.tone, paused]);
  const { label, icon: Icon, style, accent } = tones[entry.tone];
  const recovery = entry.tone === 'error' ? errorRecovery(entry.message) : null;
  return <div role={entry.tone === 'error' ? 'alert' : 'status'} aria-atomic="true" data-feedback-tone={entry.tone}
    onMouseEnter={() => setHovered(true)} onMouseLeave={() => setHovered(false)}
    onFocusCapture={() => setFocused(true)} onBlurCapture={(event) => { if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setFocused(false); }}
    className={`pointer-events-auto flex items-start gap-3 rounded-2xl border p-3 shadow-xl shadow-neutral-950/15 motion-safe:animate-[feedback-enter_160ms_ease-out] ${style}`}>
    <span className={`mt-1 rounded-full p-2 ${accent}`}><Icon aria-hidden="true" className="h-5 w-5" /></span>
    <div className="min-w-0 flex-1 py-1"><p className="text-sm font-semibold">{label}</p><div className="mt-1 break-words text-sm leading-6 [&_a]:underline [&_button]:min-h-11 [&_button]:min-w-11">{entry.content?.() || entry.children || entry.message}</div>{recovery && <p className="mt-2 break-words text-sm leading-6 text-neutral-700"><span className="font-semibold">What to do: </span>{recovery}</p>}</div>
    <button type="button" aria-label={`Dismiss notification: ${entry.message}`} className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl text-neutral-600 hover:bg-neutral-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500" onClick={() => dismiss(entry.id)}><X aria-hidden="true" className="h-5 w-5" /></button>
  </div>;
}

/** Explicit replacement for transient action banners; rich details are preserved. */
export function ActionFeedback({ tone, message, children, retryKey }: FeedbackInput & { retryKey?: number }) {
  const feedback = useContext(FeedbackContext);
  const owner = useId();
  const content = useRef(children);
  content.current = children;
  const publish = feedback?.publish;
  const release = feedback?.release;
  useEffect(() => {
    if (!message.trim() || !publish || !release) return;
    publish({ tone, message }, owner, () => content.current);
    return () => release(owner);
  }, [message, owner, publish, release, tone, retryKey]);
  if (feedback || !message.trim()) return null;
  // Standalone tests and server-rendered components retain readable feedback.
  return <div role={tone === 'error' ? 'alert' : 'status'}>{children || message}</div>;
}

export function useFeedback(): { notify: (input: FeedbackInput) => void } {
  const feedback = useContext(FeedbackContext);
  const owner = useId();
  const publish = feedback?.notify;
  const release = feedback?.release;
  useEffect(() => () => release?.(owner), [owner, release]);
  const notify = useCallback((input: FeedbackInput) => publish?.(input, owner), [owner, publish]);
  return useMemo(() => ({ notify }), [notify]);
}


/** Retain error state while letting a repeated failed attempt show a dismissed toast again. */
export function useFeedbackState<T>(initial: T | (() => T)): [T, Dispatch<SetStateAction<T>>, number] {
  const [value, setValue] = useState<T>(initial);
  const [attempt, setAttempt] = useState(0);
  const setFeedback = useCallback<Dispatch<SetStateAction<T>>>((next) => {
    setValue(next);
    setAttempt((previous) => previous + 1);
  }, []);
  return [value, setFeedback, attempt];
}
