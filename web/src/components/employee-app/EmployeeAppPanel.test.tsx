// @vitest-environment jsdom

import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '@/services/api';
import { employeeAppRolloutApi, type EmployeeAppAccess } from '@/services/employee-app-rollout-api';
import { EmployeeAppPanel } from './EmployeeAppPanel';

const mocks = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }));
vi.mock('@/services/api', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/services/api')>()),
  apiClient: { get: mocks.get, post: mocks.post },
}));

const employee: EmployeeAppAccess = {
  id: 5, name: 'Sample Worker', email: 'worker@example.test', enabled: true, status: 'invited',
  staff_actions: false, can_manage_invites: true, access_id: 10, invite_expires_at: '2099-06-30T09:00:00Z',
  invite_delivery: 'code', locked_until: null, former_access_until: null, reset_pending: false, can_invite: false,
};

function openPanel(access: EmployeeAppAccess, audience: 'client' | 'admin' = 'client') {
  mocks.get.mockResolvedValue({ data: access });
  const user = userEvent.setup();
  render(<MemoryRouter><EmployeeAppPanel companyId={1} companyName="Example Bakery" employeeId={5} audience={audience} /></MemoryRouter>);
  return user;
}

describe('Employee app panel', () => {
  afterEach(() => { cleanup(); vi.resetAllMocks(); vi.restoreAllMocks(); });

  it('explains why an invite cannot be sent while the company is off', async () => {
    openPanel({ ...employee, enabled: false, status: 'not_invited', can_invite: true });
    expect(await screen.findByText("The employee app isn't turned on for this company yet.")).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Invite' })).toBeNull();
  });

  it('keeps the code until Done, confirms closing before Print, and clears it after printing', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
    const print = vi.spyOn(window, 'print').mockImplementation(() => {});
    const user = openPanel(employee);
    mocks.post.mockResolvedValue({
      data: employee,
      print: { name: employee.name, code: 'ABCDEFGHJK', url: 'https://employees.example.test/activate', expires_at: employee.invite_expires_at },
    });
    const resend = await screen.findByRole('button', { name: 'Resend invite' });
    await user.click(resend);
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Create code' }));

    const printView = await screen.findByRole('dialog', { name: 'Print sign-up code' });
    expect(within(printView).getByText('ABCDE-FGHJK')).toBeTruthy();
    expect(mocks.post).toHaveBeenCalledWith('/client/employees/5/employee_app/resend',
      { access_id: 10, delivery: 'code', confirm_same_person_email: false, reason: undefined }, { companyId: 1 });

    const backdrop = printView.closest('[data-dialog-portal]')?.querySelector('[data-dialog-backdrop]');
    expect(backdrop).toBeInstanceOf(HTMLElement);
    await user.click(backdrop as HTMLElement);
    await user.keyboard('{Escape}');
    expect(confirm).not.toHaveBeenCalled();
    expect(within(printView).getByText('ABCDE-FGHJK')).toBeTruthy();

    const done = within(printView).getByRole('button', { name: 'Done' });
    await user.click(done);
    expect(confirm).toHaveBeenCalledWith(expect.stringContaining('Close without printing?'));
    expect(within(printView).getByText('ABCDE-FGHJK')).toBeTruthy();

    await user.click(within(printView).getByRole('button', { name: 'Print code' }));
    expect(print).toHaveBeenCalledOnce();
    await user.click(done);
    expect(confirm).toHaveBeenCalledTimes(1);
    expect(screen.queryByText('ABCDE-FGHJK')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Revoke access' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Reset sign-up' })).toBeNull();
  });

  it('shows a pending reset without offering an unavailable action while the app is off', async () => {
    openPanel({ ...employee, staff_actions: true, enabled: false, reset_pending: true }, 'admin');
    expect(await screen.findByText('Sign-up reset is waiting to finish.')).toBeTruthy();
    expect(screen.queryByText(/Choose Reset sign-up/)).toBeNull();
    expect(screen.queryByRole('button', { name: 'Reset sign-up' })).toBeNull();
  });

  it('tells the client to have the employee sign in when their account already exists', async () => {
    const user = openPanel(employee);
    const message = 'This person already created their account. Ask them to sign in to finish.';
    mocks.post.mockRejectedValue(new ApiError(message, 409, undefined, { code: 'sign_up_accepted' }));
    await user.click(await screen.findByRole('button', { name: 'Resend invite' }));
    const dialog = screen.getByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: 'Create code' }));
    expect(await within(dialog).findByRole('status')).toHaveProperty('textContent', message);
    expect(within(dialog).queryByRole('button', { name: 'Create code' })).toBeNull();
    await user.click(within(dialog).getByRole('button', { name: 'Done' }));
  });

  it('requires a reason before staff can revoke', async () => {
    const user = openPanel({ ...employee, staff_actions: true }, 'admin');
    mocks.post.mockResolvedValue({ data: { ...employee, staff_actions: true, status: 'revoked' } });
    await user.click(await screen.findByRole('button', { name: 'Revoke access' }));
    const dialog = within(screen.getByRole('dialog'));
    const revoke = dialog.getByRole('button', { name: 'Revoke access' });
    expect(revoke).toHaveProperty('disabled', true);
    await user.type(dialog.getByRole('textbox', { name: 'Reason' }), 'Employee request');
    await user.click(revoke);
    expect(await screen.findByText('App access revoked.')).toBeTruthy();
    expect(mocks.post).toHaveBeenCalledWith('/admin/employees/5/employee_app/revoke',
      { access_id: 10, delivery: undefined, confirm_same_person_email: false, reason: 'Employee request' }, { companyId: 1 });
  });

  it.each(['resolves', 'rejects'] as const)('ignores an older access refresh that %s after a successful retry', async (outcome) => {
    const access = { ...employee, staff_actions: true };
    const user = openPanel(access, 'admin');
    await user.click(await screen.findByRole('button', { name: 'Revoke access' }));
    const dialog = within(screen.getByRole('dialog', { name: 'Revoke access' }));

    let resolveRefresh!: (value: { data: EmployeeAppAccess }) => void;
    let rejectRefresh!: (error: Error) => void;
    mocks.get.mockReturnValueOnce(new Promise((resolve, reject) => {
      resolveRefresh = resolve;
      rejectRefresh = reject;
    }));
    mocks.post.mockRejectedValueOnce(new Error('Could not revoke access.')).mockResolvedValueOnce({
      data: { ...access, status: 'revoked' },
    });
    await user.type(dialog.getByRole('textbox', { name: 'Reason' }), 'Employee request');
    const revoke = dialog.getByRole('button', { name: 'Revoke access' });
    await user.click(revoke);
    expect(await dialog.findByRole('alert')).toHaveProperty('textContent', 'Could not revoke access.');
    await waitFor(() => expect(mocks.get).toHaveBeenCalledTimes(2));

    await user.click(revoke);
    expect(await screen.findByText('Revoked')).toBeTruthy();
    await act(async () => {
      if (outcome === 'resolves') resolveRefresh({ data: access });
      else rejectRefresh(new Error('The old status request failed.'));
    });
    expect(screen.getByText('Revoked')).toBeTruthy();
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('keeps a rejected action and its reason in the same dialog when the refresh fails', async () => {
    const user = openPanel({ ...employee, staff_actions: true }, 'admin');
    await user.click(await screen.findByRole('button', { name: 'Revoke access' }));
    const dialog = screen.getByRole('dialog', { name: 'Revoke access' });
    const form = within(dialog);
    const reason = form.getByRole('textbox', { name: 'Reason' });
    mocks.post.mockRejectedValueOnce(new Error('Could not revoke access.'));
    mocks.get.mockRejectedValueOnce(new Error('The status request failed.'));

    await user.type(reason, 'Employee request');
    await user.click(form.getByRole('button', { name: 'Revoke access' }));

    expect(await screen.findByText(/Could not refresh employee app status/)).toBeTruthy();
    expect(screen.getByRole('dialog', { name: 'Revoke access' })).toBe(dialog);
    expect(form.getByRole('alert')).toHaveProperty('textContent', 'Could not revoke access.');
    expect(form.getByRole('textbox', { name: 'Reason' })).toHaveProperty('value', 'Employee request');
    await user.click(form.getByRole('button', { name: 'Cancel' }));
    expect(screen.getByText('Invited')).toBeTruthy();
  });

  it('sends the explicit company and employee IDs in its read and wave requests', async () => {
    const api = employeeAppRolloutApi(7, 'client');
    await api.get();
    await api.employee(55);
    await api.inviteWave([55, 56], 'code');
    expect(mocks.get).toHaveBeenCalledWith('/client/employee_app_rollout/7', undefined, { companyId: 7 });
    expect(mocks.get).toHaveBeenCalledWith('/client/employees/55/employee_app', undefined, { companyId: 7 });
    expect(mocks.post).toHaveBeenCalledWith('/client/employee_app_rollout/7/invite',
      { employee_ids: [55, 56], delivery: 'code' }, { companyId: 7 });
  });
});
