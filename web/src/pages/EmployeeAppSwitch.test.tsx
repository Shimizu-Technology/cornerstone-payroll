// @vitest-environment jsdom
import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CompanyListItem } from '@/services/api';
import type { EmployeeAppSwitchState, ReadinessCheck } from '@/services/employee-app-switch-api';
import { EmployeeAppSwitch } from './EmployeeAppSwitch';

const mocks = vi.hoisted(() => ({
  get: vi.fn(),
  send: vi.fn(),
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ user: { id: 7, role: 'org_admin' }, isLoading: false, hasCapability: () => true }),
}));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({
    activeCompany: { id: 6, name: 'Example Grill' } as unknown as CompanyListItem,
    activeCompanyId: 6,
    loading: false,
  }),
}));
vi.mock('@/lib/useOptionalStepUpRequest', () => ({
  useOptionalStepUpRequest: () => mocks.send,
}));
vi.mock('@clerk/react/errors', () => ({ isReverificationCancelledError: () => false }));
vi.mock('@/services/employee-app-switch-api', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/services/employee-app-switch-api')>()),
  employeeAppSwitchApi: { get: mocks.get },
}));

const passed = (key: string, name: string): ReadinessCheck => ({ key, name, status: 'passed', detail: null });

function state(overrides: Partial<EmployeeAppSwitchState> = {}, checks?: ReadinessCheck[]): EmployeeAppSwitchState {
  const platform = checks ?? [
    passed('company', 'This is a live client or a demo company'),
    passed('mfa', 'Two-step sign-in is required (REQUIRE_MFA=true with the two-step claim)'),
    { key: 'rls_guard', name: 'The employee service refuses any database read without a company (RLS guard in raise mode)', status: 'failed',
      detail: "The employee service's guard is set to log, not raise." },
    passed('rls_database', 'The database enforces company separation (row-level security on)'),
  ];
  const blocked = platform.filter((check) => check.status === 'failed').map((check) => check.key);
  return {
    company: { id: 6, name: 'Example Grill', demo: false, live: true, subdomain_slug: 'example-grill' },
    switches: [
      { key: 'employee_portal_enabled', label: 'Employee app', description: 'Employees can sign up.', on: false, open_today: false, feature: false, blocked_by: blocked },
      { key: 'employee_portal.features.stubs', label: 'Pay stubs', description: 'Employees can view stubs.', on: false, open_today: false, feature: true, blocked_by: blocked },
    ],
    stays_off: [{ key: 'employee_portal.features.bank_requests', label: 'Bank account changes', description: 'Stays off.' }],
    readiness: {
      checked_at: '2026-11-25T01:00:00Z',
      checks: platform,
      counsel_checks: {
        terms: passed('terms', 'Employee App Terms and Privacy Notice wording is approved by counsel'),
        consent: passed('consent', 'Electronic delivery consent wording is approved by counsel'),
      },
      switch_checks: {},
      observed: { reported: true, fresh: true, observed_at: '2026-11-25T00:59:00Z', revision: 'abc', rls_guard_mode: 'log',
        rls_runtime_role_verified: true, dependencies_healthy: true, answered_health_check: true, health_check_configured: true },
      database: { phase: 'shadow', enforced: false, enforced_tables: 0, protected_tables: 120 },
      early_access: null,
    },
    early_access: { name: 'Demo early access before database enforcement', max_days: 31, max_companies: 2, demo_companies: [], windows: [] },
    ...overrides,
  };
}

function json(status: number, body: unknown) {
  return { ok: status < 400, status, json: async () => body } as Response;
}

function renderPage() {
  return render(<MemoryRouter><EmployeeAppSwitch /></MemoryRouter>);
}

describe('EmployeeAppSwitch', () => {
  beforeEach(() => {
    mocks.get.mockReset();
    mocks.send.mockReset();
  });
  afterEach(cleanup);

  it('names each failing check and keeps turn-on disabled while it fails', async () => {
    mocks.get.mockResolvedValue({ data: state() });
    renderPage();

    expect(await screen.findByText('Readiness checklist')).toBeTruthy();
    expect(screen.getByText("The employee service's guard is set to log, not raise.")).toBeTruthy();
    const row = screen.getByText('Employee app', { selector: 'p' }).closest('li') as HTMLElement;
    expect(within(row).getByText(/Can't turn on yet: The employee service refuses any database read without a company/)).toBeTruthy();
    expect((within(row).getByRole('button', { name: 'Turn on' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText('Locked off')).toBeTruthy();
    // Observed guard and database state are shown separately.
    expect(screen.getByText('Log only')).toBeTruthy();
    expect(screen.getByText('Shadow (policies installed, not enforced)')).toBeTruthy();
  });

  it('turns a part off with a reason, without needing the checks', async () => {
    const on = state();
    on.switches[0] = { ...on.switches[0], on: true, open_today: true };
    mocks.get.mockResolvedValue({ data: on });
    const after = state();
    mocks.send.mockResolvedValue(json(200, { data: after }));
    renderPage();

    const row = (await screen.findByText('Employee app', { selector: 'p' })).closest('li') as HTMLElement;
    await userEvent.click(within(row).getByRole('button', { name: 'Turn off' }));
    const dialog = await screen.findByRole('dialog');
    const confirm = within(dialog).getByRole('button', { name: 'Turn off' }) as HTMLButtonElement;
    expect(confirm.disabled).toBe(true);
    await userEvent.type(within(dialog).getByLabelText('Reason'), 'Pause the pilot');
    await userEvent.click(confirm);

    await waitFor(() => expect(screen.getByText('Employee app is off.')).toBeTruthy());
    expect(mocks.send).toHaveBeenCalledWith({ method: 'PATCH', suffix: '', body: { changes: { employee_portal_enabled: false }, reason: 'Pause the pilot' } });
  });

  it('lists the failing checks the server returns when a turn-on is refused', async () => {
    const ready = state({}, [passed('company', 'This is a live client or a demo company')]);
    mocks.get.mockResolvedValue({ data: ready });
    mocks.send.mockResolvedValue(json(422, {
      error: 'Not ready to turn on yet. Fix the failing checks first.', code: 'not_ready',
      failing_checks: [{ key: 'employee_service', name: 'The employee service is running and healthy', status: 'failed', detail: "The employee service didn't answer its health check." }],
    }));
    renderPage();

    const row = (await screen.findByText('Employee app', { selector: 'p' })).closest('li') as HTMLElement;
    await userEvent.click(within(row).getByRole('button', { name: 'Turn on' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.type(within(dialog).getByLabelText('Reason'), 'Pilot week 1');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Turn on' }));

    expect(await within(dialog).findByText(/The employee service is running and healthy/)).toBeTruthy();
    expect(within(dialog).getByText('Not ready to turn on yet. Fix the failing checks first.')).toBeTruthy();
  });

  it('shows demo early access and the kill switch only for a demo company', async () => {
    const demo = state({
      company: { id: 6, name: 'Harbor Finch Kitchen', demo: true, live: false, subdomain_slug: 'harborfinch' },
      early_access: { name: 'Demo early access before database enforcement', max_days: 31, max_companies: 2,
        demo_companies: [{ id: 6, name: 'Harbor Finch Kitchen' }], windows: [] },
    });
    mocks.get.mockResolvedValue({ data: demo });
    mocks.send.mockResolvedValue(json(200, { data: demo }));
    renderPage();

    expect(await screen.findByText('Demo early access before database enforcement')).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Stop demo employee access' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.type(within(dialog).getByLabelText('Reason'), 'Leak suspected');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Stop demo access' }));
    await waitFor(() => expect(mocks.send).toHaveBeenCalledWith({ method: 'POST', suffix: '/demo_stop', body: { reason: 'Leak suspected' } }));
    expect(await screen.findByText('Demo employee access stopped.')).toBeTruthy();
  });

  it('hides demo tools for a real company', async () => {
    mocks.get.mockResolvedValue({ data: state() });
    renderPage();
    await screen.findByText('Readiness checklist');
    expect(screen.queryByText('Stop all demo employee access')).toBeNull();
  });
});
