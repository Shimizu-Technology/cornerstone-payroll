// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ApiError, authApi } from '@/services/api';

const clerk = vi.hoisted(() => ({
  getToken: vi.fn().mockResolvedValue('synthetic-token'),
  signOut: vi.fn(),
}));
vi.mock('@clerk/clerk-react', () => ({
  useAuth: () => ({ isSignedIn: true, isLoaded: true, ...clerk }),
}));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

function UnboundProbe({ useAuth }: { useAuth: typeof import('./AuthContext').useAuth }) {
  const { authProblem, isAuthenticated, refreshUser } = useAuth();
  return (
    <button onClick={() => { void refreshUser(); }}>
      {isAuthenticated ? 'Signed in' : authProblem?.signOutFailed ? 'Retry sign-out' : authProblem?.code}
    </button>
  );
}

it('keeps an unbound account denied without repeating checks after a successful sign-out', async () => {
  clerk.signOut.mockReset().mockResolvedValue(undefined);
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { AuthProvider, useAuth } = await import('./AuthContext');
  const me = vi.spyOn(authApi, 'me').mockRejectedValue(
    new ApiError('This Clerk account is not linked to Payroll', 401, undefined, { code: 'payroll_account_unbound' }),
  );

  render(<AuthProvider><UnboundProbe useAuth={useAuth} /></AuthProvider>);

  fireEvent.click(await screen.findByRole('button', { name: 'payroll_account_unbound' }));
  expect(clerk.signOut).toHaveBeenCalledTimes(1);
  expect(me).toHaveBeenCalledTimes(1);
});

it('allows a retry when Clerk sign-out fails', async () => {
  clerk.signOut.mockReset().mockRejectedValueOnce(new Error('Synthetic sign-out failure')).mockResolvedValue(undefined);
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { AuthProvider, useAuth } = await import('./AuthContext');
  const me = vi.spyOn(authApi, 'me').mockRejectedValue(
    new ApiError('This Clerk account is not linked to Payroll', 401, undefined, { code: 'payroll_account_unbound' }),
  );

  render(<AuthProvider><UnboundProbe useAuth={useAuth} /></AuthProvider>);

  fireEvent.click(await screen.findByRole('button', { name: 'Retry sign-out' }));
  await waitFor(() => expect(clerk.signOut).toHaveBeenCalledTimes(2));
  expect(me).toHaveBeenCalledTimes(2);
  expect(screen.queryByRole('button', { name: 'Signed in' })).toBeNull();
});


it('keeps the Clerk sign-in intact and allows a retry when invitation binding is paused', async () => {
  clerk.signOut.mockClear();
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { AuthProvider, useAuth } = await import('./AuthContext');
  const me = vi.spyOn(authApi, 'me').mockRejectedValueOnce(
    new ApiError('Try again shortly', 503, undefined, { code: 'write_maintenance' }),
  ).mockResolvedValue({
    user: { id: 1, name: 'Payroll User', email: 'payroll@example.test', role: 'admin', organization_id: 1, company_id: 1, company_name: 'Payroll QA', home_company_id: 1, assigned_company_ids: [1], capabilities: [] },
  });

  render(<AuthProvider><UnboundProbe useAuth={useAuth} /></AuthProvider>);

  fireEvent.click(await screen.findByRole('button', { name: 'write_maintenance' }));
  expect(await screen.findByRole('button', { name: 'Signed in' })).toBeTruthy();
  expect(clerk.signOut).not.toHaveBeenCalled();
  expect(me).toHaveBeenCalledTimes(2);
});
