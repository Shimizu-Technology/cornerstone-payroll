// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { apiClient, ApiError, authApi, setAuthTokenProvider } from '@/services/api';

const clerk = vi.hoisted(() => ({
  getToken: vi.fn().mockResolvedValue('synthetic-token'),
  signOut: vi.fn().mockResolvedValue(undefined),
  openUserProfile: vi.fn(),
}));
vi.mock('@clerk/clerk-react', () => ({
  useAuth: () => ({ isSignedIn: true, isLoaded: true, getToken: clerk.getToken, signOut: clerk.signOut }),
  useClerk: () => ({ openUserProfile: clerk.openUserProfile }),
  SignIn: () => <div data-testid="clerk-sign-in" />,
  SignedOut: () => null,
}));

const account = {
  user: {
    id: 1, name: 'Payroll User', email: 'payroll@example.test', role: 'admin', organization_id: 1,
    company_id: 1, company_name: 'Payroll QA', home_company_id: 1, assigned_company_ids: [1], capabilities: [],
  },
};
const mfaPending = { mfa_required: true, mfa_verified: false } as const;
const requiredTitle = 'Multi-factor authentication required';

afterEach(() => {
  cleanup();
  setAuthTokenProvider(null);
  vi.restoreAllMocks();
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

async function renderLogin() {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { AuthProvider } = await import('./AuthContext');
  const { Login } = await import('@/pages/Login');
  render(
    <MemoryRouter initialEntries={['/login']}>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route path="/app" element={<h1>Payroll workspace</h1>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

it('opens Clerk account security, keeps the session on denial, and retries with a fresh token only on demand', async () => {
  const me = vi.spyOn(authApi, 'me')
    .mockResolvedValueOnce(mfaPending)
    .mockResolvedValueOnce(mfaPending)
    .mockResolvedValueOnce({ ...account, mfa_required: true, mfa_verified: true });
  await renderLogin();

  expect(await screen.findByRole('heading', { name: requiredTitle })).toBeTruthy();
  expect(screen.queryByTestId('clerk-sign-in')).toBeNull();
  expect(clerk.signOut).not.toHaveBeenCalled();
  expect(me).toHaveBeenCalledTimes(1);

  fireEvent.click(screen.getByRole('button', { name: 'Open account settings' }));
  expect(clerk.openUserProfile).toHaveBeenCalledTimes(1);
  expect(me).toHaveBeenCalledTimes(1);

  fireEvent.click(screen.getByRole('button', { name: 'Check verification' }));
  await waitFor(() => expect(clerk.getToken).toHaveBeenLastCalledWith({ skipCache: true }));
  await waitFor(() => expect((screen.getByRole('button', { name: 'Check verification' }) as HTMLButtonElement).disabled).toBe(false));
  expect(screen.getByRole('heading', { name: requiredTitle })).toBeTruthy();

  fireEvent.click(screen.getByRole('button', { name: 'Check verification' }));
  expect(await screen.findByRole('heading', { name: 'Payroll workspace' })).toBeTruthy();
  expect(me).toHaveBeenCalledTimes(3);
  expect(clerk.signOut).not.toHaveBeenCalled();
});

it('offers sign-out and re-authentication for the stable MFA 403 contract', async () => {
  vi.spyOn(authApi, 'me').mockRejectedValue(
    new ApiError('Multi-factor authentication is required before accessing payroll.', 403, undefined, { code: 'mfa_required' }),
  );
  await renderLogin();

  expect(await screen.findByRole('heading', { name: requiredTitle })).toBeTruthy();
  expect(clerk.signOut).not.toHaveBeenCalled();

  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }));
  expect(clerk.signOut).toHaveBeenCalledTimes(1);
});

it('keeps the MFA prompt available when Clerk sign-out fails', async () => {
  clerk.signOut.mockRejectedValueOnce(new Error('Synthetic sign-out failure'));
  vi.spyOn(authApi, 'me').mockResolvedValue(mfaPending);
  await renderLogin();

  await screen.findByRole('heading', { name: requiredTitle });
  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }));

  expect((await screen.findByRole('alert')).textContent).toContain('Could not sign out');
  expect(screen.getByRole('button', { name: 'Sign out' })).toBeTruthy();
});

it('keeps the normal sign-in path when the API switch is off', async () => {
  const me = vi.spyOn(authApi, 'me').mockResolvedValue(account);
  await renderLogin();

  expect(await screen.findByRole('heading', { name: 'Payroll workspace' })).toBeTruthy();
  expect(screen.queryByRole('heading', { name: requiredTitle })).toBeNull();
  expect(clerk.getToken.mock.calls).toEqual([[]]);
  expect(me).toHaveBeenCalledTimes(1);
  expect(clerk.openUserProfile).not.toHaveBeenCalled();
  expect(clerk.signOut).not.toHaveBeenCalled();
});

it('locks an already-loaded account when any API request returns the MFA denial', async () => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { AuthProvider, useAuth } = await import('./AuthContext');
  const me = vi.spyOn(authApi, 'me').mockResolvedValue(account);
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json(
    { code: 'mfa_required', error: 'Multi-factor authentication is required before accessing payroll.' },
    { status: 403 },
  )));

  function Probe() {
    const { isAuthenticated, authProblem } = useAuth();
    return <p>{isAuthenticated ? 'Payroll workspace' : authProblem?.code}</p>;
  }

  render(<AuthProvider><Probe /></AuthProvider>);
  expect(await screen.findByText('Payroll workspace')).toBeTruthy();

  await act(async () => {
    await expect(apiClient.get('/companies')).rejects.toMatchObject({ status: 403, data: { code: 'mfa_required' } });
  });

  expect(screen.getByText('mfa_required')).toBeTruthy();
  expect(me).toHaveBeenCalledTimes(1);
  expect(clerk.signOut).not.toHaveBeenCalled();
});
