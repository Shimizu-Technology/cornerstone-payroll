import { useCallback, useEffect, useState } from 'react';
import { EmployeeApiError, type EmployeeApi } from './api';
import { useReadySession } from './contexts';

/**
 * Failures that belong to the whole session, not one screen: signed out, the
 * link gone (404), or two-step sign-in needed. Screens pass these to
 * reportError so the session shows the right full screen.
 */
export function isSessionError(error: unknown): error is EmployeeApiError {
  return error instanceof EmployeeApiError
    && (error.kind === 'not_found' || error.kind === 'unauthorized' || error.kind === 'mfa_enrollment_required' || error.kind === 'mfa_required');
}

export type DataState<T> =
  | { status: 'loading' }
  | { status: 'ready'; data: T }
  /** A failure this screen can recover from on its own: offline, too many tries, a server error. */
  | { status: 'error'; kind: 'offline' | 'rate_limited' | 'server' };

/**
 * Loads one thing for the open link and keeps it in session memory, so going
 * from the list to a stub and back doesn't reload. Memory is a Map in React
 * state: it's gone on reload, sign-out or a switch of employer, and nothing is
 * written to the device. A 401, a 404 or a two-step sign-in 403 goes to the session, which signs out
 * or shows its full screen; other failures stay on this screen with Try again.
 */
export function useEmployeeData<T>(
  key: string | null,
  load: (api: EmployeeApi, linkId: string, signal: AbortSignal) => Promise<T>,
): { state: DataState<T>; reload: () => void; update: (data: T) => void } {
  const { api, state: session, reportError, memory } = useReadySession();
  const linkId = session.link.id;
  const cacheKey = key ? `${linkId}:${key}` : null;
  const [attempt, setAttempt] = useState(0);
  // Tagged with its key, so a screen that switches stubs never shows the last one's data.
  const [loaded, setLoaded] = useState<{ key: string; state: DataState<T> } | null>(null);

  useEffect(() => {
    if (!cacheKey || memory.has(cacheKey)) return undefined;
    const controller = new AbortController();
    setLoaded({ key: cacheKey, state: { status: 'loading' } });
    load(api, linkId, controller.signal).then((data) => {
      if (controller.signal.aborted) return;
      memory.set(cacheKey, data);
      setLoaded({ key: cacheKey, state: { status: 'ready', data } });
    }, (error: unknown) => {
      if (controller.signal.aborted) return;
      if (error instanceof EmployeeApiError && (error.kind === 'offline' || error.kind === 'rate_limited')) {
        setLoaded({ key: cacheKey, state: { status: 'error', kind: error.kind } });
      } else if (isSessionError(error)) {
        reportError(error);
      } else {
        setLoaded({ key: cacheKey, state: { status: 'error', kind: 'server' } });
      }
    });
    return () => controller.abort();
    // `load` is a fresh closure on every render; the key says what it loads.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cacheKey, attempt, api, linkId, memory, reportError]);

  const reload = useCallback(() => {
    if (cacheKey) memory.delete(cacheKey);
    setAttempt((n) => n + 1);
  }, [cacheKey, memory]);
  const update = useCallback((data: T) => {
    if (!cacheKey) return;
    memory.set(cacheKey, data);
    setLoaded({ key: cacheKey, state: { status: 'ready', data } });
  }, [cacheKey, memory]);

  let state: DataState<T> = { status: 'loading' };
  if (loaded && loaded.key === cacheKey) state = loaded.state;
  else if (cacheKey && memory.has(cacheKey)) state = { status: 'ready', data: memory.get(cacheKey) as T };
  return { state, reload, update };
}
