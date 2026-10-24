// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { AirePayrollCalendarCard } from './AirePayrollCalendarCard';
import type { AirePayrollCalendarState } from '@/types';
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: () => false }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1, activeCompany: { id: 1 } }) }));
const calendar = { enabled: true, source_id: 1, source_name: 'Synthetic time tracking', eligible: true, cutoff_at: '2026-10-22T07:00:00Z', cutoff_state: 'cutoff_due', needs_revision: false, can_publish: false, can_retry: false } as AirePayrollCalendarState;
afterEach(() => { cleanup(); vi.useRealTimers(); });
it.each(['2026-10-22T07:00:00Z', '2026-10-22T07:00:01Z', '2026-10-22T09:00:00Z'])('shows pending lock and age at %s without claiming finalization', now => {
  vi.useFakeTimers(); vi.setSystemTime(new Date(now));
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={calendar} onRefresh={vi.fn()} /></MemoryRouter>);
  expect(screen.getByText('Cutoff reached — waiting for time tracking to lock the hours')).toBeTruthy();
  expect(screen.getByText(/Waiting since.*ChST/)).toBeTruthy();
  expect(screen.queryByText('Batch finalized')).toBeNull();
});
it.each(['scheduled', 'batch_verifying', 'batch_rejected', 'batch_verified'] as const)('preserves authoritative %s state', cutoff_state => {
  vi.useFakeTimers(); vi.setSystemTime(new Date('2026-10-22T06:59:59Z'));
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...calendar, cutoff_state }} onRefresh={vi.fn()} /></MemoryRouter>);
  expect(screen.queryByText('Cutoff reached — waiting for time tracking to lock the hours')).toBeNull();
});
it('shows known retry and error details on delayed delivery', () => {
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={{ ...calendar, publication: { id: 1, schedule_version: 1, publication_id: 'synthetic', delivery_status: 'failed', delivery_attempts: 2, last_error: 'Connection unavailable', next_delivery_attempt_at: '2026-10-22T09:00:00Z' } }} onRefresh={vi.fn()} /></MemoryRouter>);
  expect(screen.getByText(/Next retry:.*ChST/)).toBeTruthy();
  expect(screen.getByText('Connection unavailable')).toBeTruthy();
});
