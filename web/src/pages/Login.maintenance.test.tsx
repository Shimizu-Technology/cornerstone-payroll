// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes, useLocation } from 'react-router';
import type { ReactNode } from 'react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const clerk = vi.hoisted(() => ({ isSignedIn: true }));
vi.mock('@clerk/react', () => ({
  SignIn: () => <div data-testid="clerk-sign-in" />,
  SignUp: ({ forceRedirectUrl }: { forceRedirectUrl: string }) => {
    const { search } = useLocation();
    return <div data-testid="clerk-sign-up" data-redirect={forceRedirectUrl} data-search={search} />;
  },
  Show: ({ children, fallback }: { children: ReactNode; fallback?: ReactNode }) => clerk.isSignedIn ? fallback : children,
  useUser: () => ({ user: { primaryEmailAddress: { emailAddress: 'other-account@example.test' } } }),
  useClerk: () => ({ openUserProfile: () => undefined }),
}));

const auth = vi.hoisted(() => ({
  isAuthenticated: false,
  isLoading: false,
  authProblem: { status: 503, code: 'write_maintenance', message: 'Payroll is in a short maintenance window.' } as unknown,
  refreshUser: vi.fn().mockResolvedValue(undefined),
  signOut: vi.fn(),
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => auth }));
vi.mock('@/components/auth/AccountAccessNotice', () => ({
  AccountAccessNotice: () => <div role="status">maintenance notice</div>,
}));

beforeEach(() => {
  clerk.isSignedIn = false;
  auth.isAuthenticated = false;
  auth.authProblem = null;
  auth.signOut.mockReset().mockResolvedValue(undefined);
});

afterEach(() => {
  cleanup();
  vi.unstubAllEnvs();
  vi.resetModules();
});

async function renderLogin(search = '') {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { Login } = await import('./Login');
  render(
    <MemoryRouter initialEntries={[`/login${search}`]}>
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route path="/app" element={<h1>Payroll workspace</h1>} />
      </Routes>
    </MemoryRouter>,
  );
}

it('keeps the maintenance notice without mounting SignIn while Clerk is still signed in', async () => {
  clerk.isSignedIn = true;
  auth.authProblem = { status: 503, code: 'write_maintenance', message: 'Payroll is in a short maintenance window.' };
  await renderLogin('?__clerk_status=complete');
  expect(screen.getByRole('status').textContent).toContain('maintenance notice');
  expect(screen.queryByTestId('clerk-sign-in')).toBeNull();
});

it.each([
  ['ordinary sign-in', ''],
  ['an existing account invitation', '?__clerk_status=sign_in&__clerk_ticket=fake-ticket'],
  ['a completed invitation without an active session', '?__clerk_status=complete'],
  ['a sign-up status without a ticket', '?__clerk_status=sign_up'],
])('shows SignIn for %s', async (_label, search) => {
  await renderLogin(search);
  expect(screen.getByTestId('clerk-sign-in')).toBeTruthy();
  expect(screen.queryByTestId('clerk-sign-up')).toBeNull();
  expect(Boolean(screen.queryByText(/Invitation links work once and expire/))).toBe(search.includes('__clerk_ticket'));
});

it('opens Clerk sign-up in place for a new invitee and preserves the ticket', async () => {
  const search = '?__clerk_status=sign_up&__clerk_ticket=fake-ticket';
  await renderLogin(search);

  const form = screen.getByTestId('clerk-sign-up');
  expect(form.getAttribute('data-search')).toBe(search);
  expect(form.getAttribute('data-redirect')).toBe('/app');
  expect(screen.queryByTestId('clerk-sign-in')).toBeNull();
  expect(screen.getByText(/ask Cornerstone to resend your invitation/)).toBeTruthy();
});

it('opens the workspace when the invitation has already produced an authenticated session', async () => {
  clerk.isSignedIn = true;
  auth.isAuthenticated = true;
  await renderLogin('?__clerk_status=complete');

  expect(screen.getByRole('heading', { name: 'Payroll workspace' })).toBeTruthy();
  expect(screen.queryByTestId('clerk-sign-in')).toBeNull();
});

it('asks the signed-in Clerk user to sign out and keeps the invitation URL', async () => {
  clerk.isSignedIn = true;
  auth.isAuthenticated = true;
  auth.signOut.mockRejectedValueOnce(new Error('Synthetic sign-out failure'));
  const search = '?__clerk_status=sign_up&__clerk_ticket=fake-ticket';
  await renderLogin(search);

  expect(screen.getByRole('heading', { name: 'You’re signed in as other-account@example.test.' })).toBeTruthy();
  expect(screen.getByText('Sign out to accept this invitation.')).toBeTruthy();
  expect(screen.queryByRole('heading', { name: 'Payroll workspace' })).toBeNull();
  expect(screen.queryByTestId('clerk-sign-up')).toBeNull();

  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }));
  expect(await screen.findByText('Could not sign out. Try again.')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }));

  await waitFor(() => expect(screen.queryByText('Could not sign out. Try again.')).toBeNull());
  expect(auth.signOut.mock.calls).toEqual([[{ redirectUrl: `/login${search}` }], [{ redirectUrl: `/login${search}` }]]);
});

it('keeps the access notice for a signed-in invitee alongside the sign-out prompt', async () => {
  clerk.isSignedIn = true;
  auth.authProblem = { status: 503, code: 'write_maintenance', message: 'Payroll is in a short maintenance window.' };
  await renderLogin('?__clerk_status=sign_up&__clerk_ticket=fake-ticket');

  expect(screen.getByRole('status').textContent).toContain('maintenance notice');
  expect(screen.getByText('Sign out to accept this invitation.')).toBeTruthy();
});

it('links to the privacy policy and terms from the sign-in card', async () => {
  await renderLogin();
  expect(screen.getByRole('link', { name: 'Privacy Policy' }).getAttribute('href')).toBe('/privacy');
  expect(screen.getByRole('link', { name: 'Terms of Service' }).getAttribute('href')).toBe('/terms');
});
