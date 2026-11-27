/** @vitest-environment jsdom */
import { ClerkInstanceContext } from '@clerk/shared/react';
import { renderHook } from '@testing-library/react';
import type { ContextType, PropsWithChildren } from 'react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MFA_REQUIRED_EVENT } from '@/services/api';
import { STEP_UP_INCOMPLETE_MESSAGE, stepUpErrorMessage, useStepUpRequest } from './useStepUpRequest';

const { getToken } = vi.hoisted(() => ({ getToken: vi.fn() }));

vi.mock('@clerk/react', async (importOriginal) => ({
  ...await importOriginal<typeof import('@clerk/react')>(),
  useAuth: () => ({ getToken }),
}));

type Clerk = NonNullable<ContextType<typeof ClerkInstanceContext>>['value'];
const openReverification = vi.fn<Clerk['__internal_openReverification']>();
const reloadSession = vi.fn<() => Promise<void>>();
const clerk = {
  __internal_openReverification: openReverification,
  session: { reload: reloadSession },
} as unknown as Clerk;

function wrapper({ children }: PropsWithChildren) {
  return <ClerkInstanceContext.Provider value={{ value: clerk }}>{children}</ClerkInstanceContext.Provider>;
}

beforeEach(() => {
  getToken.mockReset().mockResolvedValue('initial-token');
  openReverification.mockReset();
  reloadSession.mockReset().mockResolvedValue(undefined);
});

describe('useStepUpRequest', () => {
  it.each(['first_factor', 'second_factor'])('uses Clerk to prompt for %s and retry with a fresh token', async (level) => {
    getToken.mockResolvedValueOnce('initial-token').mockResolvedValueOnce('verified-token');
    openReverification.mockImplementation((props) => props?.afterVerification?.({}));
    const fetchRequest = vi.fn<(token: string, change: { phone: string }) => Promise<Response>>()
      .mockResolvedValueOnce(Response.json({
        clerk_error: {
          type: 'forbidden',
          reason: 'reverification-error',
          metadata: { reverification: { level, afterMinutes: 10 } },
        },
      }, { status: 403 }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    const { result } = renderHook(() => useStepUpRequest(fetchRequest), { wrapper });
    const change = { phone: '555-0100' };

    expect((await result.current(change)).status).toBe(204);
    expect(openReverification).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ level }));
    expect(fetchRequest.mock.calls).toEqual([['initial-token', change], ['verified-token', change]]);
    expect(getToken.mock.calls).toEqual([[{ skipCache: true }], [{ skipCache: true }]]);
  });

  it('preserves the status and body of an unrelated 403 without retrying', async () => {
    const body = { error: 'Permission denied' };
    const response = Response.json(body, { status: 403 });
    const fetchRequest = vi.fn().mockResolvedValue(response);
    const { result } = renderHook(() => useStepUpRequest(fetchRequest), { wrapper });

    const received = await result.current();
    expect(received).toBe(response);
    expect(await received.json()).toEqual(body);
    expect(openReverification).not.toHaveBeenCalled();
    expect(fetchRequest).toHaveBeenCalledTimes(1);
  });

  it('notifies the app MFA flow when a step-up request returns mfa_enrollment_required', async () => {
    const body = { error: 'Set up two-step sign-in to make this change.', code: 'mfa_enrollment_required' };
    const response = Response.json(body, { status: 403 });
    const fetchRequest = vi.fn().mockResolvedValue(response);
    const onMfa = vi.fn();
    window.addEventListener(MFA_REQUIRED_EVENT, onMfa);
    try {
      const { result } = renderHook(() => useStepUpRequest(fetchRequest), { wrapper });
      const received = await result.current();
      expect(received).toBe(response);
      expect(openReverification).not.toHaveBeenCalled();
      expect(onMfa).toHaveBeenCalledTimes(1);
      expect((onMfa.mock.calls[0][0] as CustomEvent).detail).toEqual({
        code: 'mfa_enrollment_required',
        message: body.error,
      });
    } finally {
      window.removeEventListener(MFA_REQUIRED_EVENT, onMfa);
    }
  });

  it('reloads the Clerk session and retries with a fresh token if the first post-reverification token is stale', async () => {
    vi.useFakeTimers();
    try {
      const reverificationResponse = () => Response.json({
        clerk_error: {
          type: 'forbidden',
          reason: 'reverification-error',
          metadata: { reverification: { level: 'first_factor', afterMinutes: 10 } },
        },
      }, { status: 403 });

      getToken
        .mockResolvedValueOnce('stale-token')
        .mockResolvedValueOnce('stale-token')
        .mockResolvedValueOnce('fresh-verified-token');
      openReverification.mockImplementation((props) => props?.afterVerification?.({}));
      const fetchRequest = vi.fn<(token: string) => Promise<Response>>()
        .mockResolvedValueOnce(reverificationResponse())
        .mockResolvedValueOnce(new Response(null, { status: 200 }));
      const { result } = renderHook(() => useStepUpRequest(fetchRequest), { wrapper });

      const pending = result.current();
      await vi.runAllTimersAsync();
      const response = await pending;

      expect(response.status).toBe(200);
      expect(reloadSession).toHaveBeenCalledTimes(2);
      expect(getToken.mock.calls).toEqual([[{ skipCache: true }], [{ skipCache: true }], [{ skipCache: true }]]);
      expect(fetchRequest.mock.calls).toEqual([['stale-token'], ['fresh-verified-token']]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('retries with a fresh token if the immediate post-reverification request still returns 403 reverification-error', async () => {
    vi.useFakeTimers();
    try {
      const reverificationResponse = () => Response.json({
        clerk_error: {
          type: 'forbidden',
          reason: 'reverification-error',
          metadata: { reverification: { level: 'first_factor', afterMinutes: 10 } },
        },
      }, { status: 403 });

      getToken
        .mockResolvedValueOnce('token-before')
        .mockResolvedValueOnce('token-raced')
        .mockResolvedValueOnce('token-fresh');
      openReverification.mockImplementation((props) => props?.afterVerification?.({}));
      const fetchRequest = vi.fn<(token: string) => Promise<Response>>()
        .mockResolvedValueOnce(reverificationResponse())
        .mockResolvedValueOnce(reverificationResponse())
        .mockResolvedValueOnce(new Response(null, { status: 200 }));
      const { result } = renderHook(() => useStepUpRequest(fetchRequest), { wrapper });

      const pending = result.current();
      await vi.runAllTimersAsync();
      const response = await pending;

      expect(response.status).toBe(200);
      expect(fetchRequest.mock.calls).toEqual([['token-before'], ['token-raced'], ['token-fresh']]);
      expect(getToken.mock.calls).toEqual([[{ skipCache: true }], [{ skipCache: true }], [{ skipCache: true }]]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('formats a clear step-up error when a reverification-error body reaches the caller', () => {
    expect(stepUpErrorMessage({ clerk_error: { reason: 'reverification-error' } }, 'Could not approve for the client.'))
      .toBe(STEP_UP_INCOMPLETE_MESSAGE);
    expect(stepUpErrorMessage({ error: 'Override reason is required.' }, 'Fallback'))
      .toBe('Override reason is required.');
    expect(stepUpErrorMessage(null, 'Fallback')).toBe('Fallback');
  });
});
