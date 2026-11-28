// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ReadinessOverrideActions } from './ReadinessOverrideActions';

const mocks = vi.hoisted(() => ({ allowed: true, unlocked: true, managed: true, options: vi.fn(), preview: vi.fn(), send: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({
  useOptionalAuth: () => ({ hasCapability: (cap: string) => mocks.allowed && cap === 'override_employee_readiness' }),
}));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompanyId: 1, activeCompany: { id: 1, client_managed_employee_lifecycle: mocks.managed, staff_employee_lifecycle_available: mocks.unlocked } }),
}));
vi.mock('@/lib/useOptionalStepUpRequest', () => ({ useOptionalStepUpRequest: () => mocks.send }));
vi.mock('@/services/staff-employee-lifecycle', () => ({ staffEmployeeLifecycleApi: { readinessOptions: mocks.options, readinessPreview: mocks.preview } }));

const options = {
  today: '2026-11-28', latest_expiration: '2026-12-28',
  pay_periods: [{ id: 14, start_date: '2026-11-16', end_date: '2026-11-29', pay_date: '2026-12-04' }],
  active_overrides: [{ id: 7, pay_period_id: 15, expires_on: null }],
};

beforeEach(() => {
  vi.resetAllMocks();
  mocks.allowed = true;
  mocks.unlocked = true;
  mocks.managed = true;
  mocks.options.mockResolvedValue({ data: options });
  mocks.preview.mockResolvedValue({ data: {
    default_w4_acknowledgement_required: true,
    checklist: { status: 'incomplete', rates_on: '2026-11-29', w4_on: '2026-12-04', missing_keys: ['tax_form'],
      items: [{ key: 'tax_form', label: 'W-4', complete: false, applicable: true, missing_label: 'W-4 missing' }] },
  } });
  mocks.send.mockResolvedValue({ ok: true });
});
afterEach(cleanup);
function open(payPeriodId?: number, gateEnforced = true) {
  const updated = vi.fn();
  render(<ReadinessOverrideActions companyId={1} employeeId={31} employeeName="Synthetic Worker" gateEnforced={gateEnforced} payPeriodId={payPeriodId} onUpdated={updated} />);
  return updated;
}

describe('Readiness override actions', () => {
  it.each(['role', 'unlock'])('keeps actions hidden without the %s', (requirement) => {
    if (requirement === 'role') mocks.allowed = false;
    else { mocks.unlocked = false; mocks.managed = false; }
    open();
    expect(screen.queryByRole('button', { name: 'Readiness override' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Clear readiness gate' })).toBeNull();
    expect(mocks.options).not.toHaveBeenCalled();
  });

  it('preselects the current pay period, lists missing items and requires Pub 15-T acknowledgement', async () => {
    const updated = open(14);
    const opener = screen.getByRole('button', { name: 'Readiness override' });
    opener.focus();
    fireEvent.click(opener);
    const dialog = screen.getByRole('dialog', { name: 'Readiness override' });
    const ack = await within(dialog).findByRole('checkbox', { name: /IRS Pub 15-T default/ });
    expect((within(dialog).getByLabelText('Pay period') as HTMLSelectElement).value).toBe('14');
    expect(within(dialog).getByText('W-4 missing')).toBeTruthy();
    const submit = within(dialog).getByRole('button', { name: 'Allow in payroll' }) as HTMLButtonElement;
    fireEvent.change(within(dialog).getByRole('textbox', { name: /Reason/ }), { target: { value: 'Pay wages while the signed W-4 is collected.' } });
    expect(submit.disabled).toBe(true);
    fireEvent.click(ack);
    fireEvent.click(submit);
    await waitFor(() => expect(updated).toHaveBeenCalled());
    expect(mocks.send).toHaveBeenCalledWith(1, 31, { action: 'grant', scope: { pay_period_id: 14 }, reason: 'Pay wages while the signed W-4 is collected.', default_w4_acknowledged: true });
    await waitFor(() => expect(document.activeElement).toBe(opener));
  });

  it('previews an expiration date and clears a gate only after the reason is entered', async () => {
    open();
    expect(await screen.findByText('Override active')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Readiness override' }));
    fireEvent.change(await screen.findByLabelText('Override scope'), { target: { value: 'expiration' } });
    fireEvent.change(screen.getByLabelText(/Expiration date/), { target: { value: '2026-12-17' } });
    await waitFor(() => expect(mocks.preview).toHaveBeenCalledWith(1, 31, { expires_on: '2026-12-17' }, expect.any(AbortSignal)));
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }));
    fireEvent.click(screen.getByRole('button', { name: 'Clear readiness gate' }));
    const clear = screen.getByRole('dialog', { name: 'Clear readiness gate' });
    expect((within(clear).getByRole('button', { name: 'Clear readiness gate' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(within(clear).getByRole('textbox'), { target: { value: 'Original staff roster was imported in error.' } });
    fireEvent.click(within(clear).getByRole('button', { name: 'Clear readiness gate' }));
    await waitFor(() => expect(mocks.send).toHaveBeenCalledWith(1, 31, { action: 'clear', reason: 'Original staff roster was imported in error.' }));
  });

  it('keeps grant, clear and revoke available for a gated employee after rollback', async () => {
    mocks.managed = false;
    open();
    expect(screen.getByRole('button', { name: 'Readiness override' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Clear readiness gate' })).toBeTruthy();
    expect(await screen.findByRole('button', { name: 'Revoke override' })).toBeTruthy();
  });

  it('revokes a residual override after rollback and focuses the result when its opener disappears', async () => {
    mocks.managed = false;
    mocks.options.mockResolvedValueOnce({ data: options }).mockResolvedValue({ data: { ...options, active_overrides: [] } });
    open(undefined, false);
    const revoke = await screen.findByRole('button', { name: 'Revoke override' });
    expect(screen.queryByRole('button', { name: 'Readiness override' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Clear readiness gate' })).toBeNull();
    fireEvent.click(revoke);
    const dialog = screen.getByRole('dialog', { name: 'Revoke readiness override' });
    const reason = within(dialog).getByRole('textbox', { name: /Reason/ });
    expect(document.activeElement).toBe(reason);
    fireEvent.change(reason, { target: { value: 'Setup was completed today.' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Revoke readiness override' }));
    expect(await screen.findByText('Readiness override revoked.')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Revoke override' })).toBeNull();
    await waitFor(() => expect(document.activeElement).toBe(screen.getByText('Readiness override revoked.')));
    expect(mocks.send).toHaveBeenCalledWith(1, 31, { action: 'revoke', overrideId: 7, reason: 'Setup was completed today.' });
  });

  it('explains how to continue when no pay periods are open and flags out-of-range dates', async () => {
    mocks.options.mockResolvedValue({ data: { ...options, pay_periods: [], active_overrides: [] } });
    open();
    fireEvent.click(screen.getByRole('button', { name: 'Readiness override' }));
    expect(await screen.findByText('No pay periods are open. Choose an expiration date to continue.')).toBeTruthy();
    fireEvent.change(screen.getByLabelText('Override scope'), { target: { value: 'expiration' } });
    fireEvent.change(screen.getByLabelText(/Expiration date/), { target: { value: '2026-12-29' } });
    expect(screen.getByText('Choose a date from Nov 28, 2026 through Dec 28, 2026.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Allow in payroll' })).toHaveProperty('disabled', true);
    expect(mocks.preview).not.toHaveBeenCalled();
  });

  it('explains when a worker is already ready to pay', async () => {
    mocks.preview.mockResolvedValue({ data: { default_w4_acknowledgement_required: false, checklist: {
      status: 'ready', rates_on: '2026-11-29', w4_on: '2026-12-04', missing_keys: [], items: [],
    } } });
    open();
    fireEvent.click(screen.getByRole('button', { name: 'Readiness override' }));
    expect(await screen.findByText('This employee is ready to pay for this scope and does not need an override.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Allow in payroll' })).toHaveProperty('disabled', true);
  });

  it('stops a duplicate pay-period grant before preview or sign-in verification', async () => {
    mocks.options.mockResolvedValue({ data: { ...options, active_overrides: [{ ...options.active_overrides[0], pay_period_id: 14 }] } });
    open(14);
    fireEvent.click(screen.getByRole('button', { name: 'Readiness override' }));
    expect(await screen.findByText(/An override is already active for this pay period/)).toBeTruthy();
    fireEvent.change(screen.getByRole('textbox', { name: /Reason/ }), { target: { value: 'This override already exists.' } });
    expect(screen.getByRole('button', { name: 'Allow in payroll' })).toHaveProperty('disabled', true);
    expect(mocks.preview).not.toHaveBeenCalled();
    expect(mocks.send).not.toHaveBeenCalled();
  });
});
