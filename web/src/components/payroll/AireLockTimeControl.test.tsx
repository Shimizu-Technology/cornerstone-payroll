// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AireLockTimeControl } from './AireLockTimeControl';
import type { AirePayrollCalendarState } from '@/types';

const mocks = vi.hoisted(() => ({ capabilities: new Set<string>(), change: vi.fn() }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: (capability: string) => mocks.capabilities.has(capability) }));
vi.mock('@/services/api', () => ({ payPeriodsApi: { changeAireCutoff: mocks.change } }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1 }) }));

const now = new Date('2026-11-19T09:00:00+10:00');
const calendar = {
  enabled: true, source_id: 1, source_name: 'AIRE', eligible: true, needs_revision: false, can_publish: false, can_retry: false,
  cutoff_state: 'scheduled', lock_mode: 'scheduled', cutoff_at: '2026-11-22T17:00:00+10:00', cutoff_source: 'policy',
  policy_cutoff_at: '2026-11-22T17:00:00+10:00', cutoff_override: null,
  cutoff_control: {
    available: true, lock_now_available: true, reset_available: false, earliest_at: '2026-11-19T09:15:00+10:00',
    latest_at: '2026-11-28T23:59:00+10:00', lock_now_available_at: '2026-11-16T00:00:00+10:00', unavailable_reason: null,
  },
} as AirePayrollCalendarState;

function renderControl(state: AirePayrollCalendarState = calendar, onChanged = vi.fn()) {
  render(<AireLockTimeControl payPeriodId={42} calendar={state} companyId={1} now={now} onChanged={onChanged} />);
  return onChanged;
}

const refused = { state: 'rejected', schedule_version: 3, cutoff_at: '2026-11-19T09:03:00+10:00', cutoff_source: 'override', action: 'change', error: 'cutoff_at must be in the future when published', last_delivery_attempt_at: '2026-11-19T09:05:00+10:00' } as const;

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
    expect(input.min).toBe('2026-11-19T09:15');
    // Starts at the lock AIRE has, which can't be saved unchanged.
    expect(input.value).toBe('2026-11-22T17:00');
    expect((screen.getByRole('button', { name: 'Save lock time' }) as HTMLButtonElement).disabled).toBe(true);
    expect(input.max).toBe('2026-11-28T23:59');
    await user.type(screen.getByLabelText(/Reason/), 'Payday moved');

    await user.clear(input);
    await user.type(input, '2026-11-29T09:00');
    await user.click(screen.getByRole('button', { name: 'Save lock time' }));
    expect(screen.getByRole('alert').textContent).toBe('Choose a time between Thu, Nov 19 at 9:15 AM and Sat, Nov 28 at 11:59 PM.');

    await user.clear(input);
    await user.type(input, '2026-11-25T17:00');
    await user.click(screen.getByRole('button', { name: 'Save lock time' }));
    await waitFor(() => expect(mocks.change).toHaveBeenCalledWith(42, expect.objectContaining({ lock_action: 'change', cutoff_at: '2026-11-25T17:00:00+10:00' })));
    expect((await screen.findByRole('alert')).textContent).toBe('Choose a time at least two days before payday');
    expect(screen.getByRole('dialog')).toBeTruthy();
  });

  it('keeps the minimum 15 minutes ahead even when the server bound has aged', async () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    render(<AireLockTimeControl payPeriodId={42} calendar={calendar} companyId={1} now={new Date('2026-11-19T09:40:30+10:00')} onChanged={vi.fn()} />);
    await userEvent.setup().click(screen.getByRole('button', { name: /Change lock time/ }));
    expect((screen.getByLabelText(/New lock time/) as HTMLInputElement).min).toBe('2026-11-19T09:56');
    expect(screen.getByText(/Between Thu, Nov 19 at 9:56 AM \(at least 15 minutes from now\)/)).toBeTruthy();
  });

  it('shows the lock AIRE has while a newer change is still being delivered', () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    renderControl({
      ...calendar, cutoff_at: '2026-11-24T17:00:00+10:00', cutoff_source: 'override',
      cutoff_override: { override_id: 'o2', action: 'change', reason: 'Holiday', set_at: '2026-11-19T08:59:00+10:00', set_by_name: 'Chels', requested_via: 'cornerstone_payroll', previous_cutoff_at: '2026-11-22T17:00:00+10:00' },
      applied_cutoff_at: '2026-11-22T17:00:00+10:00', applied_cutoff_override: null,
      cutoff_delivery: { state: 'pending', schedule_version: 2, cutoff_at: '2026-11-24T17:00:00+10:00', cutoff_source: 'override', action: 'change', error: null, last_delivery_attempt_at: null },
      cutoff_control: { ...calendar.cutoff_control!, available: false, lock_now_available: false, unavailable_reason: 'Waiting for AIRE to confirm the last change' },
    });
    expect(screen.getByText('Locks Sun, Nov 22 at 5:00 PM')).toBeTruthy();
    expect(screen.getByRole('status').textContent).toBe('Waiting for AIRE to confirm the change to Tue, Nov 24 at 5:00 PM. Until it does, AIRE keeps the lock time above.');
    expect(screen.queryByText(/Changed by/)).toBeNull();
    expect(screen.queryByRole('button', { name: /Lock now|Change lock time/ })).toBeNull();
  });

  it("says AIRE rejected a change and lets an admin replace it", () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    renderControl({
      ...calendar, cutoff_at: '2026-11-19T09:03:00+10:00', cutoff_source: 'override',
      applied_cutoff_at: '2026-11-21T12:00:00+10:00',
      applied_cutoff_override: { action: 'change', reason: 'Thanksgiving payroll run', set_by_name: 'Leon', requested_via: 'aire_services', policy_cutoff_at: '2026-11-22T17:00:00+10:00' },
      cutoff_delivery: { state: 'rejected', schedule_version: 3, cutoff_at: '2026-11-19T09:03:00+10:00', cutoff_source: 'override', action: 'change', error: 'cutoff_at must be in the future when published', last_delivery_attempt_at: '2026-11-19T09:05:00+10:00' },
    });
    expect(screen.getByText('Locks Sat, Nov 21 at 12:00 PM')).toBeTruthy();
    expect(screen.getByText('Changed by Leon in AIRE: Thanksgiving payroll run')).toBeTruthy();
    const note = screen.getByRole('status');
    expect(note.textContent).toContain('AIRE rejected the change to Thu, Nov 19 at 9:03 AM: cutoff_at must be in the future when published');
    expect(note.textContent).toContain('The lock time above is still in effect. Lock now or choose a new time to replace the rejected change.');
    expect(screen.getByRole('button', { name: /Change lock time/ })).toBeTruthy();
  });

  it('lets an admin save the lock AIRE has to replace a change it did not apply', async () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    renderControl({ ...calendar, cutoff_delivery: { ...refused, state: 'expired', error: null } });
    expect(screen.getByRole('status').textContent).toContain("The change to Thu, Nov 19 at 9:03 AM didn't reach AIRE in time, so AIRE didn't apply it.");
    await userEvent.setup().click(screen.getByRole('button', { name: /Change lock time/ }));
    expect((screen.getByLabelText(/New lock time/) as HTMLInputElement).value).toBe('2026-11-22T17:00');
    expect((screen.getByRole('button', { name: 'Save lock time' }) as HTMLButtonElement).disabled).toBe(false);
  });

  it('offers only what the admin can still do to replace a refused change', () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    renderControl({ ...calendar, cutoff_delivery: refused, cutoff_control: { ...calendar.cutoff_control!, lock_now_available: false } });
    expect(screen.getByRole('status').textContent).toContain('The lock time above is still in effect. Choose a new time to replace the rejected change.');
    cleanup();
    renderControl({ ...calendar, cutoff_delivery: refused, cutoff_control: { ...calendar.cutoff_control!, available: false, lock_now_available: false, unavailable_reason: 'It is too close to payday to change the lock time' } });
    const note = screen.getByRole('status').textContent ?? '';
    expect(note).toContain('AIRE rejected the change to Thu, Nov 19 at 9:03 AM: cutoff_at must be in the future when published');
    expect(note.endsWith('The lock time above is still in effect.')).toBe(true);
  });

  it('drops the delivery note once the lock AIRE has is reached', () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    renderControl({ ...calendar, applied_cutoff_at: '2026-11-19T08:00:00+10:00', cutoff_delivery: refused });
    expect(screen.getByText('Lock time reached')).toBeTruthy();
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('moves a time that slipped under the 15-minute minimum before sending it', async () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    const props = { payPeriodId: 42, calendar, companyId: 1, onChanged: vi.fn() };
    const { rerender } = render(<AireLockTimeControl {...props} now={now} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: /Change lock time/ }));
    const input = screen.getByLabelText(/New lock time/) as HTMLInputElement;
    await user.clear(input);
    await user.type(input, '2026-11-19T09:15');
    await user.type(screen.getByLabelText(/Reason/), 'Lock early');

    // A minute and a half later the earliest allowed minute is 9:17.
    rerender(<AireLockTimeControl {...props} now={new Date('2026-11-19T09:01:30+10:00')} />);
    await user.click(screen.getByRole('button', { name: 'Save lock time' }));
    expect(screen.getByRole('alert').textContent).toBe('The lock time must be at least 15 minutes from now, so the earliest is now Thu, Nov 19 at 9:17 AM. Check the new time and save again.');
    expect(input.value).toBe('2026-11-19T09:17');
    expect(mocks.change).not.toHaveBeenCalled();

    mocks.change.mockResolvedValue({ aire_payroll_calendar: calendar, idempotent: false });
    await user.click(screen.getByRole('button', { name: 'Save lock time' }));
    await waitFor(() => expect(mocks.change).toHaveBeenCalledWith(42, expect.objectContaining({
      lock_action: 'change',
      cutoff_at: '2026-11-19T09:17:00+10:00',
    })));
  });

  it('does not send a time once the 15-minute minimum passes the latest allowed time', async () => {
    mocks.capabilities.add('manage_time_tracking_lock');
    const closing = { ...calendar, cutoff_control: { ...calendar.cutoff_control!, latest_at: '2026-11-19T09:20:00+10:00' } };
    const props = { payPeriodId: 42, companyId: 1, onChanged: vi.fn() };
    const { rerender } = render(<AireLockTimeControl {...props} calendar={closing} now={now} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: /Change lock time/ }));
    await user.type(screen.getByLabelText(/Reason/), 'Lock early');

    // Six minutes later the earliest allowed minute, 9:21, is past the latest, 9:20.
    rerender(<AireLockTimeControl {...props} calendar={closing} now={new Date('2026-11-19T09:06:00+10:00')} />);
    await user.click(screen.getByRole('button', { name: 'Save lock time' }));
    expect(screen.getByRole('alert').textContent).toBe('No lock time is left to choose: it must be at least 15 minutes from now and no later than Thu, Nov 19 at 9:20 AM. Use Lock now instead.');
    expect(mocks.change).not.toHaveBeenCalled();

    const noLockNow = { ...closing, cutoff_control: { ...closing.cutoff_control, lock_now_available: false } };
    rerender(<AireLockTimeControl {...props} calendar={noLockNow} now={new Date('2026-11-19T09:06:00+10:00')} />);
    await user.click(screen.getByRole('button', { name: 'Save lock time' }));
    expect(screen.getByRole('alert').textContent).toBe('No lock time is left to choose: it must be at least 15 minutes from now and no later than Thu, Nov 19 at 9:20 AM.');
    expect(mocks.change).not.toHaveBeenCalled();
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
