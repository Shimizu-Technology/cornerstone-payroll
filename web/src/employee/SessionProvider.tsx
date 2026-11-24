import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement, type ReactNode } from 'react';
import { chooseLink, createEmployeeApi, problemFor } from './api';
import { API_BASE_URL, TENANT_SLUG, today } from './config';
import { EmployeeSessionContext, useEmployeeAuth, type EmployeeSessionState, type EmployeeSessionValue } from './contexts';
import { useSignOut } from './hooks';

/** How long opening the app may take before it shows the error screen with Try again. */
export const SESSION_LOAD_TIMEOUT_MS = 15_000;

class SessionLoadTimeout extends Error {}

/**
 * Opens the signed-in employee's pay: finds their link for this client
 * (GET /employee/links), then checks it (GET /employee/context). Data screens
 * use the same client, which sends the link in X-Employee-Link-Id. Nothing is
 * stored on the device.
 */
export function EmployeeSessionProvider({ children }: { children: ReactNode }): ReactElement {
  const { getToken } = useEmployeeAuth();
  const signOut = useSignOut();
  const api = useMemo(() => createEmployeeApi({ baseUrl: API_BASE_URL, getToken }), [getToken]);
  const [state, setState] = useState<EmployeeSessionState>({ status: 'loading' });
  const [attempt, setAttempt] = useState(0);
  const opened = useRef(false);

  useEffect(() => {
    // `cancelled` is cleanup (unmount, or a newer attempt): stay quiet.
    // A deadline that passes aborts the requests too, but shows the error screen.
    let cancelled = false;
    const controller = new AbortController();
    let timer: number | undefined;
    const deadline = new Promise<never>((_, reject) => {
      timer = window.setTimeout(() => {
        controller.abort();
        reject(new SessionLoadTimeout());
      }, SESSION_LOAD_TIMEOUT_MS);
    });
    // Waits on the request, but never longer than the deadline (getToken can't be aborted).
    const bounded = <T,>(request: Promise<T>): Promise<T> => Promise.race([request, deadline]);
    deadline.catch(() => undefined);

    setState({ status: 'loading' });
    void (async (): Promise<void> => {
      try {
        const choice = chooseLink(await bounded(api.links(controller.signal)), today(), TENANT_SLUG);
        if (cancelled) return;
        if (typeof choice === 'string') {
          setState({ status: 'problem', problem: choice });
          return;
        }
        await bounded(api.context(choice.id, controller.signal));
        if (cancelled) return;
        opened.current = true;
        setState({ status: 'ready', link: choice });
      } catch (error) {
        if (cancelled) return;
        const problem = error instanceof SessionLoadTimeout || controller.signal.aborted ? 'error' : problemFor(error, { opened: opened.current });
        setState({ status: 'problem', problem });
      } finally {
        window.clearTimeout(timer);
      }
    })();
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [api, attempt]);

  const problem = state.status === 'problem' ? state.problem : null;

  // The API no longer accepts this session: sign out. If that fails, show the
  // error screen (Try again, Sign out) rather than an endless loading screen.
  useEffect(() => {
    if (problem !== 'signed_out') return;
    let current = true;
    void signOut().then((signedOut) => {
      if (!signedOut && current) setState({ status: 'problem', problem: 'error' });
    });
    return () => {
      current = false;
    };
  }, [problem, signOut]);

  const retry = useCallback((): void => setAttempt((n) => n + 1), []);

  // Come back on its own when the connection returns. If it came back before
  // this listener was added, retry once now. A load that then fails while
  // online shows the error screen, not offline, so this can't loop.
  useEffect(() => {
    if (problem !== 'offline') return;
    if (navigator.onLine) {
      retry();
      return;
    }
    window.addEventListener('online', retry);
    return () => window.removeEventListener('online', retry);
  }, [problem, retry]);

  const reportError = useCallback((error: unknown): void => {
    setState({ status: 'problem', problem: problemFor(error, { opened: opened.current }) });
  }, []);

  const value = useMemo<EmployeeSessionValue>(() => ({ state, api, retry, reportError }), [state, api, retry, reportError]);
  return <EmployeeSessionContext.Provider value={value}>{children}</EmployeeSessionContext.Provider>;
}
