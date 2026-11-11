// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AireLockTimeControl } from './AireLockTimeControl';
import type { AirePayrollCalendarState } from '@/types';

const mocks = vi.hoisted(() => ({ capabilities: new Set<string>(), change: vi.fn() }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: (capability: string) => mocks.capabilities.has(capability) }));
vi.mock('@/services/api', () => ({ payPeriodsApi: { changeAireCutoff: mocks.change } }));

const now = new Date('2026-11-19T09:00:00+10:00');
const calendar = {
  enabled: true, source_id: 1, source_name: 'AIRE', eligible: true, needs_revision: false, can_publish: false, can_retry: false,
  cutoff_state: 'scheduled', lock_mode: 'scheduled', cutoff_at: '2026-11-22T17:00:00+10:00', cutoff_source: 'policy',
  policy_cutoff_at: '2026-11-22T17:00:00+10:00', cutoff_override: null,
  cutoff_control: {
    available: true, lock_now_available: true, reset_available: false, earliest_at: '2026-11-19T09:00:00+10:00',
    latest_at: '2026-11-28T23:59:00+10:00', lock_now_available_at: '2026-11-16T00:00:00+10:00', unavailable_reason: null,
  },
} as AirePayrollCalendarState;

function renderControl(state: AirePayrollCalendarState = calendar, onChanged = vi.fn()) {
  render(<AireLockTimeControl payPeriodId={42} calendar={state} companyId={1} now={now} onChanged={onChanged} />);
  return onChanged;
}

afterEach(() => { cleanup(); mocks.capabilities = new Set(); mocks.change.mockReset(); });

describe('AireLockTimeControl', () => {
  it('shows the countdown to everyone who can see the calendar, without actions for other roles', () => {
    renderControl();
    expect(screen.getByText('Locks Sun, Nov 22 at 5:00 PM')).toBeTruthy();
    expect(screen.getByText('(in 3 days)')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Lock now|Change lock time/ })).toBeNull();
    expect(screen.getByRole('button', { name: 'About the AIRE lock time' })).toBeTruthy();
  });

  it('shows who changed the lock and why', () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    renderControl({
      ...calendar, cutoff_source: 'override', cutoff_at: '2026-11-21T12:00:00+10:00',
      cutoff_override: { override_id: 'o1', action: 'change', reason: 'Thanksgiving payroll run', set_at: '2026-11-18T09:00:00+10:00', set_by_name: 'Chels', requested_via: 'aire_services', previous_cutoff_at: '2026-11-22T17:00:00+10:00' },
      cutoff_control: { ...calendar.cutoff_control!, reset_available: true },
    });
    expect(screen.getByText('Changed by Chels in AIRE: Thanksgiving payroll run')).toBeTruthy();
    expect(screen.getByText('Default was Sun, Nov 22 at 5:00 PM.')).toBeTruthy();
    expect(screen.getByRole('button', { name: /Reset to default/ })).toBeTruthy();
  });

  it('locks now after a reason and the late-hours confirmation', async () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    mocks.change.mockResolvedValue({ aire_payroll_calendar: calendar, idempotent: false });
    const onChanged = renderControl();
    const user = userEvent.setup();

    await user.click(screen.getByRole('button', { name: /Lock now/ }));
    const dialog = screen.getByRole('dialog', { name: 'Lock hours now?' });
    expect(dialog.textContent).toContain("AIRE locks this period's hours right away instead of Sun, Nov 22 at 5:00 PM.");
    expect(dialog.textContent).toContain('go to the next pay period as late hours');

    await user.click(screen.getAllByRole('button', { name: 'Lock now' }).at(-1)!);
    expect(screen.getByRole('alert').textContent).toBe('Enter a reason for the change.');
    expect(mocks.change).not.toHaveBeenCalled();

    await user.type(screen.getByLabelText(/Reason/), 'All approvals are in');
    await user.click(screen.getAllByRole('button', { name: 'Lock now' }).at(-1)!);
    await waitFor(() => expect(onChanged).toHaveBeenCalled());
    expect(mocks.change).toHaveBeenCalledWith(42, expect.objectContaining({ lock_action: 'lock_now', reason: 'All approvals are in' }));
    expect(mocks.change.mock.calls[0][1]).not.toHaveProperty('cutoff_at');
  });

  it('moves the lock within the allowed range and shows server refusals', async () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    mocks.change.mockRejectedValueOnce(new Error('Choose a time at least two days before payday'));
    renderControl();
    const user = userEvent.setup();

    await user.click(screen.getByRole('button', { name: /Change lock time/ }));
    const input = screen.getByLabelText(/New lock time/) as HTMLInputElement;
    expect(input.min).toBe('2026-11-19T09:00');
    expect(input.max).toBe('2026-11-28T23:59');
    await user.type(screen.getByLabelText(/Reason/), 'Payday moved');

    await user.clear(input);
    await user.type(input, '2026-11-29T09:00');
    await user.click(screen.getByRole('button', { name: 'Save lock time' }));
    expect(screen.getByRole('alert').textContent).toBe('Choose a time between Thu, Nov 19 at 9:00 AM and Sat, Nov 28 at 11:59 PM.');

    await user.clear(input);
    await user.type(input, '2026-11-25T17:00');
    await user.click(screen.getByRole('button', { name: 'Save lock time' }));
    await waitFor(() => expect(mocks.change).toHaveBeenCalledWith(42, expect.objectContaining({ lock_action: 'change', cutoff_at: '2026-11-25T17:00:00+10:00' })));
    expect((await screen.findByRole('alert')).textContent).toBe('Choose a time at least two days before payday');
    expect(screen.getByRole('dialog')).toBeTruthy();
  });

  it('explains why an admin cannot change it and stays out of manual calendars', () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    renderControl({ ...calendar, cutoff_control: { ...calendar.cutoff_control!, available: false, lock_now_available: false, unavailable_reason: 'It is too close to payday to change the lock time' } });
    expect(screen.getByText('It is too close to payday to change the lock time.')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Change lock time/ })).toBeNull();
    cleanup();
    renderControl({ ...calendar, lock_mode: 'manual' });
    expect(screen.queryByText(/AIRE lock time/)).toBeNull();
  });
});
