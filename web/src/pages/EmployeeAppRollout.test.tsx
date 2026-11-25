// @vitest-environment jsdom

import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { EmployeeAppRollout as Rollout } from '@/services/employee-app-rollout-api';
import { EmployeeAppRollout } from './EmployeeAppRollout';

const mocks = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }));
vi.mock('@/services/api', () => ({ apiClient: mocks }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: { id: 7, name: 'Example Bakery' } }) }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: () => false }));

const rollout: Rollout = {
  enabled: true,
  can_manage_invites: true,
  max_wave_size: 25,
  counts: { ready_to_invite: 2, invited: 0, active: 0, needs_contact_details: 0, locked: 0, former: 0 },
  candidates: [
    { id: 21, name: 'Sample One', email: 'one@example.test', email_ready: true },
    { id: 22, name: 'Sample Two', email: 'two@example.test', email_ready: true },
  ],
  todo: { locked: [], needs_contact_details: [], expiring: [], cleanup: [] },
  lock_alert: null,
};

describe('Employee app rollout', () => {
  afterEach(() => { cleanup(); vi.resetAllMocks(); });

  it('keeps selected employees across searches and shows the outcome for each employee', async () => {
    mocks.get.mockResolvedValue({ data: rollout });
    mocks.post.mockResolvedValue({ data: [
      { id: 21, email_status: 'failed' },
      { id: 22, error: 'This employee already has an invite. Resend it instead.' },
    ] });
    const user = userEvent.setup();
    render(<MemoryRouter><EmployeeAppRollout audience="client" /></MemoryRouter>);

    await user.click(await screen.findByRole('checkbox', { name: /Sample One/ }));
    await user.type(screen.getByRole('searchbox', { name: 'Find employees' }), 'Sample Two');
    await user.click(screen.getByRole('checkbox', { name: /Sample Two/ }));
    expect(screen.getByText('2 selected')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Send email invites' }));

    const results = within(await screen.findByRole('region', { name: 'Invite results' }));
    expect(results.getByText(/email could not be sent/)).toBeTruthy();
    expect(results.getByText(/already has an invite/)).toBeTruthy();
    expect(results.getByRole('link', { name: 'Sample One' }).getAttribute('href')).toContain('/companies/7/employees/21/overview');
    expect(mocks.post).toHaveBeenCalledWith('/client/employee_app_rollout/7/invite',
      { employee_ids: [21, 22], delivery: 'email' }, { companyId: 7 });
  });
});
