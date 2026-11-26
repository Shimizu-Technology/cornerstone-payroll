// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactNode } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CompanyListItem } from '@/services/api';
import type { User } from '@/types';
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

const viewer = {
  id: 21, name: 'Sample Viewer', email: 'viewer@example.test', role: 'client', client_access_level: 'viewer',
  active: true, assigned_company_ids: [1], assigned_companies: [{ id: 1, name: 'Sample Bakery' }],
  created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-01T00:00:00Z',
} as User;
const manager = { ...viewer, id: 22, name: 'Sample Manager', email: 'manager@example.test', client_access_level: 'manager' } as User;

describe('Client access level', () => {
  it('invites a client user as a Client manager by default, or as a Client viewer', async () => {
    apiMocks.users.create.mockResolvedValue({ data: { id: 9 }, invitation_delivery_status: 'queued', invitation_sent: false });
    const user = userEvent.setup();
    render(<Users />);
    await user.click(await screen.findByRole('button', { name: 'Invite User' }));

    expect(screen.queryByRole('combobox', { name: 'Client access' })).toBeNull();
    await user.type(screen.getByLabelText('Email address'), 'viewer.new@example.test');
    await user.selectOptions(screen.getByRole('combobox', { name: 'Role' }), 'client');
    const access = screen.getByRole('combobox', { name: 'Client access' }) as HTMLSelectElement;
    expect(access.value).toBe('manager');
    expect(within(access).getAllByRole('option').map((option) => option.textContent)).toEqual(['Client manager', 'Client viewer']);

    await user.selectOptions(access, 'viewer');
    expect(screen.getByText(/View only: sees payroll, employees, reports, documents and messages/)).toBeTruthy();
    await user.click(await screen.findByRole('checkbox', { name: /Sample Bakery/ }));
    await user.click(screen.getByRole('button', { name: /Send Invitation/ }));
    await waitFor(() => expect(apiMocks.users.create).toHaveBeenCalledExactlyOnceWith({
      email: 'viewer.new@example.test', name: 'viewer.new', role: 'client', client_access_level: 'viewer', company_ids: [1],
    }));
  });

  it('shows each client user’s access level in the list and lets staff change it', async () => {
    apiMocks.users.list.mockResolvedValue({ data: [viewer, manager] });
    apiMocks.users.update.mockResolvedValue({ data: { ...viewer, client_access_level: 'manager' } });
    const user = userEvent.setup();
    render(<Users />);

    expect((await screen.findAllByText('Client Portal User · Client viewer')).length).toBeGreaterThan(0);
    expect(screen.getAllByText('Client Portal User · Client manager').length).toBeGreaterThan(0);

    // The desktop table row (the mobile cards render alongside it in tests).
    const findRow = () => screen.getAllByRole('row').find((candidate) => within(candidate).queryByText('viewer@example.test')) as HTMLElement;
    await user.click(within(findRow()).getByRole('button', { name: 'Edit' }));
    const access = within(findRow()).getByRole('combobox', { name: 'Client access' }) as HTMLSelectElement;
    expect(access.value).toBe('viewer');
    await user.selectOptions(access, 'manager');
    await user.click(within(findRow()).getByRole('button', { name: /Save/ }));
    await waitFor(() => expect(apiMocks.users.update).toHaveBeenCalledWith(21, expect.objectContaining({
      role: 'client', client_access_level: 'manager',
    })));
  });
});
