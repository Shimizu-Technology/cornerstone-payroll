// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ReadinessOverrideActions } from './ReadinessOverrideActions';

const mocks = vi.hoisted(() => ({ allowed: true, enabled: true, options: vi.fn(), preview: vi.fn(), send: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({
  useOptionalAuth: () => ({ hasCapability: (cap: string) => mocks.allowed && cap === 'override_employee_readiness' }),
}));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompanyId: 1, activeCompany: { id: 1, client_managed_employee_lifecycle: mocks.enabled } }),
}));
vi.mock('@/lib/useOptionalStepUpRequest', () => ({ useOptionalStepUpRequest: () => mocks.send }));
vi.mock('@/services/staff-employee-lifecycle', () => ({ staffEmployeeLifecycleApi: { readinessOptions: mocks.options, readinessPreview: mocks.preview } }));

beforeEach(() => {
  vi.clearAllMocks();
  mocks.allowed = true;
  mocks.enabled = true;
  mocks.options.mockResolvedValue({ data: {
    today: '2026-11-28', latest_expiration: '2026-12-28',
    pay_periods: [{ id: 14, start_date: '2026-11-16', end_date: '2026-11-29', pay_date: '2026-12-04' }],
    active_overrides: [{ id: 7, pay_period_id: 14, expires_on: null, reason: 'Synthetic reason' }],
  } });
  mocks.preview.mockResolvedValue({ data: {
    default_w4_acknowledgement_required: true,
    checklist: { status: 'incomplete', rates_on: '2026-11-29', w4_on: '2026-12-04', missing_keys: ['tax_form'],
      items: [{ key: 'tax_form', label: 'W-4', complete: false, applicable: true, missing_label: 'W-4 missing' }] },
  } });
  mocks.send.mockResolvedValue({ ok: true });
});
afterEach(cleanup);
function open(payPeriodId?: number) {
  const updated = vi.fn();
  render(<ReadinessOverrideActions companyId={1} employeeId={31} employeeName="Synthetic Worker" payPeriodId={payPeriodId} onUpdated={updated} />);
  return updated;
}

describe('Readiness override actions', () => {
  it.each(['role', 'mode'])('keeps actions hidden without the %s', (requirement) => {
    if (requirement === 'role') mocks.allowed = false;
    else mocks.enabled = false;
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
});
