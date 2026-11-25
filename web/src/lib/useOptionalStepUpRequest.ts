import { useCallback } from 'react';
import { useStepUpRequest } from '@/lib/useStepUpRequest';

const clerkConfigured = Boolean(import.meta.env.VITE_CLERK_PUBLISHABLE_KEY);

/**
 * useStepUpRequest when Clerk is configured. In local development without
 * Clerk (auth off), the request goes out without a token and no step-up
 * prompt. The choice is fixed per build, so hook order never changes.
 */
function useDevRequest<Args extends unknown[]>(
  request: (token: string, ...args: Args) => Promise<Response>,
): (...args: Args) => Promise<Response> {
  return useCallback((...args: Args) => request('', ...args), [request]);
}

export const useOptionalStepUpRequest: typeof useStepUpRequest = clerkConfigured ? useStepUpRequest : useDevRequest;
