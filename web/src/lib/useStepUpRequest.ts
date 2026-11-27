import { useCallback } from 'react';
import { useAuth, useClerk, useReverification } from '@clerk/react';
import { beginStepUpOverlay } from '@/components/ui/dialog-overlay';
import { isMfaRequiredCode, MFA_REQUIRED_EVENT } from '@/services/api';

const POST_STEP_UP_RETRY_DELAYS_MS = [250, 600];

export const STEP_UP_INCOMPLETE_MESSAGE =
  "This change needs a fresh sign-in check, and it wasn't completed. Try again and confirm it's you when asked.";

export function isReverificationErrorBody(data: unknown): boolean {
  if (!data || typeof data !== 'object') return false;
  const clerkError = (data as { clerk_error?: unknown }).clerk_error;
  return Boolean(
    clerkError
    && typeof clerkError === 'object'
    && (clerkError as { reason?: unknown }).reason === 'reverification-error',
  );
}

export function stepUpErrorMessage(data: unknown, fallback: string): string {
  if (data && typeof data === 'object') {
    const error = (data as { error?: unknown }).error;
    if (typeof error === 'string' && error.trim()) return error;
    const errors = (data as { errors?: unknown }).errors;
    if (Array.isArray(errors) && errors.length > 0) return errors.map(String).join(', ');
  }
  if (isReverificationErrorBody(data)) return STEP_UP_INCOMPLETE_MESSAGE;
  return fallback;
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => globalThis.setTimeout(resolve, ms));
}

interface StepUpAttemptState {
  rejectedToken: string | null;
  reverified: boolean;
  releaseOverlay: (() => void) | null;
}

/**
 * Pass a request factory so Clerk can retry it with a fresh session token.
 * If the person closes the prompt, the call throws; check it with
 * `isReverificationCancelledError` from `@clerk/react/errors`.
 */
export function useStepUpRequest<Args extends unknown[]>(
  request: (token: string, ...args: Args) => Promise<Response>,
): (...args: Args) => Promise<Response> {
  const { getToken } = useAuth();
  const clerk = useClerk();

  const fetchFreshToken = useCallback(async (reloadSession: boolean): Promise<string> => {
    if (reloadSession) {
      const session = clerk?.session as { reload?: () => Promise<unknown> } | null | undefined;
      if (typeof session?.reload === 'function') {
        await session.reload().catch(() => undefined);
      }
    }
    const token = await getToken({ skipCache: true });
    if (!token) throw new Error('A signed-in session is required.');
    return token;
  }, [clerk, getToken]);

  const send = useReverification(async (attempt: StepUpAttemptState, ...args: Args) => {
    if (attempt.reverified) {
      attempt.releaseOverlay?.();
      attempt.releaseOverlay = null;

      let token = await fetchFreshToken(true);
      for (let retry = 0; retry <= POST_STEP_UP_RETRY_DELAYS_MS.length; retry += 1) {
        if (token === attempt.rejectedToken && retry < POST_STEP_UP_RETRY_DELAYS_MS.length) {
          await wait(POST_STEP_UP_RETRY_DELAYS_MS[retry]);
          token = await fetchFreshToken(true);
          continue;
        }

        const response = await request(token, ...args);
        if (response.status !== 403) return { response };

        const hint = await response.clone().json().catch(() => null);
        if (hint && typeof hint === 'object' && isMfaRequiredCode(hint.code)) {
          const message = typeof hint.error === 'string' ? hint.error : undefined;
          globalThis.window?.dispatchEvent(new CustomEvent(MFA_REQUIRED_EVENT, { detail: { code: hint.code, message } }));
          return { response };
        }
        if (isReverificationErrorBody(hint) && retry < POST_STEP_UP_RETRY_DELAYS_MS.length) {
          await wait(POST_STEP_UP_RETRY_DELAYS_MS[retry]);
          token = await fetchFreshToken(true);
          continue;
        }
        return { response, clerk_error: hint?.clerk_error };
      }
    }

    const token = await fetchFreshToken(false);
    const response = await request(token, ...args);
    if (response.status !== 403) return { response };

    const hint = await response.clone().json().catch(() => null);
    if (hint && typeof hint === 'object' && isMfaRequiredCode(hint.code)) {
      const message = typeof hint.error === 'string' ? hint.error : undefined;
      globalThis.window?.dispatchEvent(new CustomEvent(MFA_REQUIRED_EVENT, { detail: { code: hint.code, message } }));
    }
    if (isReverificationErrorBody(hint)) {
      attempt.rejectedToken = token;
      attempt.reverified = true;
      attempt.releaseOverlay = beginStepUpOverlay();
    }
    return { response, clerk_error: hint?.clerk_error };
  });

  return useCallback(async (...args: Args) => {
    const attempt: StepUpAttemptState = { rejectedToken: null, reverified: false, releaseOverlay: null };
    try {
      return (await send(attempt, ...args)).response;
    } finally {
      attempt.releaseOverlay?.();
      attempt.releaseOverlay = null;
    }
  }, [send]);
}
