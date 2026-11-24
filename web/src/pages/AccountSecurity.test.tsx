// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

const userProfileProps = vi.hoisted(() => ({ last: null as Record<string, unknown> | null }));
vi.mock('@clerk/react', () => ({
  UserProfile: (props: Record<string, unknown>) => {
    userProfileProps.last = props;
    return <div data-testid="clerk-user-profile">Clerk UserProfile</div>;
  },
}));
vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({
    user: { id: 1, name: 'Payroll Staff', email: 'staff@example.test', role: 'accountant' },
  }),
}));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompany: { id: 1, name: 'Test Company' } }),
}));

afterEach(() => {
  cleanup();
  userProfileProps.last = null;
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe('AccountSecurity', () => {
  it('mounts Clerk UserProfile inside the app with authenticator and backup-code guidance', async () => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_synthetic');
    const { AccountSecurity } = await import('./AccountSecurity');

    render(<AccountSecurity />);

    expect(screen.getByRole('heading', { name: 'Account & security' })).toBeTruthy();
    expect(screen.getByTestId('clerk-user-profile')).toBeTruthy();
    expect(userProfileProps.last?.routing).toBe('hash');
    expect(screen.getAllByText(/authenticator app/i).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/backup codes/i).length).toBeGreaterThan(0);
    expect(screen.getByText(/Ask your Cornerstone administrator/i)).toBeTruthy();
  });

  it('shows a local-development fallback when Clerk is not configured', async () => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '');
    const { AccountSecurity } = await import('./AccountSecurity');

    render(<AccountSecurity />);

    expect(screen.getByRole('heading', { name: 'Account & security' })).toBeTruthy();
    expect(screen.queryByTestId('clerk-user-profile')).toBeNull();
    expect(screen.getByText(/Clerk is not enabled in this local development session/i)).toBeTruthy();
    expect(screen.getByText(/Payroll Staff/)).toBeTruthy();
  });
});
