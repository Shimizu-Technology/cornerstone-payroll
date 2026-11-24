import { useAuth, useReverification } from '@clerk/react';

/** Pass a request factory so Clerk can retry it with a fresh session token. */
export function useStepUpRequest<Args extends unknown[]>(
  request: (token: string, ...args: Args) => Promise<Response>,
): (...args: Args) => Promise<Response> {
  const { getToken } = useAuth();
  const send = useReverification(async (...args: Args) => {
    const token = await getToken({ skipCache: true });
    if (!token) throw new Error('A signed-in session is required.');

    const response = await request(token, ...args);
    if (response.status !== 403) return { response };

    const hint = await response.clone().json().catch(() => null);
    return { response, clerk_error: hint?.clerk_error };
  });

  return async (...args) => (await send(...args)).response;
}
