// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Sidebar } from './Sidebar';
const actor = vi.hoisted(() => ({ allowed: true, delegated: false, selectedId: 7, role: 'accountant', access: 'manager', mosa: false, queue: false, otherOpen: false }));
vi.mock('@/hooks/usePortalCounts', () => ({ usePortalCounts: () => null }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({
  user: { role: actor.role, organization_id: 1, client_access_level: actor.access, name: 'Assigned accountant', email: 'accountant@example.test' },
  isAccountant: true, signOut: vi.fn(),
  hasCapability: (capability: string) => actor.allowed && ['manage_own_aire_account_link', 'payroll_operations'].includes(capability),
}) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({
  activeCompanyId: actor.selectedId, companies: [{ id: 9, organization_id: 1, active: true, has_open_employee_verifications: actor.otherOpen }], activeCompany: { id: 7, active: true, client_managed_employee_lifecycle: actor.queue, name: 'Assigned client', payroll_intake_source_types: actor.mosa ? ['mosa_revel'] : [], client_capabilities: actor.delegated ? ['manage_client_configuration', 'manage_client_administration'] : [] }, canViewClientManagement: false,
}) }));
vi.mock('./CompanySwitcher', () => ({ CompanySwitcher: () => null }));
vi.mock('./OrganizationSwitcher', () => ({ OrganizationSwitcher: () => null }));
beforeEach(() => { actor.allowed = true; actor.delegated = false; actor.selectedId = 7; actor.role = 'accountant'; actor.access = 'manager'; actor.mosa = false; actor.queue = false; actor.otherOpen = false; });
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
  it('links to account & security and personal notification settings for staff and clients', () => {
    const onNavigate = vi.fn();
    const view = render(<MemoryRouter><Sidebar onNavigate={onNavigate} /></MemoryRouter>);
    fireEvent.click(screen.getByRole('button', { name: 'Open account menu' }));

    const securityLink = screen.getByRole('link', { name: 'Account & security' });
    expect(securityLink.getAttribute('href')).toBe('/app/account-security');
    expect(screen.getByRole('link', { name: 'Notifications' }).getAttribute('href')).toBe('/app/notifications');

    fireEvent.click(securityLink);
    expect(onNavigate).toHaveBeenCalledTimes(1);

    actor.role = 'client';
    view.rerender(<MemoryRouter><Sidebar onNavigate={onNavigate} /></MemoryRouter>);
    fireEvent.click(screen.getByRole('button', { name: 'Open account menu' }));
    expect(screen.getByRole('link', { name: 'Account & security' }).getAttribute('href')).toBe('/app/account-security');
  });
});


it('highlights only Client Inbox when visiting its route', () => {
  render(<MemoryRouter initialEntries={['/app/client-inbox']}><Sidebar /></MemoryRouter>);
  expect(screen.getByRole('link', { name: 'Home' }).getAttribute('aria-current')).toBeNull();
  expect(screen.getByRole('link', { name: 'Client Inbox' }).getAttribute('aria-current')).toBe('page');
});

it('shows sentence-case client navigation including Pay period files to every portal client', () => {
  actor.role = 'client';
  const view = render(<MemoryRouter><Sidebar /></MemoryRouter>);
  expect(screen.getByRole('link', { name: 'Pay period files' })).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Contact details' })).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Pay periods' })).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Change requests' })).toBeTruthy();
  actor.mosa = true;
  view.rerender(<MemoryRouter><Sidebar /></MemoryRouter>);
  expect(screen.getByRole('link', { name: 'Pay period files' })).toBeTruthy();
});

it('highlights only Contact Details when visiting its route', () => {
  render(<MemoryRouter initialEntries={['/companies/7/employees/contact-details']}><Sidebar /></MemoryRouter>);
  expect(screen.getByRole('link', { name: 'Employees' }).getAttribute('aria-current')).toBeNull();
  expect(screen.getByRole('link', { name: 'Contact Details' }).getAttribute('aria-current')).toBe('page');
});

it('hides the command shortcut badge on mobile viewports', () => {
  render(<MemoryRouter><Sidebar onOpenCommandPalette={vi.fn()} /></MemoryRouter>);
  const commandButton = screen.getByRole('button', { name: 'Open command menu' });
  const shortcutBadge = commandButton.querySelector('span.ml-auto');
  expect(shortcutBadge?.className).toContain('hidden');
  expect(shortcutBadge?.className).toContain('lg:inline-flex');
});

it.each(['manager', 'viewer'])('shows client branding navigation only to a %s', (access) => {
  actor.role = 'client';
  actor.access = access;
  render(<MemoryRouter><Sidebar /></MemoryRouter>);
  expect(Boolean(screen.queryByRole('link', { name: 'Employee app branding & help' }))).toBe(access === 'manager');
  expect(screen.getByText(access === 'manager' ? 'Client manager' : 'Client viewer')).toBeTruthy();
});

it('keeps To verify dormant and exposes it to payroll operators when a client is active or has open work', () => {
  const view = render(<MemoryRouter><Sidebar /></MemoryRouter>);
  expect(screen.queryByRole('link', { name: 'To verify' })).toBeNull();
  actor.otherOpen = true;
  view.rerender(<MemoryRouter><Sidebar /></MemoryRouter>);
  expect(screen.getByRole('link', { name: 'To verify' }).getAttribute('href')).toBe('/companies/9/verifications');
  actor.queue = true;
  view.rerender(<MemoryRouter><Sidebar /></MemoryRouter>);
  expect(screen.getByRole('link', { name: 'To verify' }).getAttribute('href')).toBe('/companies/7/verifications');
  actor.role = 'client';
  view.rerender(<MemoryRouter><Sidebar /></MemoryRouter>);
  expect(screen.queryByRole('link', { name: 'To verify' })).toBeNull();
});
