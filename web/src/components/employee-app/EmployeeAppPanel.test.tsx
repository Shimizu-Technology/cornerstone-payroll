// @vitest-environment jsdom

import { cleanup, render, screen, within } from '@testing-library/react';
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
  afterEach(() => { cleanup(); vi.resetAllMocks(); });

  it('explains why an invite cannot be sent while the company is off', async () => {
    openPanel({ ...employee, enabled: false, status: 'not_invited', can_invite: true });
    expect(await screen.findByText("The employee app isn't turned on for this company yet.")).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Invite' })).toBeNull();
  });

  it('shows a replacement code only in the current print view', async () => {
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
    await user.click(within(printView).getByRole('button', { name: 'Done' }));
    expect(screen.queryByText('ABCDE-FGHJK')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Revoke access' })).toBeNull();
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
