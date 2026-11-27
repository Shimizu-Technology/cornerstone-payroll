import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement, type ReactNode } from 'react';
import { chooseLink, createEmployeeApi, problemFor, usableLinks, type EmployeeLink } from './api';
import { API_BASE_URL, TENANT_SLUG, today } from './config';
import { EmployeeSessionContext, useEmployeeAuth, type EmployeeSessionState, type EmployeeSessionValue } from './contexts';
import { useSignOut } from './hooks';
import { resetAnalytics } from '@/lib/analytics';

/** How long opening the app may take before it shows the error screen with Try again. */
export const SESSION_LOAD_TIMEOUT_MS = 15_000;

class SessionLoadTimeout extends Error {}

/**
 * Opens the signed-in employee's pay: finds their link for this client
 * (GET /employee/links), asks them to pick an employer when there's more than
 * one on a shared host, then checks it (GET /employee/context). Data screens
 * use the same client, which sends the link in X-Employee-Link-Id. Nothing is
 * stored on the device: the chosen employer and loaded pay live in memory.
 */
export function EmployeeSessionProvider({ viewOnly = false, support, initialLinkId = null, children }: {
  viewOnly?: boolean;
  support?: { token: string; link: EmployeeLink };
  /** The link just claimed or reactivated, so a login with several employers opens that one. */
  initialLinkId?: string | null;
  children: ReactNode;
}): ReactElement {
  const { getToken } = useEmployeeAuth();
  const signOut = useSignOut();
  const api = useMemo(() => createEmployeeApi({ baseUrl: API_BASE_URL, getToken, grantToken: support?.token }), [getToken, support?.token]);
  const [state, setState] = useState<EmployeeSessionState>({ status: 'loading' });
  const [attempt, setAttempt] = useState(0);
  const [chosenId, setChosenId] = useState<string | null>(initialLinkId);
  const opened = useRef(false);
  const [memory, setMemory] = useState(() => new Map<string, unknown>());

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
        const links = support ? [support.link] : await bounded(api.links(controller.signal));
        const choice = support?.link ?? chooseLink(links, today(), TENANT_SLUG, chosenId);
        if (cancelled) return;
        if (choice === 'choose') {
          const usable = usableLinks(links, today(), TENANT_SLUG);
          setState({ status: 'choose', links: typeof usable === 'string' ? [] : usable });
          return;
        }
        if (typeof choice === 'string') {
          setState({ status: 'problem', problem: choice });
          return;
        }
        const info = await bounded(api.context(choice.id, controller.signal));
        if (cancelled) return;
        opened.current = true;
        const usable = usableLinks(links, today(), TENANT_SLUG);
        setState({ status: 'ready', link: choice, links: typeof usable === 'string' ? [choice] : usable, info });
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
  }, [api, attempt, chosenId, support]);

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

  const chooseLinkId = useCallback((linkId: string | null): void => {
    // Another employer's pay never shows from this one's memory, and analytics
    // starts a fresh anonymous device session on employer switch.
    setMemory(new Map());
    resetAnalytics();
    opened.current = false;
    setChosenId(linkId);
    setAttempt((n) => n + 1);
  }, []);

  // Tracked apart, so a view-only look at a former employee shows exactly what that employee sees.
  const isFormer = state.status === 'ready' && (state.link.status === 'former' || state.info.status === 'former');
  const isViewOnly = viewOnly || Boolean(support);

  const value = useMemo<EmployeeSessionValue>(
    () => ({ state, api, retry, reportError, chooseLink: chooseLinkId, isFormer, isViewOnly, readOnly: isFormer || isViewOnly, memory }),
    [state, api, retry, reportError, chooseLinkId, isFormer, isViewOnly, memory],
  );
  return <EmployeeSessionContext.Provider value={value}>{children}</EmployeeSessionContext.Provider>;
}
