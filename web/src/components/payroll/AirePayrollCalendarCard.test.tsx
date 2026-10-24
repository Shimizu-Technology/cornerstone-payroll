// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { AirePayrollCalendarCard } from './AirePayrollCalendarCard';
import type { AirePayrollCalendarState } from '@/types';
const actions = vi.hoisted(() => ({ manage: false, publish: vi.fn() }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: () => actions.manage }));
vi.mock('@/services/api', () => ({ payPeriodsApi: { publishAireCalendar: actions.publish } }));
vi.mock('@/contexts/CompanyContext', (): { useCompany: () => { activeCompanyId: number; activeCompany: { id: number } } } => ({ useCompany: (): { activeCompanyId: number; activeCompany: { id: number } } => ({ activeCompanyId: 1, activeCompany: { id: 1 } }) }));
const calendar = { enabled: true, source_id: 1, source_name: 'Synthetic time tracking', eligible: true, cutoff_at: '2026-10-22T07:00:00Z', cutoff_state: 'cutoff_due', needs_revision: false, can_publish: false, can_retry: false } as AirePayrollCalendarState;
afterEach((): void => { cleanup(); vi.useRealTimers(); actions.manage = false; actions.publish.mockReset(); });
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
