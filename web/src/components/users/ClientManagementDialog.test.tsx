// @vitest-environment jsdom
import { act, cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CompanyAssignment } from '@/services/api';
import type { User } from '@/types';
import { ClientManagementDialog } from './ClientManagementDialog';

const mocks = vi.hoisted(() => ({ list: vi.fn(), update: vi.fn(), actor: { id: 1, role: 'org_admin' } }));
vi.mock('@/services/api', () => ({ companyAssignmentsApi: { list: mocks.list, updateClientManagement: mocks.update } }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: mocks.actor }) }));
const accountant = { id: 2, role: 'accountant', name: 'Synthetic Accountant' } as User;
const assignment = (id: number, enabled = false, extra: Partial<CompanyAssignment> = {}): CompanyAssignment => ({
  id, user_id: 2, user_name: accountant.name, user_email: 'synthetic@example.invalid', company_id: id,
  company_name: `Client ${id}`, test_workspace: false, created_at: '2026-01-01', client_management: enabled, ...extra,
});
beforeEach(() => { vi.resetAllMocks(); mocks.actor = { id: 1, role: 'org_admin' }; mocks.list.mockResolvedValue({ data: [assignment(10), assignment(20)] }); mocks.update.mockResolvedValue({ data: assignment(10, true) }); });
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); });

describe('explicit accountant client management', () => {
  it('loads grants, grants and revokes only the selected assignment, and re-reads saved access', async () => {
    const user = userEvent.setup();
    mocks.list.mockResolvedValueOnce({ data: [assignment(10), assignment(20)] })
      .mockResolvedValueOnce({ data: [assignment(10, true), assignment(20)] })
      .mockResolvedValueOnce({ data: [assignment(10), assignment(20)] });
    render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />);
    expect(screen.getByRole('status').textContent).toContain('Loading');
    await user.click(await screen.findByRole('button', { name: 'Grant Client management for Client 10' }));
    expect(mocks.update).toHaveBeenCalledExactlyOnceWith(10, true);
    await screen.findByText('Client management granted for Client 10.');
    expect(within(screen.getByRole('region', { name: 'Client 20' })).getByText('Client management: Not granted')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Revoke Client management for Client 10' }));
    await screen.findByText('Client management revoked for Client 10.');
    expect(mocks.update).toHaveBeenLastCalledWith(10, false);
    expect(mocks.list).toHaveBeenCalledTimes(3);
    expect(mocks.list).toHaveBeenLastCalledWith(2);
    expect(accountant.role).toBe('accountant');
  });
  it('retains the failed client action and supports retry without claiming a grant', async () => {
    const user = userEvent.setup();
    mocks.update.mockRejectedValueOnce(new Error('Access changed. Reload or retry.')).mockResolvedValueOnce({ data: assignment(10, true) });
    render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />);
    await user.click(await screen.findByRole('button', { name: 'Grant Client management for Client 10' }));
    await screen.findByText('Access changed. Reload or retry.');
    expect(screen.queryByText('Client management granted for Client 10.')).toBeNull();
    mocks.list.mockResolvedValue({ data: [assignment(10, true), assignment(20)] });
    await user.click(screen.getByRole('button', { name: 'Grant Client management for Client 10' }));
    await screen.findByRole('button', { name: 'Revoke Client management for Client 10' });
    expect(mocks.update).toHaveBeenNthCalledWith(2, 10, true);
  });
  it('recovers assignment load errors and treats a missing boolean as no grant', async () => {
    const user = userEvent.setup();
    mocks.list.mockRejectedValueOnce(new Error('Assignments unavailable')).mockResolvedValue({ data: [assignment(10, false, { client_management: undefined })] });
    render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />);
    await screen.findByText('Assignments unavailable');
    await user.click(screen.getByRole('button', { name: 'Reload client access' }));
    await screen.findByRole('button', { name: 'Grant Client management for Client 10' });
    expect(mocks.update).not.toHaveBeenCalled();
  });
  it('reports a failed confirmation reload without reporting success', async () => {
    const user = userEvent.setup();
    mocks.list.mockResolvedValueOnce({ data: [assignment(10)] }).mockRejectedValue(new Error('Could not confirm saved access'));
    render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />);
    await user.click(await screen.findByRole('button', { name: 'Grant Client management for Client 10' }));
    await screen.findByText('Could not confirm saved access');
    expect(screen.queryByText('Client management granted for Client 10.')).toBeNull();
  });
  it('keeps revocation available for expired grants and denies new grants at their deadline', async () => {
    const user = userEvent.setup();
    const expiry = Date.now() + 60_000;
    mocks.list.mockResolvedValue({ data: [assignment(10, true, { expires_at: new Date(Date.now() - 1000).toISOString() }), assignment(20, false, { expires_at: new Date(expiry).toISOString() })] });
    render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />);
    const expired = await screen.findByRole('button', { name: 'Revoke Client management for Client 10' });
    expect(expired.hasAttribute('disabled')).toBe(false);
    vi.spyOn(Date, 'now').mockReturnValue(expiry + 1);
    // A rerender also checks the deadline immediately, before any request.
    await user.click(screen.getByRole('button', { name: 'Grant Client management for Client 20' }));
    expect(mocks.update).not.toHaveBeenCalled();
    vi.restoreAllMocks();
  });
  it('allows an administrator to clear an expired grant for an inactive accountant', async () => {
    const user = userEvent.setup();
    const expired = new Date(Date.now() - 1000).toISOString();
    mocks.list.mockResolvedValueOnce({ data: [assignment(10, true, { expires_at: expired })] })
      .mockResolvedValue({ data: [assignment(10, false, { expires_at: expired })] });
    render(<ClientManagementDialog accountant={{ ...accountant, active: false }} onClose={vi.fn()} />);
    await user.click(await screen.findByRole('button', { name: 'Revoke Client management for Client 10' }));
    expect(mocks.update).toHaveBeenCalledWith(10, false);
    expect(await screen.findByText('Client management revoked for Client 10.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Grant Client management for Client 10' })).toHaveProperty('disabled', true);
  });

  it('does not offer self-grants, role promotion, or non-admin delegation', () => {
    const view = render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />);
    view.unmount();
    mocks.list.mockClear();
    mocks.actor = { id: 2, role: 'org_admin' };
    const self = render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />);
    expect(screen.queryByRole('dialog')).toBeNull();
    self.unmount();
    mocks.actor = { id: 1, role: 'accountant' };
    render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />);
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(mocks.list).not.toHaveBeenCalled();
  });
  it('ignores an old accountant response after switching the target', async () => {
    let resolve!: (value: { data: CompanyAssignment[] }) => void;
    mocks.list.mockImplementationOnce(() => new Promise(done => { resolve = done; })).mockResolvedValue({ data: [] });
    const view = render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />);
    view.rerender(<ClientManagementDialog accountant={{ ...accountant, id: 3, name: 'Next Accountant' }} onClose={vi.fn()} />);
    await screen.findByText('No assigned clients. Assign and save a client on the user profile first.');
    await act(async () => resolve({ data: [assignment(10, true)] }));
    expect(screen.queryByRole('button', { name: 'Revoke Client management for Client 10' })).toBeNull();
  });
  it('updates the displayed state when an open assignment expires', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-18T00:00:00Z'));
    mocks.list.mockResolvedValue({ data: [assignment(10, true, { expires_at: '2026-10-18T00:01:00Z' })] });
    await act(async () => { render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />); });
    expect(screen.getByRole('button', { name: 'Revoke Client management for Client 10' }).hasAttribute('disabled')).toBe(false);
    await act(async () => { vi.advanceTimersByTime(60_020); });
    expect(screen.getByRole('button', { name: 'Revoke Client management for Client 10' }).hasAttribute('disabled')).toBe(false);
    expect(screen.getByText('Client management: Unavailable — assignment expired')).toBeTruthy();
    expect(mocks.update).not.toHaveBeenCalled();
  });
  it('does not report a grant when authoritative access was revoked before the confirmation reload', async () => {
    const user = userEvent.setup();
    render(<ClientManagementDialog accountant={accountant} onClose={vi.fn()} />);
    await user.click(await screen.findByRole('button', { name: 'Grant Client management for Client 10' }));
    await screen.findByText('Access changed while saving. Review the current client access before trying again.');
    expect(screen.queryByText('Client management granted for Client 10.')).toBeNull();
  });

});
