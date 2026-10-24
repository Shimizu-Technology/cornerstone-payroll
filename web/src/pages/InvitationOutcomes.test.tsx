// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import type { ReactNode } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Users } from './Users';
import { Organizations } from './Organizations';

const mocks = vi.hoisted(() => ({
  users: { list: vi.fn(), create: vi.fn(), resendInvitation: vi.fn() },
  organizations: { list: vi.fn(), create: vi.fn(), createAdminUser: vi.fn() },
  companies: { list: vi.fn() },
}));
vi.mock('@/services/api', () => ({ usersApi: mocks.users, organizationsApi: mocks.organizations,
  companiesApi: mocks.companies, companyAssignmentsApi: {}, auditLogsApi: {}, ApiError: class extends Error {} }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 1, role: 'super_admin' } }) }));
vi.mock('@/components/layout/Header', () => ({ Header: ({ actions }: { actions?: ReactNode }) => <header>{actions}</header> }));

const invitee = { id: 2, name: 'Synthetic Invitee', email: 'invitee@example.test', role: 'employee', active: true,
  invitation_pending: true, assigned_companies: [], assigned_company_ids: [] };
const organization = { id: 1, name: 'Synthetic Firm', slug: 'synthetic', status: 'active', active: true,
  client_limit: 3, companies_count: 1, active_companies_count: 1, users_count: 1, org_admins: [] };
const outcomes = [
  ['captured', 'Captured in staging (not sent)'],
  ['queued', 'Invitation queued'],
  ['submitted', 'Invitation submitted to the email provider'],
  ['failed', 'Invitation email failed'],
] as const;

beforeEach(() => {
  vi.resetAllMocks();
  mocks.users.list.mockResolvedValue({ data: [invitee] });
  mocks.organizations.list.mockResolvedValue({ data: [organization] });
  mocks.companies.list.mockResolvedValue({ companies: [] });
});
afterEach(cleanup);

describe('invitation delivery outcomes', () => {
  it.each(outcomes)('shows %s for user creation', async (status, message) => {
    mocks.users.create.mockResolvedValue({ data: invitee, invitation_delivery_status: status,
      invitation_sent: status === 'submitted', invitation_error: status === 'failed' ? 'Synthetic failure' : null });
    render(<Users />);
    await screen.findAllByText('Synthetic Invitee');
    fireEvent.click(screen.getByRole('button', { name: 'Invite User' }));
    fireEvent.change(screen.getByPlaceholderText('Email address *'), { target: { value: invitee.email } });
    fireEvent.click(screen.getByRole('button', { name: 'Send Invitation' }));
    expect(await screen.findByText(new RegExp(message.replace(/[()]/g, '\\$&')))).toBeTruthy();
    expect(screen.queryByText(/Invitation (?:re)?sent to/)).toBeNull();
  });

  it.each(outcomes)('shows %s for user resend', async (status, message) => {
    mocks.users.resendInvitation.mockResolvedValue({ data: invitee, invitation_delivery_status: status,
      invitation_sent: status === 'submitted', invitation_error: status === 'failed' ? 'Synthetic failure' : null });
    render(<Users />);
    fireEvent.click((await screen.findAllByRole('button', { name: 'Resend' }))[0]);
    expect(await screen.findByText(new RegExp(message.replace(/[()]/g, '\\$&')))).toBeTruthy();
    expect(screen.queryByText(/Invitation (?:re)?sent to/)).toBeNull();
  });

  it.each(outcomes)('shows %s for organization creation with first admin', async (status, message) => {
    mocks.organizations.create.mockResolvedValue({ data: organization, admin_user: invitee,
      invitation_delivery_status: status, invitation_sent: status === 'submitted' });
    render(<Organizations />);
    await screen.findAllByText('Synthetic Firm');
    fireEvent.click(screen.getByRole('button', { name: 'New Organization' }));
    fireEvent.change(screen.getByPlaceholderText('Organization name *'), { target: { value: 'New Firm' } });
    fireEvent.change(screen.getByPlaceholderText('Primary company name *'), { target: { value: 'New HQ' } });
    fireEvent.change(screen.getByPlaceholderText('First admin email (optional)'), { target: { value: invitee.email } });
    fireEvent.click(screen.getByRole('button', { name: 'Create Organization' }));
    expect(await screen.findByText(new RegExp(message.replace(/[()]/g, '\\$&')))).toBeTruthy();
  });

  it.each(outcomes)('shows %s for adding an organization admin', async (status, message) => {
    mocks.organizations.createAdminUser.mockResolvedValue({ data: invitee,
      invitation_delivery_status: status, invitation_sent: status === 'submitted' });
    render(<Organizations />);
    fireEvent.click((await screen.findAllByRole('button', { name: 'Add Admin' }))[0]);
    fireEvent.change(screen.getByPlaceholderText('Admin email *'), { target: { value: invitee.email } });
    fireEvent.click(screen.getByRole('button', { name: 'Create Admin' }));
    expect(await screen.findByText(new RegExp(message.replace(/[()]/g, '\\$&')))).toBeTruthy();
  });

  it('does not infer delivery from the legacy sent boolean without an outcome', async () => {
    mocks.users.resendInvitation.mockResolvedValue({ data: invitee, invitation_sent: true });
    render(<Users />);
    fireEvent.click((await screen.findAllByRole('button', { name: 'Resend' }))[0]);
    expect(await screen.findByText(/Invitation delivery status is unavailable/)).toBeTruthy();
    expect(screen.queryByText(/Invitation (?:re)?sent to/)).toBeNull();
  });

  it('creates an organization without claiming an invitation when no admin was requested', async () => {
    mocks.organizations.create.mockResolvedValue({ data: organization, admin_user: null,
      invitation_delivery_status: 'not_requested', invitation_sent: false });
    render(<Organizations />);
    await screen.findAllByText('Synthetic Firm');
    fireEvent.click(screen.getByRole('button', { name: 'New Organization' }));
    fireEvent.change(screen.getByPlaceholderText('Organization name *'), { target: { value: 'No Admin Firm' } });
    fireEvent.change(screen.getByPlaceholderText('Primary company name *'), { target: { value: 'New HQ' } });
    fireEvent.click(screen.getByRole('button', { name: 'Create Organization' }));
    expect(await screen.findByText('Organization created.')).toBeTruthy();
    expect(screen.queryByText(/Invitation (?:queued|submitted|email failed|delivery status)/)).toBeNull();
  });
});
