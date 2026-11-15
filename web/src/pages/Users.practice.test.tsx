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

vi.mock('@/services/api', () => ({
  usersApi: apiMocks.users,
  companiesApi: apiMocks.companies,
  companyAssignmentsApi: { list: vi.fn(), updateClientManagement: vi.fn() },
  auditLogsApi: { list: vi.fn() },
  ApiError: class ApiError extends Error {
    status: number;
    data?: unknown;
    constructor(message: string, status = 422, _details?: unknown, data?: unknown) {
      super(message);
      this.status = status;
      this.data = data;
    }
  },
}));
vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ user: { id: 1, role: 'org_admin' } }),
}));
vi.mock('@/components/layout/Header', () => ({
  Header: ({ actions }: { actions?: ReactNode }) => <header>{actions}</header>,
}));

const realClient = { id: 1, organization_id: 7, name: 'Synthetic Bakery', active: true, active_employees: 4, payroll_environment: 'live' } as CompanyListItem;
const copyB = {
  id: 3, organization_id: 7, name: 'Synthetic Bakery practice B', active: true, active_employees: 4,
  payroll_environment: 'migration_rehearsal', test_workspace: true, test_workspace_purpose: 'sandbox',
  migration_rehearsal_status: 'pending', test_workspace_expires_at: '2027-02-12T00:00:00Z',
} as CompanyListItem;
const archivedCopyA = {
  ...copyB, id: 2, name: 'Synthetic Bakery practice A', active: false, migration_rehearsal_status: 'ready',
  test_workspace_archived_at: '2026-11-14T00:00:00Z', test_workspace_read_only: true,
} as CompanyListItem;
const readyB = { ...copyB, migration_rehearsal_status: 'ready' } as CompanyListItem;

const practiceLogin: User = {
  id: 5, name: 'Practice Login', email: 'practice-login@example.invalid', role: 'client', organization_id: 7,
  active: false, assigned_company_ids: [2], assigned_companies: [{ id: 2, name: archivedCopyA.name, test_workspace: true }],
  practice_company_id: 2, practice_company_name: archivedCopyA.name, practice_copy_closed_reason: 'archived',
  invitation_status: 'accepted', invitation_pending: false,
  created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-14T00:00:00Z',
};

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

beforeEach(() => {
  vi.resetAllMocks();
  apiMocks.users.list.mockResolvedValue({ data: [] });
});

describe('Invite User with a practice copy', () => {
  it('reloads companies when the form opens so a copy that finished preparing can be given to a client login', async () => {
    // The page loaded while copy B was still being prepared; it is ready by the time Invite opens.
    apiMocks.companies.list.mockResolvedValueOnce({ companies: [realClient, copyB] })
      .mockResolvedValue({ companies: [realClient, readyB] });
    apiMocks.users.create.mockResolvedValue({ data: { id: 9 }, invitation_delivery_status: 'queued', invitation_sent: false });
    const user = userEvent.setup();
    render(<Users />);
    await waitFor(() => expect(apiMocks.companies.list).toHaveBeenCalledTimes(1));

    await user.click(await screen.findByRole('button', { name: 'Invite User' }));
    await user.type(screen.getByPlaceholderText('Email address *'), 'practice-b@example.invalid');
    await user.selectOptions(screen.getByRole('combobox', { name: 'Role' }), 'client');

    // On the stale list, copy B was pending and so vanished for the client role.
    await waitFor(() => {
      const copy = screen.getByRole('checkbox', { name: /Synthetic Bakery practice B/ }) as HTMLInputElement;
      expect(copy.disabled).toBe(false);
    });
    const copy = screen.getByRole('checkbox', { name: /Synthetic Bakery practice B/ });
    expect(copy.closest('section')?.textContent).toContain('Test / practice workspaces');
    await user.click(copy);
    await user.click(screen.getByRole('button', { name: /Send Invitation/ }));

    await waitFor(() => expect(apiMocks.users.create).toHaveBeenCalledExactlyOnceWith({
      email: 'practice-b@example.invalid', name: 'practice-b', role: 'client', company_ids: [3],
    }));
  });

  it('lists a copy that is still being prepared as disabled, groups the picker and hides archived copies', async () => {
    apiMocks.companies.list.mockResolvedValue({ companies: [realClient, copyB, archivedCopyA] });
    const user = userEvent.setup();
    render(<Users />);

    await user.click(await screen.findByRole('button', { name: 'Invite User' }));
    await user.selectOptions(screen.getByRole('combobox', { name: 'Role' }), 'client');

    const production = (await screen.findByText('Production clients')).closest('section') as HTMLElement;
    expect(within(production).getByRole('checkbox', { name: /Synthetic Bakery/ })).toBeTruthy();
    const practiceGroup = screen.getByText('Test / practice workspaces').closest('section') as HTMLElement;
    const preparing = within(practiceGroup).getByRole('checkbox', { name: /Synthetic Bakery practice B/ }) as HTMLInputElement;
    expect(preparing.disabled).toBe(true);
    expect(within(practiceGroup).getByText('Preparing… refresh in a moment')).toBeTruthy();
    expect(within(practiceGroup).queryByText(/practice A/)).toBeNull();
    const closed = screen.getByText('Archived, expired or read-only (1)').closest('details') as HTMLDetailsElement;
    expect(closed.open).toBe(false);
    expect((within(closed).getByRole('checkbox', { name: /practice A/ }) as HTMLInputElement).disabled).toBe(true);

    const calls = apiMocks.companies.list.mock.calls.length;
    await user.click(within(practiceGroup).getByRole('button', { name: 'Refresh test and practice workspaces' }));
    await waitFor(() => expect(apiMocks.companies.list.mock.calls.length).toBe(calls + 1));
  });
});

describe('Practice login whose copy was archived', () => {
  beforeEach(() => {
    apiMocks.users.list.mockResolvedValue({ data: [practiceLogin] });
    apiMocks.companies.list.mockResolvedValue({ companies: [realClient, archivedCopyA, readyB] });
  });

  it('moves the login to a ready practice copy and activates it', async () => {
    apiMocks.users.movePracticeCopy.mockResolvedValue({
      data: { ...practiceLogin, active: true, practice_company_id: 3, practice_company_name: readyB.name, practice_copy_closed_reason: null },
      moved_from: { id: 2, name: archivedCopyA.name },
    });
    const user = userEvent.setup();
    render(<Users />);

    const [moveButton] = await screen.findAllByRole('button', { name: 'Move Practice Login to another practice copy' });
    await user.click(moveButton);
    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).queryByRole('radio', { name: /Synthetic Bakery$/ })).toBeNull();
    expect((within(dialog).getByRole('radio', { name: /practice B/ }) as HTMLInputElement).checked).toBe(true);
    expect((within(dialog).getByRole('checkbox', { name: /Activate the login now/ }) as HTMLInputElement).checked).toBe(true);
    await user.click(within(dialog).getByRole('button', { name: 'Move and activate' }));

    await waitFor(() => expect(apiMocks.users.movePracticeCopy).toHaveBeenCalledExactlyOnceWith(5, { company_id: 3, activate: true }));
    expect(await screen.findByText(/Practice Login now uses Synthetic Bakery practice B/)).toBeTruthy();
  });

  it('turns a refused Activate into a plain message with a Move action', async () => {
    const { ApiError } = await import('@/services/api');
    const message = 'Practice Login belongs to practice copy Synthetic Bakery practice A, which is archived. To use this login again, choose Move and pick a current practice copy.';
    apiMocks.users.activate.mockRejectedValue(new ApiError(message, 422, undefined, { error: message, code: 'practice_copy_closed' }));
    const user = userEvent.setup();
    render(<Users />);

    const table = await screen.findByRole('table');
    await user.click(within(table).getByRole('button', { name: /Activate/ }));

    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toContain('which is archived');
    expect(alert.textContent).not.toContain('Practice company must be');
    expect(within(alert).getByRole('button', { name: 'Move Practice Login to another practice copy' })).toBeTruthy();
  });

  it('offers Deactivate and Move when Delete is refused for retained history', async () => {
    const { ApiError } = await import('@/services/api');
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const message = "Practice Login can't be deleted because their name is on payroll submissions, uploaded files, review history or other records that have to be kept.";
    apiMocks.users.delete.mockRejectedValue(new ApiError(message, 422, undefined, { error: message, code: 'user_has_retained_history' }));
    apiMocks.users.list.mockResolvedValue({ data: [{ ...practiceLogin, active: true }] });
    const user = userEvent.setup();
    render(<Users />);

    const table = await screen.findByRole('table');
    await user.click(within(table).getByRole('button', { name: 'Delete user Practice Login (practice-login@example.invalid)' }));

    const alert = await screen.findByRole('alert');
    expect(within(alert).getByRole('button', { name: /Deactivate instead/ })).toBeTruthy();
    expect(within(alert).getByRole('button', { name: 'Move Practice Login to another practice copy' })).toBeTruthy();
  });

  it('keeps the practice login fixed to its copy in Edit and saves a rename without touching assignments', async () => {
    apiMocks.users.update.mockResolvedValue({ data: practiceLogin });
    const user = userEvent.setup();
    render(<Users />);

    const table = await screen.findByRole('table');
    await user.click(within(table).getByRole('button', { name: 'Edit' }));
    expect((within(table).getByRole('combobox', { name: 'Role' }) as HTMLSelectElement).disabled).toBe(true);
    expect(within(table).getByText(/That copy is archived/)).toBeTruthy();
    expect(within(table).queryByText('Production clients')).toBeNull();
    await user.click(within(table).getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(apiMocks.users.update).toHaveBeenCalledExactlyOnceWith(5, { name: 'Practice Login', role: 'client' }));
  });
});
