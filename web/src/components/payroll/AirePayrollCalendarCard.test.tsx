// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AirePayrollCalendarCard } from './AirePayrollCalendarCard';
import type { AirePayrollCalendarState } from '@/types';
const actions = vi.hoisted(() => ({ manage: false, publish: vi.fn(), refresh: vi.fn() }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: () => actions.manage }));
vi.mock('@/services/api', () => ({ payPeriodsApi: { publishAireCalendar: actions.publish, refreshAireCalendar: actions.refresh } }));
vi.mock('@/contexts/CompanyContext', (): { useCompany: () => { activeCompanyId: number; activeCompany: { id: number } } } => ({ useCompany: (): { activeCompanyId: number; activeCompany: { id: number } } => ({ activeCompanyId: 1, activeCompany: { id: 1 } }) }));
const calendar = { enabled: true, source_id: 1, source_name: 'Synthetic time tracking', eligible: true, cutoff_at: '2026-10-22T07:00:00Z', cutoff_state: 'cutoff_due', needs_revision: false, can_publish: false, can_retry: false } as AirePayrollCalendarState;
afterEach((): void => { cleanup(); vi.useRealTimers(); actions.manage = false; actions.publish.mockReset(); actions.refresh.mockReset(); });
it.each([['2026-10-22T07:00:00Z', 0], ['2026-10-22T07:00:01Z', 0], ['2026-10-22T09:00:00Z', 120]] as const)('shows pending lock and age at %s without claiming finalization', (now, minutes): void => {
  vi.useFakeTimers(); vi.setSystemTime(new Date(now));
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={calendar} onRefresh={vi.fn()} /></MemoryRouter>);
  expect(screen.getByText('Cutoff reached — waiting for time tracking to lock the hours')).toBeTruthy();
  expect(screen.getByText(/Waiting since.*ChST/).textContent).toContain(`(${minutes} minutes).`);
  expect(screen.queryByText('Batch finalized')).toBeNull();
});
it.each(['scheduled', 'batch_verifying', 'batch_rejected', 'batch_verified'] as const)('preserves authoritative %s state', (cutoff_state): void => {
  vi.useFakeTimers(); vi.setSystemTime(new Date('2026-10-22T06:59:59Z'));
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...calendar, cutoff_state }} onRefresh={vi.fn()} /></MemoryRouter>);
  expect(screen.queryByText('Cutoff reached — waiting for time tracking to lock the hours')).toBeNull();
});
it('shows known retry and error details on delayed delivery', (): void => {
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...calendar, publication: { id: 1, schedule_version: 1, publication_id: 'synthetic', delivery_status: 'failed', delivery_attempts: 2, last_error: 'Connection unavailable', next_delivery_attempt_at: '2026-10-22T09:00:00Z' } }} onRefresh={vi.fn()} /></MemoryRouter>);
  expect(screen.getByText(/Next retry:.*ChST/)).toBeTruthy();
  expect(screen.getByText('Connection unavailable')).toBeTruthy();
});
it('keeps a past nominal cutoff manual without a countdown or waiting warning', (): void => {
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...calendar, lock_mode: 'manual', cutoff_state: 'unpublished', can_publish: true }} onRefresh={vi.fn()} /></MemoryRouter>);
  expect(screen.getByText('Lock manually when you are ready')).toBeTruthy();
  expect(screen.queryByText(/Waiting since|Cutoff reached|until cutoff/)).toBeNull();
  expect(screen.getByText('Next: publish this period to time tracking')).toBeTruthy();
});
it('names the automatic Guam cutoff explicitly', (): void => {
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...calendar, lock_mode: 'scheduled', cutoff_state: 'scheduled', cutoff_at: '2026-11-07T17:00:00+10:00' }} onRefresh={vi.fn()} /></MemoryRouter>);
  expect(screen.getByText('Locks automatically Nov 7, 5:00 p.m. ChST')).toBeTruthy();
});

it('publishes a manual period through its enabled action after nominal cutoff', async () => {
  actions.manage = true;
  actions.publish.mockResolvedValue({});
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-10-24T00:00:00Z'));
  const refresh = vi.fn();
  const user = userEvent.setup();
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={17} calendar={{ ...calendar, lock_mode: 'manual', cutoff_state: 'unpublished', can_publish: true }} onRefresh={refresh} /></MemoryRouter>);
  await user.click(screen.getByRole('button', { name: 'Publish cutoff to time tracking' }));
  await waitFor(() => expect(actions.publish).toHaveBeenCalledExactlyOnceWith(17));
  expect(refresh).toHaveBeenCalledOnce();
});


it('reconciles the source calendar before refreshing the page', async () => {
  const user = userEvent.setup();
  const onRefresh = vi.fn();
  let finish!: () => void;
  actions.refresh.mockImplementation(() => new Promise<void>(resolve => { finish = resolve; }));
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={17} calendar={calendar} onRefresh={onRefresh} /></MemoryRouter>);
  await user.click(screen.getByRole('button', { name: 'Refresh' }));
  expect(actions.refresh).toHaveBeenCalledExactlyOnceWith(17);
  expect(onRefresh).not.toHaveBeenCalled();
  finish();
  await waitFor(() => expect(onRefresh).toHaveBeenCalledOnce());
});

it('shows a reconciliation failure without presenting an old page as refreshed', async () => {
  const user = userEvent.setup();
  const onRefresh = vi.fn();
  actions.refresh.mockRejectedValue(new Error('Calendar refresh failed'));
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={17} calendar={calendar} onRefresh={onRefresh} /></MemoryRouter>);
  await user.click(screen.getByRole('button', { name: 'Refresh' }));
  expect(await screen.findByText('Calendar refresh failed')).toBeTruthy();
  expect(onRefresh).not.toHaveBeenCalled();
});
describe('schedule eligibility note', () => {
  const ineligible = { ...calendar, eligible: false, cutoff_state: 'unpublished', eligibility_code: 'pay_schedule_not_effective', eligibility_error: 'This pay period begins before the confirmed payroll setup takes effect.' } as AirePayrollCalendarState;
  const linkedRecord = { source_cutoff_at: '2026-08-31T03:06:59Z' };
  it('stays neutral on a completed payroll with a linked record and drops the setup action', (): void => {
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={ineligible} payPeriodStatus="committed" linkedRecord={linkedRecord} onRefresh={vi.fn()} /></MemoryRouter>);
    expect(screen.getByText('Time tracking scheduling does not apply to this completed payroll')).toBeTruthy();
    expect(screen.getByText(ineligible.eligibility_error!).closest('[role="status"]')?.className).toContain('bg-neutral-50');
    expect(screen.queryByText('This run is not ready for time tracking scheduling')).toBeNull();
    expect(screen.queryByRole('link', { name: /pay schedule/i })).toBeNull();
  });
  it('keeps the warning and setup action on a completed payroll without a linked record', (): void => {
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={ineligible} payPeriodStatus="committed" onRefresh={vi.fn()} /></MemoryRouter>);
    expect(screen.getByText('This run is not ready for time tracking scheduling')).toBeTruthy();
    expect(screen.queryByText('Time tracking scheduling does not apply to this completed payroll')).toBeNull();
  });
  it('keeps the warning when a completed payroll has a batch still being verified', (): void => {
    const finalized_batch = { event_id: 'event-1', verification_status: 'pending', verification_attempts: 1, occurred_at: '2026-09-23T09:00:00+10:00' } as AirePayrollCalendarState['finalized_batch'];
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...ineligible, finalized_batch }} payPeriodStatus="committed" linkedRecord={linkedRecord} onRefresh={vi.fn()} /></MemoryRouter>);
    expect(screen.getByText('This run is not ready for time tracking scheduling')).toBeTruthy();
  });
  it('keeps a connection failure as an alert on a completed payroll', (): void => {
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...ineligible, publication: { id: 1, schedule_version: 1, publication_id: 'synthetic', delivery_status: 'failed', delivery_attempts: 2, last_error: 'Connection unavailable' } }} payPeriodStatus="committed" onRefresh={vi.fn()} /></MemoryRouter>);
    expect(screen.getByRole('alert').textContent).toContain('Connection unavailable');
  });
  it.each(['draft', 'calculated', 'approved', undefined] as const)('keeps the warning and setup action for %s', (payPeriodStatus): void => {
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={ineligible} payPeriodStatus={payPeriodStatus} onRefresh={vi.fn()} /></MemoryRouter>);
    expect(screen.getByText('This run is not ready for time tracking scheduling')).toBeTruthy();
    expect(screen.getByText(ineligible.eligibility_error!).closest('[role="status"]')?.className).toContain('bg-warning-50');
    expect(screen.getByRole('link', { name: /Open pay schedule and workweek/ })).toBeTruthy();
    cleanup();
  });
});
describe('committed run with a linked record and no schedule', () => {
  const linkedRecord = { source_cutoff_at: '2026-08-31T03:06:59Z' };
  const unpublished = { ...calendar, eligible: false, cutoff_at: null, cutoff_state: 'unpublished', publication: null, finalized_batch: null, eligibility_error: 'Synthetic setup note.' } as AirePayrollCalendarState;
  const expectRecorded = (): void => {
    expect(screen.getByText('Recorded with payroll')).toBeTruthy();
    expect(screen.getByText('No cutoff was scheduled; hours come from the linked time record. Held time stays separate.')).toBeTruthy();
    expect(screen.getByText(/Aug 31, 2026.*ChST/)).toBeTruthy();
    expect(screen.getByText('Not used for this payroll')).toBeTruthy();
    expect(screen.getByText('Linked time record')).toBeTruthy();
    expect(screen.queryByText(/Not published|No finalized batch received|Not sent|Automatic lock time unavailable|Not available/)).toBeNull();
  };
  it('describes the linked record instead of a schedule that never existed', (): void => {
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={unpublished} payPeriodStatus="committed" linkedRecord={linkedRecord} onRefresh={vi.fn()} /></MemoryRouter>);
    expectRecorded();
  });
  it('does not wait for a lock on a cutoff that was never published', (): void => {
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...unpublished, cutoff_at: '2026-08-24T07:00:00Z', cutoff_state: 'cutoff_due' }} payPeriodStatus="committed" linkedRecord={linkedRecord} onRefresh={vi.fn()} /></MemoryRouter>);
    expectRecorded();
    expect(screen.queryByText(/waiting for time tracking to lock/)).toBeNull();
    expect(screen.queryByText('Cutoff reached')).toBeNull();
  });
  it('keeps the real state and alert when a publication failed', (): void => {
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...unpublished, cutoff_state: 'publication_failed', publication: { id: 1, schedule_version: 1, publication_id: 'synthetic', delivery_status: 'failed', delivery_attempts: 2, last_error: 'Connection unavailable' } }} payPeriodStatus="committed" linkedRecord={linkedRecord} onRefresh={vi.fn()} /></MemoryRouter>);
    expect(screen.getByText('Sync needs attention')).toBeTruthy();
    expect(screen.getByText('Retry required')).toBeTruthy();
    expect(screen.getByRole('alert').textContent).toContain('Connection unavailable');
    expect(screen.queryByText('Recorded with payroll')).toBeNull();
  });
  it('keeps the batch state while a batch is being verified', (): void => {
    const finalized_batch = { event_id: 'event', verification_status: 'pending', verification_attempts: 1, occurred_at: '2026-10-22T07:00:00Z', payroll_batch_id: 'batch', payroll_batch_checksum: 'checksum' } as NonNullable<AirePayrollCalendarState['finalized_batch']>;
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...unpublished, finalized_batch }} payPeriodStatus="committed" linkedRecord={linkedRecord} onRefresh={vi.fn()} /></MemoryRouter>);
    expect(screen.getByText('Verification in progress')).toBeTruthy();
    expect(screen.queryByText('Recorded with payroll')).toBeNull();
  });
  it('keeps the schedule wording while publishing is still offered', (): void => {
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...unpublished, can_publish: true }} payPeriodStatus="committed" linkedRecord={linkedRecord} onRefresh={vi.fn()} /></MemoryRouter>);
    expect(screen.getByText('Not published')).toBeTruthy();
  });
  it('keeps the schedule wording without a linked record', (): void => {
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={unpublished} payPeriodStatus="committed" linkedRecord={null} onRefresh={vi.fn()} /></MemoryRouter>);
    expect(screen.getByText('Not published')).toBeTruthy();
    expect(screen.getByText('No finalized batch received')).toBeTruthy();
  });
  it.each(['draft', 'calculated', 'approved'] as const)('keeps the schedule wording on a %s run', (payPeriodStatus): void => {
    render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={unpublished} payPeriodStatus={payPeriodStatus} linkedRecord={linkedRecord} onRefresh={vi.fn()} /></MemoryRouter>);
    expect(screen.getByText('Not published')).toBeTruthy();
    expect(screen.getByText('No finalized batch received')).toBeTruthy();
    cleanup();
  });
});
