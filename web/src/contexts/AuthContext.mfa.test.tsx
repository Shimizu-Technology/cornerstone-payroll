// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import type { ReactNode } from 'react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { apiClient, ApiError, authApi, setAuthTokenProvider } from '@/services/api';

const clerk = vi.hoisted(() => ({
  getToken: vi.fn<(options?: { skipCache: boolean }) => Promise<string>>(),
  isSignedIn: true,
  signOut: vi.fn().mockResolvedValue(undefined),
  openUserProfile: vi.fn(),
  sessionReload: vi.fn().mockResolvedValue(undefined),
}));
vi.mock('@clerk/react', () => ({
  useAuth: () => ({ isSignedIn: clerk.isSignedIn, isLoaded: true, getToken: clerk.getToken, signOut: clerk.signOut }),
  useClerk: () => ({ openUserProfile: clerk.openUserProfile, session: { reload: clerk.sessionReload } }),
  SignIn: () => <div data-testid="clerk-sign-in" />,
  Show: ({ when, children }: { when: string; children: ReactNode }) => (when === 'signed-out' && !clerk.isSignedIn ? children : null),
}));

const account = {
  user: {
    id: 1, name: 'Payroll User', email: 'payroll@example.test', role: 'admin', organization_id: 1,
    company_id: 1, company_name: 'Payroll QA', home_company_id: 1, assigned_company_ids: [1], capabilities: [],
  },
};
// The /auth/me bootstrap for each MFA denial, as the API sends it.
const mfaSetup = {
  mfa_required: true, mfa_verified: false, code: 'mfa_enrollment_required', error: 'Set up two-step sign-in before accessing payroll.',
} as const;
const mfaSignIn = {
  mfa_required: true, mfa_verified: false, code: 'mfa_required', error: 'Multi-factor authentication is required before accessing payroll.',
} as const;
const setupTitle = 'Set up two-step sign-in';
const signInTitle = 'Finish two-step sign-in';

beforeEach(() => {
  clerk.isSignedIn = true;
  clerk.getToken.mockReset().mockImplementation(async (options) => options?.skipCache ? 'fresh-token' : 'cached-token');
  clerk.sessionReload.mockReset().mockResolvedValue(undefined);
});

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
  const ui = () => (
    <MemoryRouter initialEntries={['/login']}>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route path="/app" element={<h1>Payroll workspace</h1>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>
  );
  const { rerender } = render(ui());
  return () => rerender(ui());
}

it('opens Clerk account security, keeps the session on denial, and retries with a fresh token only on demand', async () => {
  const fetch = vi.fn<typeof globalThis.fetch>()
    .mockResolvedValueOnce(Response.json(mfaSetup))
    .mockResolvedValueOnce(Response.json(mfaSetup))
    .mockResolvedValueOnce(Response.json({ ...account, mfa_required: true, mfa_verified: true }));
  vi.stubGlobal('fetch', fetch);
  await renderLogin();

  expect(await screen.findByRole('heading', { name: setupTitle })).toBeTruthy();
  expect(screen.getAllByText(/authenticator app/i).length).toBeGreaterThan(0);
  expect(screen.getByText(/Save your backup codes/i)).toBeTruthy();
  expect(screen.getByText(/Ask your Cornerstone administrator/i)).toBeTruthy();
  expect(screen.queryByTestId('clerk-sign-in')).toBeNull();
  expect(clerk.signOut).not.toHaveBeenCalled();
  expect(fetch).toHaveBeenCalledExactlyOnceWith(
    expect.stringMatching(/\/auth\/me$/),
    expect.objectContaining({ headers: expect.objectContaining({ Authorization: 'Bearer cached-token' }) }),
  );

  fireEvent.click(screen.getByRole('button', { name: 'Open account settings' }));
  expect(clerk.openUserProfile).toHaveBeenCalledTimes(1);
  expect(screen.getByRole('status').textContent).toMatch(/Finished adding your authenticator app/i);
  expect(fetch).toHaveBeenCalledTimes(1);

  clerk.getToken.mockClear();
  fireEvent.click(screen.getByRole('button', { name: 'Check verification' }));
  await waitFor(() => expect((screen.getByRole('button', { name: 'Check verification' }) as HTMLButtonElement).disabled).toBe(false));
  expect(clerk.sessionReload).toHaveBeenCalledTimes(1);
  expect(screen.getByRole('heading', { name: setupTitle })).toBeTruthy();
  expect(screen.getByRole('status').textContent).toMatch(/still needs a fresh two-step check/i);
  expect(screen.getByRole('button', { name: 'Sign out and sign back in' })).toBeTruthy();

  fireEvent.click(screen.getByRole('button', { name: 'Check verification' }));
  expect(await screen.findByRole('heading', { name: 'Payroll workspace' })).toBeTruthy();
  expect(clerk.sessionReload).toHaveBeenCalledTimes(2);
  expect(fetch).toHaveBeenCalledTimes(3);
  expect(fetch.mock.calls.slice(1).map(([, init]) => new Headers(init?.headers).get('Authorization')))
    .toEqual(['Bearer fresh-token', 'Bearer fresh-token']);
  expect(clerk.getToken.mock.calls).toEqual([[{ skipCache: true }], [{ skipCache: true }]]);
  expect(clerk.signOut).not.toHaveBeenCalled();
});

it('asks an enrolled login to sign in again for the stable mfa_required 403', async () => {
  vi.spyOn(authApi, 'me').mockRejectedValue(
    new ApiError('Multi-factor authentication is required before accessing payroll.', 403, undefined, { code: 'mfa_required' }),
  );
  await renderLogin();

  expect(await screen.findByRole('heading', { name: signInTitle })).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Open account settings' })).toBeNull();
  expect(clerk.signOut).not.toHaveBeenCalled();

  fireEvent.click(screen.getByRole('button', { name: 'Sign out and sign back in' }));
  expect(clerk.signOut).toHaveBeenCalledTimes(1);
});

it('shows the authenticator setup steps when the API returns mfa_enrollment_required', async () => {
  vi.spyOn(authApi, 'me').mockRejectedValue(
    new ApiError('Set up two-step sign-in to make this change.', 403, undefined, { code: 'mfa_enrollment_required' }),
  );
  await renderLogin();

  expect(await screen.findByRole('heading', { name: setupTitle })).toBeTruthy();
  expect(screen.getAllByText(/authenticator app/i).length).toBeGreaterThan(0);
  expect(screen.getByText(/Ask your Cornerstone administrator/i)).toBeTruthy();
  expect(clerk.signOut).not.toHaveBeenCalled();
});

it('keeps the MFA prompt available when Clerk sign-out fails', async () => {
  clerk.signOut.mockRejectedValueOnce(new Error('Synthetic sign-out failure'));
  vi.spyOn(authApi, 'me').mockResolvedValue(mfaSetup);
  await renderLogin();

  await screen.findByRole('heading', { name: setupTitle });
  fireEvent.click(screen.getByRole('button', { name: 'Sign out and sign back in' }));

  expect((await screen.findByRole('alert')).textContent).toContain('Could not sign out');
  expect(screen.getByRole('button', { name: 'Sign out and sign back in' })).toBeTruthy();
});

it('clears the MFA prompt when the user signs out of Clerk elsewhere', async () => {
  vi.spyOn(authApi, 'me').mockResolvedValue(mfaSetup);
  const rerender = await renderLogin();
  await screen.findByRole('heading', { name: setupTitle });

  clerk.isSignedIn = false;
  rerender();

  expect(await screen.findByTestId('clerk-sign-in')).toBeTruthy();
  await waitFor(() => expect(screen.queryByRole('heading', { name: setupTitle })).toBeNull());
});

it('keeps the 401 account notice after Clerk signs out', async () => {
  vi.spyOn(authApi, 'me').mockRejectedValue(new ApiError('Synthetic unlinked account', 401));
  const rerender = await renderLogin();
  await screen.findByRole('alert');

  clerk.isSignedIn = false;
  rerender();

  expect(await screen.findByTestId('clerk-sign-in')).toBeTruthy();
  expect(screen.getByRole('alert').textContent).toContain('Synthetic unlinked account');
});

it('clears a user restored by a concurrent refresh when MFA sign-out fails', async () => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { AuthProvider, useAuth } = await import('./AuthContext');
  let rejectSignOut!: (error: Error) => void;
  const signingOut = new Promise<void>((_, reject) => { rejectSignOut = reject; });
  clerk.signOut.mockReturnValueOnce(signingOut);
  vi.spyOn(authApi, 'me').mockResolvedValueOnce(mfaSignIn).mockResolvedValue(account);

  function Probe() {
    const { isAuthenticated, user, authProblem, refreshUser, signOut } = useAuth();
    return (
      <>
        <p>{isAuthenticated ? 'Signed in' : 'Signed out'}: {user?.name ?? 'No user'}: {authProblem?.code}</p>
        <button onClick={() => { void refreshUser(); }}>Refresh</button>
        <button onClick={() => { void signOut().catch(() => undefined); }}>Sign out</button>
      </>
    );
  }

  render(<AuthProvider><Probe /></AuthProvider>);
  await screen.findByText('Signed out: No user: mfa_required');
  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }));
  fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));
  await screen.findByText('Signed in: Payroll User:');

  await act(async () => rejectSignOut(new Error('Synthetic sign-out failure')));

  expect(screen.getByText('Signed out: No user: mfa_required')).toBeTruthy();
});

it('keeps the normal sign-in path when the API switch is off', async () => {
  const me = vi.spyOn(authApi, 'me').mockResolvedValue(account);
  await renderLogin();

  expect(await screen.findByRole('heading', { name: 'Payroll workspace' })).toBeTruthy();
  expect(screen.queryByRole('heading', { name: setupTitle })).toBeNull();
  expect(clerk.getToken.mock.calls).toEqual([[]]);
  expect(me).toHaveBeenCalledTimes(1);
  expect(clerk.openUserProfile).not.toHaveBeenCalled();
  expect(clerk.signOut).not.toHaveBeenCalled();
});

it.each([
  ['mfa_required', 'Multi-factor authentication is required before accessing payroll.'],
  ['mfa_enrollment_required', 'Set up two-step sign-in to make this change.'],
])('locks an already-loaded account when any API request returns %s', async (code, error) => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { AuthProvider, useAuth } = await import('./AuthContext');
  const me = vi.spyOn(authApi, 'me').mockResolvedValue(account);
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json(
    { code, error },
    { status: 403 },
  )));

  function Probe() {
    const { isAuthenticated, authProblem } = useAuth();
    return <p>{isAuthenticated ? 'Payroll workspace' : authProblem?.code}</p>;
  }

  render(<AuthProvider><Probe /></AuthProvider>);
  expect(await screen.findByText('Payroll workspace')).toBeTruthy();

  await act(async () => {
    await expect(apiClient.get('/companies')).rejects.toMatchObject({ status: 403, data: { code } });
  });

  expect(screen.getByText(code)).toBeTruthy();
  expect(me).toHaveBeenCalledTimes(1);
  expect(clerk.signOut).not.toHaveBeenCalled();
});

it('still force-refreshes the token and guides sign-out when Clerk session reload throws', async () => {
  clerk.sessionReload.mockRejectedValueOnce(new Error('Offline session reload'));
  vi.spyOn(authApi, 'me').mockResolvedValue(mfaSetup);
  await renderLogin();

  await screen.findByRole('heading', { name: setupTitle });
  clerk.getToken.mockClear();
  fireEvent.click(screen.getByRole('button', { name: 'Check verification' }));

  await waitFor(() => expect(screen.getByRole('status').textContent).toMatch(/still needs a fresh two-step check/i));
  expect(clerk.getToken).toHaveBeenCalledWith({ skipCache: true });
});

it('sends an enrolled login that skipped the second step to sign in again, not to add an authenticator', async () => {
  vi.spyOn(authApi, 'me').mockResolvedValue(mfaSignIn);
  await renderLogin();

  expect(await screen.findByRole('heading', { name: signInTitle })).toBeTruthy();
  expect(screen.queryByRole('heading', { name: setupTitle })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Open account settings' })).toBeNull();
  expect(screen.queryByText(/Save your backup codes/i)).toBeNull();
  expect(screen.getByText(/enter the 6-digit code from your authenticator app, or one of your backup codes/i)).toBeTruthy();

  fireEvent.click(screen.getByRole('button', { name: 'Check verification' }));
  await waitFor(() => expect(screen.getByRole('status').textContent).toMatch(/still hasn.t finished two-step sign-in/i));
  expect(clerk.sessionReload).toHaveBeenCalledTimes(1);

  fireEvent.click(screen.getByRole('button', { name: 'Sign out and sign back in' }));
  expect(clerk.signOut).toHaveBeenCalledTimes(1);
  expect(clerk.openUserProfile).not.toHaveBeenCalled();
});

it.each([
  [mfaSetup, 'mfa_enrollment_required', 'Set up two-step sign-in before accessing payroll.'],
  [mfaSignIn, 'mfa_required', 'Multi-factor authentication is required before accessing payroll.'],
  [{ mfa_required: true, mfa_verified: false } as const, 'mfa_required', 'Multi-factor authentication is required before accessing payroll.'],
])('keeps the /auth/me denial code and message in the auth problem (%o)', async (body, code, message) => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { AuthProvider, useAuth } = await import('./AuthContext');
  vi.spyOn(authApi, 'me').mockResolvedValue(body);

  function Probe() {
    const { authProblem } = useAuth();
    return <p>{authProblem ? `${authProblem.status} ${authProblem.code}: ${authProblem.message}` : 'none'}</p>;
  }

  render(<AuthProvider><Probe /></AuthProvider>);
  expect(await screen.findByText(`403 ${code}: ${message}`)).toBeTruthy();
});
