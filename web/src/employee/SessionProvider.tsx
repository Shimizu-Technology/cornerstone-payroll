import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { chooseLink, createEmployeeApi, problemFor } from './api';
import { API_BASE_URL, today } from './config';
import { EmployeeSessionContext, useEmployeeAuth, type EmployeeSessionState, type EmployeeSessionValue } from './contexts';

/**
 * Opens the signed-in employee's pay: finds their link (GET /employee/links),
 * then checks it (GET /employee/context). Data screens use the same client,
 * which sends the link in X-Employee-Link-Id. Nothing is stored on the device.
 */
export function EmployeeSessionProvider({ children }: { children: ReactNode }) {
  const { getToken, signOut } = useEmployeeAuth();
  const api = useMemo(() => createEmployeeApi({ baseUrl: API_BASE_URL, getToken }), [getToken]);
  const [state, setState] = useState<EmployeeSessionState>({ status: 'loading' });
  const [attempt, setAttempt] = useState(0);
  const opened = useRef(false);

  useEffect(() => {
    const controller = new AbortController();
    setState({ status: 'loading' });
    void (async () => {
      try {
        const choice = chooseLink(await api.links(controller.signal), today());
        if (typeof choice === 'string') {
          setState({ status: 'problem', problem: choice });
          return;
        }
        await api.context(choice.id, controller.signal);
        if (controller.signal.aborted) return;
        opened.current = true;
        setState({ status: 'ready', link: choice });
      } catch (error) {
        if (controller.signal.aborted) return;
        setState({ status: 'problem', problem: problemFor(error, { opened: opened.current }) });
      }
    })();
    return () => controller.abort();
  }, [api, attempt]);

  const problem = state.status === 'problem' ? state.problem : null;

  useEffect(() => {
    if (problem === 'signed_out') void signOut();
  }, [problem, signOut]);

  const retry = useCallback(() => setAttempt((n) => n + 1), []);

  // Come back on its own when the connection returns.
  useEffect(() => {
    if (problem !== 'offline') return;
    window.addEventListener('online', retry);
    return () => window.removeEventListener('online', retry);
  }, [problem, retry]);

  const reportError = useCallback((error: unknown) => {
    setState({ status: 'problem', problem: problemFor(error, { opened: opened.current }) });
  }, []);

  const value = useMemo<EmployeeSessionValue>(() => ({ state, api, retry, reportError }), [state, api, retry, reportError]);
  return <EmployeeSessionContext.Provider value={value}>{children}</EmployeeSessionContext.Provider>;
}
