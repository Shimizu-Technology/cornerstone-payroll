// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ApiError, authApi } from '@/services/api';

const clerk = vi.hoisted(() => ({
  getToken: vi.fn().mockResolvedValue('synthetic-token'),
  signOut: vi.fn().mockRejectedValue(new Error('Synthetic sign-out failure')),
}));
vi.mock('@clerk/clerk-react', () => ({
  useAuth: () => ({ isSignedIn: true, isLoaded: true, ...clerk }),
}));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

it('keeps an unbound account denied without repeating checks or sign-out', async () => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { AuthProvider, useAuth } = await import('./AuthContext');
  const me = vi.spyOn(authApi, 'me').mockRejectedValue(
    new ApiError('This Clerk account is not linked to Payroll', 401, undefined, { code: 'payroll_account_unbound' }),
  );
  function Probe() {
    const { authProblem, isAuthenticated, refreshUser } = useAuth();
    return <button onClick={() => { void refreshUser(); }}>{isAuthenticated ? 'Signed in' : authProblem?.code}</button>;
  }

  render(<AuthProvider><Probe /></AuthProvider>);

  const denied = await screen.findByRole('button', { name: 'payroll_account_unbound' });
  fireEvent.click(denied);
  await waitFor(() => expect(clerk.signOut).toHaveBeenCalledTimes(1));
  expect(me).toHaveBeenCalledTimes(1);
});
