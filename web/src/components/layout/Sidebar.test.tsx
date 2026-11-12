// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Sidebar } from './Sidebar';
const actor = vi.hoisted(() => ({ allowed: true, delegated: false, selectedId: 7 }));
vi.mock('@/hooks/usePortalCounts', () => ({ usePortalCounts: () => null }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({
  user: { role: 'accountant', name: 'Assigned accountant', email: 'accountant@example.test' },
  isAccountant: true, signOut: vi.fn(),
  hasCapability: (capability: string) => actor.allowed && capability === 'manage_own_aire_account_link',
}) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({
  activeCompanyId: actor.selectedId, activeCompany: { id: 7, name: 'Assigned client', client_capabilities: actor.delegated ? ['manage_client_configuration', 'manage_client_administration'] : [] }, canViewClientManagement: false,
}) }));
vi.mock('./CompanySwitcher', () => ({ CompanySwitcher: () => null }));
vi.mock('./OrganizationSwitcher', () => ({ OrganizationSwitcher: () => null }));
beforeEach(() => { actor.allowed = true; actor.delegated = false; actor.selectedId = 7; });
afterEach(cleanup);
describe('Accountant personal connection navigation', () => {
  it('offers personal connection without source or calendar configuration rights', () => {
    render(<MemoryRouter><Sidebar /></MemoryRouter>);
    expect(screen.getByRole('link', { name: 'Time tracking account' }).getAttribute('href')).toBe('/app/aire-account-connection');
    expect(screen.queryByRole('link', { name: /Time Tracking Sources|Pay Schedule|Payroll Fields/ })).toBeNull();
  });
  it('hides personal connection when the server does not grant its capability', () => {
    actor.allowed = false;
    render(<MemoryRouter><Sidebar /></MemoryRouter>);
    expect(screen.queryByRole('link', { name: 'Time tracking account' })).toBeNull();
  });
  it('offers selected-client settings after a grant while keeping Users, tax and source credentials restricted', () => {
    actor.delegated = true;
    const view = render(<MemoryRouter><Sidebar /></MemoryRouter>);
    expect(screen.getByRole('link', { name: 'Pay Schedule' })).toBeTruthy();
    expect(screen.queryByRole('link', { name: /Time Tracking Sources|Users|Tax Configuration/ })).toBeNull();
    actor.selectedId = 8;
    view.rerender(<MemoryRouter><Sidebar /></MemoryRouter>);
    expect(screen.queryByRole('link', { name: 'Pay Schedule' })).toBeNull();
  });

});

describe('Account menu', () => {
  it('links to personal notification settings', () => {
    render(<MemoryRouter><Sidebar /></MemoryRouter>);
    fireEvent.click(screen.getByRole('button', { name: 'Open account menu' }));
    expect(screen.getByRole('link', { name: 'Notifications' }).getAttribute('href')).toBe('/app/notifications');
  });
});


it('highlights only Client Inbox when visiting its route', () => {
  render(<MemoryRouter initialEntries={['/app/client-inbox']}><Sidebar /></MemoryRouter>);
  expect(screen.getByRole('link', { name: 'Dashboard' }).getAttribute('aria-current')).toBeNull();
  expect(screen.getByRole('link', { name: 'Client Inbox' }).getAttribute('aria-current')).toBe('page');
});
