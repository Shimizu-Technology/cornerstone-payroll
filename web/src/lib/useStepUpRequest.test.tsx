/** @vitest-environment jsdom */
import { ClerkInstanceContext } from '@clerk/shared/react';
import { renderHook } from '@testing-library/react';
import type { ContextType, PropsWithChildren } from 'react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useStepUpRequest } from './useStepUpRequest';

const { getToken } = vi.hoisted(() => ({ getToken: vi.fn() }));

vi.mock('@clerk/react', async (importOriginal) => ({
  ...await importOriginal<typeof import('@clerk/react')>(),
  useAuth: () => ({ getToken }),
}));

type Clerk = NonNullable<ContextType<typeof ClerkInstanceContext>>['value'];
const openReverification = vi.fn<Clerk['__internal_openReverification']>();
const clerk = { __internal_openReverification: openReverification } as unknown as Clerk;

function wrapper({ children }: PropsWithChildren) {
  return <ClerkInstanceContext.Provider value={{ value: clerk }}>{children}</ClerkInstanceContext.Provider>;
}

beforeEach(() => {
  getToken.mockReset().mockResolvedValue('initial-token');
  openReverification.mockReset();
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
});
