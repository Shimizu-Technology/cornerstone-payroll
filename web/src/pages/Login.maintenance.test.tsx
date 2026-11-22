// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import type { ReactNode } from 'react';
import { afterEach, expect, it, vi } from 'vitest';

const clerk = vi.hoisted(() => ({ isSignedIn: true }));
vi.mock('@clerk/clerk-react', () => ({
  SignIn: () => <div data-testid="clerk-sign-in" />,
  SignedOut: ({ children }: { children: ReactNode }) => (clerk.isSignedIn ? null : <>{children}</>),
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

afterEach(() => {
  cleanup();
  vi.unstubAllEnvs();
  vi.resetModules();
});

async function renderLogin() {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
  const { Login } = await import('./Login');
  render(<MemoryRouter><Login /></MemoryRouter>);
}

it('keeps the maintenance notice without mounting SignIn while Clerk is still signed in', async () => {
  clerk.isSignedIn = true;
  await renderLogin();
  expect(screen.getByRole('status').textContent).toContain('maintenance notice');
  expect(screen.queryByTestId('clerk-sign-in')).toBeNull();
});

it('shows SignIn when Clerk is signed out', async () => {
  clerk.isSignedIn = false;
  await renderLogin();
  expect(screen.getByTestId('clerk-sign-in')).toBeTruthy();
});
