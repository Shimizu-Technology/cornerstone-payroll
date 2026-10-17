// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactNode } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { User } from '@/types';
import { Users } from './Users';

const apiMocks = vi.hoisted(() => ({
  users: {
    list: vi.fn(), create: vi.fn(), update: vi.fn(), delete: vi.fn(),
    activate: vi.fn(), deactivate: vi.fn(), resendInvitation: vi.fn(),
  },
  companies: { list: vi.fn() },
}));

vi.mock('@/services/api', () => ({
  usersApi: apiMocks.users,
  companiesApi: apiMocks.companies,
  auditLogsApi: { list: vi.fn() },
  ApiError: class ApiError extends Error {},
}));
vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ user: { id: 1, role: 'admin' } }),
}));
vi.mock('@/components/layout/Header', () => ({
  Header: ({ actions }: { actions?: ReactNode }) => <header>{actions}</header>,
}));

const originalUser: User = {
  id: 2,
  name: 'Ari Ledger',
  email: 'ari-ledger@example.invalid',
  role: 'accountant',
  active: true,
  assigned_company_ids: [1, 2],
  assigned_companies: [{ id: 1, name: 'Operator QA Live Client' }, { id: 2, name: 'Operator QA Sandbox', test_workspace: true, workspace_access_level: 'operator' }],
  created_at: '2026-10-14T00:00:00Z',
  updated_at: '2026-10-14T00:00:00Z',
};
const savedUser: User = { ...originalUser, name: 'Ari Verified', role: 'manager' };

type Presentation = 'mobile' | 'desktop';

// Both responsive branches exist in JSDOM; select the real controls in each
// presentation without pretending that JSDOM verifies viewport visibility.
function inPresentation(elements: HTMLElement[], presentation: Presentation): HTMLElement {
  const element = elements.find((candidate) => Boolean(candidate.closest('table')) === (presentation === 'desktop'));
  if (!element) throw new Error(`Named control missing from ${presentation} presentation`);
  return element;
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

beforeEach(() => {
  vi.resetAllMocks();
  apiMocks.users.list.mockResolvedValue({ data: [originalUser] });
  apiMocks.companies.list.mockResolvedValue({ companies: [
    { id: 1, name: 'Operator QA Live Client', active_employees: 5, payroll_environment: 'live' },
    { id: 2, name: 'Operator QA Sandbox', active_employees: 5, payroll_environment: 'migration_rehearsal', test_workspace: true },
  ] });
});

describe('Users accessible account controls', () => {
  it.each(['mobile', 'desktop'] as const)('cancels named edits and saves the intended user and assignments in the %s presentation', async (presentation) => {
    const user = userEvent.setup();
    apiMocks.users.list.mockResolvedValueOnce({ data: [originalUser] }).mockResolvedValue({ data: [savedUser] });
    apiMocks.users.update.mockResolvedValue({ data: savedUser });
    render(<Users />);

    await user.click(inPresentation(await screen.findAllByRole('button', { name: 'Edit' }), presentation));
    const name = inPresentation(screen.getAllByRole('textbox', { name: 'Name' }), presentation);
    const role = inPresentation(screen.getAllByRole('combobox', { name: 'Role' }), presentation);
    await user.clear(name);
    await user.type(name, 'Unsaved name');
    await user.selectOptions(role, 'employee');
    await user.click(inPresentation(screen.getAllByRole('button', { name: 'Cancel editing Ari Ledger (ari-ledger@example.invalid)' }), presentation));
    expect(apiMocks.users.update).not.toHaveBeenCalled();
    expect(screen.queryByRole('textbox', { name: 'Name' })).toBeNull();

    await user.click(inPresentation(screen.getAllByRole('button', { name: 'Edit' }), presentation));
    const restoredName = inPresentation(screen.getAllByRole('textbox', { name: 'Name' }), presentation) as HTMLInputElement;
    const restoredRole = inPresentation(screen.getAllByRole('combobox', { name: 'Role' }), presentation) as HTMLSelectElement;
    expect(restoredName.value).toBe('Ari Ledger');
    expect(restoredRole.value).toBe('accountant');
    await user.clear(restoredName);
    await user.type(restoredName, 'Ari Verified');
    await user.selectOptions(restoredRole, 'manager');
    await user.click(inPresentation(screen.getAllByRole('button', { name: 'Save' }), presentation));
    await waitFor(() => expect(apiMocks.users.update).toHaveBeenCalledExactlyOnceWith(2, {
      name: 'Ari Verified', role: 'manager', company_ids: [1, 2],
    }));
    await screen.findAllByText('Ari Verified');
    expect(screen.queryByRole('textbox', { name: 'Name' })).toBeNull();
  });

  it('lets an administrator choose the invitation role by name and cancel without creating a user', async () => {
    const user = userEvent.setup();
    render(<Users />);
    await user.click(screen.getByRole('button', { name: 'Invite User' }));
    const role = screen.getByRole('combobox', { name: 'Role' }) as HTMLSelectElement;
    await user.selectOptions(role, 'manager');
    expect(role.value).toBe('manager');
    await user.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(screen.queryByRole('combobox', { name: 'Role' })).toBeNull();
    expect(apiMocks.users.create).not.toHaveBeenCalled();
  });

  it.each(['mobile', 'desktop'] as const)('identifies the deletion target and preserves confirmation cancellation in the %s presentation', async (presentation) => {
    const user = userEvent.setup();
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
    render(<Users />);
    await user.click(inPresentation(await screen.findAllByRole('button', { name: 'Delete user Ari Ledger (ari-ledger@example.invalid)' }), presentation));
    expect(confirm).toHaveBeenCalledExactlyOnceWith('Are you sure you want to delete Ari Ledger (ari-ledger@example.invalid)? This cannot be undone.');
    expect(apiMocks.users.delete).not.toHaveBeenCalled();
    expect(screen.getByRole('table')).toBeTruthy();
  });
});
