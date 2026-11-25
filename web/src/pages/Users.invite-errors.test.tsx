// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactNode } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CompanyListItem } from '@/services/api';
import { Users } from './Users';

const apiMocks = vi.hoisted(() => ({
  users: {
    list: vi.fn(), create: vi.fn(), update: vi.fn(), delete: vi.fn(),
    activate: vi.fn(), deactivate: vi.fn(), resendInvitation: vi.fn(), movePracticeCopy: vi.fn(),
  },
  companies: { list: vi.fn() },
}));

const ApiError = vi.hoisted(() => class ApiError extends Error {
  status: number;
  data?: unknown;
  constructor(message: string, status = 422, _details?: unknown, data?: unknown) {
    super(message);
    this.status = status;
    this.data = data;
  }
});

vi.mock('@/services/api', () => ({
  usersApi: apiMocks.users,
  companiesApi: apiMocks.companies,
  companyAssignmentsApi: { list: vi.fn(), updateClientManagement: vi.fn() },
  auditLogsApi: { list: vi.fn() },
  ApiError,
}));
vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ user: { id: 1, role: 'org_admin' } }),
}));
vi.mock('@/components/layout/Header', () => ({
  Header: ({ actions }: { actions?: ReactNode }) => <header>{actions}</header>,
}));

const client = { id: 1, organization_id: 7, name: 'Sample Bakery', active: true, active_employees: 4, payroll_environment: 'live' } as CompanyListItem;

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

beforeEach(() => {
  vi.resetAllMocks();
  apiMocks.users.list.mockResolvedValue({ data: [] });
  apiMocks.companies.list.mockResolvedValue({ companies: [client] });
});

async function openInvite() {
  const user = userEvent.setup();
  render(<Users />);
  await user.click(await screen.findByRole('button', { name: 'Invite User' }));
  return user;
}

function describedBy(element: HTMLElement): string {
  const id = element.getAttribute('aria-describedby');
  return id ? document.getElementById(id)?.textContent ?? '' : '';
}

describe('Invite User field errors', () => {
  it('labels every field and shows a missing email under the field without sending', async () => {
    const user = await openInvite();
    const email = screen.getByLabelText('Email address');
    expect(screen.getByLabelText('Name (optional)')).toBeTruthy();
    expect(screen.getByRole('combobox', { name: 'Role' })).toBeTruthy();

    await user.click(screen.getByRole('button', { name: /Send Invitation/ }));

    expect(email.getAttribute('aria-invalid')).toBe('true');
    expect(describedBy(email)).toBe('Enter the email address to send the invitation to.');
    expect(document.activeElement).toBe(email);
    expect(screen.queryByText(/What to do/)).toBeNull();
    expect(apiMocks.users.create).not.toHaveBeenCalled();

    await user.type(email, 'not-an-email');
    expect(email.getAttribute('aria-invalid')).toBe('false');
    await user.click(screen.getByRole('button', { name: /Send Invitation/ }));
    expect(describedBy(email)).toBe('Enter a full email address, like name@example.com.');
  });

  it('requires a client for a client portal user before sending', async () => {
    apiMocks.users.create.mockResolvedValue({ data: { id: 9 }, invitation_delivery_status: 'queued', invitation_sent: false });
    const user = await openInvite();
    await user.type(screen.getByLabelText('Email address'), 'portal@example.test');
    await user.selectOptions(screen.getByRole('combobox', { name: 'Role' }), 'client');
    expect(screen.getByText('(choose at least one)')).toBeTruthy();

    await user.click(screen.getByRole('button', { name: /Send Invitation/ }));
    expect((await screen.findByRole('alert')).textContent).toBe('Choose at least one client for a client portal user.');
    expect(apiMocks.users.create).not.toHaveBeenCalled();

    await user.click(await screen.findByRole('checkbox', { name: /Sample Bakery/ }));
    expect(screen.queryByText('Choose at least one client for a client portal user.')).toBeNull();
    await user.click(screen.getByRole('button', { name: /Send Invitation/ }));
    await waitFor(() => expect(apiMocks.users.create).toHaveBeenCalledExactlyOnceWith({
      email: 'portal@example.test', name: 'portal', role: 'client', company_ids: [1],
    }));
  });

  it('puts server refusals that name a field under that field', async () => {
    apiMocks.users.create.mockRejectedValueOnce(new ApiError('Email has already been taken', 422, undefined, { error: ['Email has already been taken'] }));
    const user = await openInvite();
    const email = screen.getByLabelText('Email address');
    await user.type(email, 'taken@example.test');
    await user.click(screen.getByRole('button', { name: /Send Invitation/ }));

    await waitFor(() => expect(describedBy(email)).toBe('This email already has an account. Find it in the list below.'));
    expect(screen.queryByText('Email has already been taken')).toBeNull();
  });
});
