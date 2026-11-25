import { useEffect, useState } from 'react';
import { leaveSupportView, supportRequest, type SupportGrant } from './grant';

export function useSupportView(base: string, getToken: () => Promise<string | null>, destination: string) {
  const [grant, setGrant] = useState<SupportGrant | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [endError, setEndError] = useState<string | null>(null);
  const [ending, setEnding] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const abort = new AbortController();
    let expiry: number | undefined;
    const timeout = window.setTimeout(() => {
      setLoadError('Could not open this support view. Try again.');
      abort.abort();
    }, 15_000);
    void (async () => {
      try {
        const response = await supportRequest(base, await getToken(), 'GET', abort.signal);
        if (abort.signal.aborted) return;
        if (!response.ok) {
          setLoadError(response.status === 403
            ? 'Verify two-step sign-in with your staff account, then try again.'
            : response.status === 404 ? 'This support view is unavailable or has ended.' : 'Could not open this support view. Try again.');
          return;
        }
        const next = await response.json() as SupportGrant;
        const remaining = Date.parse(next.expires_at) - Date.now();
        if (abort.signal.aborted) return;
        if (!Number.isFinite(remaining) || remaining <= 0) {
          setLoadError('This support view has ended.');
          return;
        }
        setGrant(next);
        expiry = window.setTimeout(() => {
          setGrant(null);
          setLoadError('This support view has ended.');
        }, remaining);
      } catch {
        if (!abort.signal.aborted) setLoadError('Could not open this support view. Try again.');
      } finally {
        window.clearTimeout(timeout);
      }
    })();

    return () => {
      abort.abort();
      window.clearTimeout(timeout);
      window.clearTimeout(expiry);
    };
  }, [base, getToken, attempt]);

  const end = async () => {
    setEnding(true);
    setEndError(null);
    try {
      const response = await supportRequest(base, await getToken(), 'DELETE', AbortSignal.timeout(15_000));
      if (!response.ok) throw new Error('Could not end this support view.');
      leaveSupportView(destination);
    } catch {
      setEndError('Could not end this support view. Try again.');
      setEnding(false);
    }
  };

  return {
    grant, loadError, endError, ending, end,
    retry: () => { setLoadError(null); setAttempt((count) => count + 1); },
    leave: () => leaveSupportView(destination),
  };
}
