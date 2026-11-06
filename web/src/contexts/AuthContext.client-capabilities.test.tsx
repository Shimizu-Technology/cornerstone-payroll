// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { AuthProvider, useAuth } from './AuthContext';
const mocks = vi.hoisted(() => ({ me: vi.fn() }));
vi.mock('@/services/api', () => ({
  authApi: { me: mocks.me }, setAuthToken: vi.fn(), setAuthTokenProvider: vi.fn(), ApiError: class extends Error {},
}));
function Probe() {
  const { user, isAdmin, isManager, hasCapability } = useAuth();
  return <output>{JSON.stringify({ role: user?.role, isAdmin, isManager, global: hasCapability('manage_client_configuration'), clients: user?.company_capabilities })}</output>;
}
afterEach(cleanup);
it('retains per-company grants without changing accountant role, manager/admin flags, or global capabilities', async () => {
  mocks.me.mockResolvedValue({ user: {
    id: 2, role: 'accountant', name: 'Synthetic accountant', email: 'synthetic@example.invalid',
    capabilities: ['payroll_operations'], company_capabilities: { 10: ['manage_client_configuration'], 20: [] },
  } });
  render(<AuthProvider><Probe /></AuthProvider>);
  const result = await screen.findByText(/"role":"accountant"/);
  expect(JSON.parse(result.textContent!)).toEqual({ role: 'accountant', isAdmin: false, isManager: false, global: false, clients: { 10: ['manage_client_configuration'], 20: [] } });
});
