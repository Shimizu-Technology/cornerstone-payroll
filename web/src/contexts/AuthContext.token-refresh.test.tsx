// @vitest-environment jsdom
import { act, cleanup, render } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const clerk = vi.hoisted(() => ({ getToken: vi.fn<() => Promise<string>>(), signOut: vi.fn() }));
vi.mock('@clerk/react', () => ({
  useAuth: () => ({ isSignedIn: true, isLoaded: true, getToken: clerk.getToken, signOut: clerk.signOut }),
}));

const api = vi.hoisted(() => ({ setAuthToken: vi.fn(), me: vi.fn() }));
vi.mock('@/services/api', () => ({
  authApi: { me: api.me },
  setAuthToken: api.setAuthToken,
  setAuthTokenProvider: vi.fn(),
  ApiError: class extends Error { status = 0; },
  MFA_REQUIRED_EVENT: 'payroll:mfa-required',
}));

beforeEach(() => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  api.me.mockResolvedValue({ user: { id: 1, role: 'admin', name: 'Payroll User', email: 'payroll@example.test', capabilities: [] } });
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  vi.resetModules();
  vi.clearAllMocks();
});

it('keeps refreshing the token after an offline rejection', async () => {
  // Capture the 50-second refresh tick so each tick can be run on demand.
  let refreshTick: (() => Promise<void>) | undefined;
  const realSetInterval = globalThis.setInterval;
  vi.spyOn(globalThis, 'setInterval').mockImplementation(((handler: () => Promise<void>, ms?: number) => {
    if (ms === 50000) {
      refreshTick = handler;
      return 0 as unknown as ReturnType<typeof setInterval>;
    }
    return realSetInterval(handler, ms);
  }) as typeof setInterval);

  clerk.getToken.mockResolvedValue('initial-token');
  const { AuthProvider } = await import('./AuthContext');
  render(<AuthProvider><span /></AuthProvider>);
  await act(async () => { await Promise.resolve(); });
  expect(refreshTick).toBeDefined();
  api.setAuthToken.mockClear();

  const offline = Object.assign(new Error('Network offline'), { name: 'ClerkOfflineError' });
  clerk.getToken.mockRejectedValueOnce(offline).mockResolvedValueOnce('refreshed-token');

  await expect(refreshTick!()).resolves.toBeUndefined();
  expect(api.setAuthToken).not.toHaveBeenCalled();

  await refreshTick!();
  expect(api.setAuthToken).toHaveBeenCalledWith('refreshed-token');
});
