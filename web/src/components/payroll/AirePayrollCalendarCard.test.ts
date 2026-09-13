// @vitest-environment jsdom

import { createElement } from 'react';
import { act, cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cutoffDistance, lockedBatchCopy } from '@/lib/aire-payroll-calendar';
import type { AirePayrollCalendarState } from '@/types';
import { AirePayrollCalendarCard } from './AirePayrollCalendarCard';

const authState = vi.hoisted(() => ({ isManager: true }));
const apiMocks = vi.hoisted(() => ({
  publish: vi.fn(),
  retry: vi.fn(),
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => authState,
}));

vi.mock('@/services/api', () => ({
  payPeriodsApi: {
    publishAireCalendar: apiMocks.publish,
    retryAireCalendarDelivery: apiMocks.retry,
  },
}));

const baseCalendar: AirePayrollCalendarState = {
  enabled: true,
  source_id: 1,
  source_name: 'AIRE Services',
  eligible: true,
  cutoff_at: '2026-10-18T17:00:00+10:00',
  cutoff_state: 'unpublished',
  needs_revision: false,
  can_publish: true,
  can_retry: false,
};

function renderCard(calendar: AirePayrollCalendarState, onRefresh = vi.fn()) {
  return render(createElement(AirePayrollCalendarCard, {
    payPeriodId: 42,
    calendar,
    onRefresh,
  }));
}

beforeEach(() => {
  authState.isManager = true;
  vi.clearAllMocks();
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe('cutoffDistance', () => {
  it('shows a concise day and hour countdown', () => {
    expect(cutoffDistance('2026-10-18T17:00:00+10:00', new Date('2026-10-16T15:00:00+10:00')))
      .toBe('2 days, 2 hr until cutoff');
  });

  it('shows minutes inside the final hour and a truthful reached state', () => {
    expect(cutoffDistance('2026-10-18T17:00:00+10:00', new Date('2026-10-18T16:10:00+10:00')))
      .toBe('50 minutes until cutoff');
    expect(cutoffDistance('2026-10-18T17:00:00+10:00', new Date('2026-10-18T17:00:00+10:00')))
      .toBe('Cutoff reached');
  });

  it('returns null for a missing or invalid timestamp', () => {
    expect(cutoffDistance()).toBeNull();
    expect(cutoffDistance('not-a-date')).toBeNull();
  });
});

describe('lockedBatchCopy', () => {
  const batch = {
    event_id: 'event-1',
    verification_status: 'verified' as const,
    verification_attempts: 1,
    occurred_at: '2026-10-18T17:00:00+10:00',
    payroll_batch_id: 'AIRE-PAY-1',
    payroll_batch_checksum: 'a'.repeat(64),
    summary: { total_hours: 12.5 },
    issues: { held: 2 },
  };

  it('distinguishes verified, retrying, rejected, and absent batches', () => {
    expect(lockedBatchCopy(batch)).toEqual({
      headline: '12.50 verified batch hours',
      detail: '2 held or review items',
    });
    expect(lockedBatchCopy({ ...batch, verification_status: 'failed' }).headline).toBe('Verification retrying');
    expect(lockedBatchCopy({ ...batch, verification_status: 'rejected' }).headline).toBe('Batch rejected');
    expect(lockedBatchCopy(null).headline).toBe('No finalized batch received');
  });
});

describe('AirePayrollCalendarCard', () => {
  it('refreshes the visible cutoff distance while the page remains open', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-18T06:59:00Z'));
    renderCard(baseCalendar);
    expect(screen.getByText('1 minute until cutoff')).toBeTruthy();

    act(() => vi.advanceTimersByTime(60_000));

    expect(screen.getByText('Cutoff reached')).toBeTruthy();
  });

  it('shows the publish action only to managers when the calendar is eligible', () => {
    renderCard(baseCalendar);
    expect(screen.getByRole('button', { name: /publish cutoff to aire/i })).toBeTruthy();

    cleanup();
    authState.isManager = false;
    renderCard(baseCalendar);
    expect(screen.queryByRole('button', { name: /publish cutoff to aire/i })).toBeNull();
  });

  it('shows a direct retry action and the delivery error for a failed publication', () => {
    renderCard({
      ...baseCalendar,
      cutoff_state: 'publication_failed',
      can_publish: false,
      can_retry: true,
      publication: {
        id: 9,
        schedule_version: 1,
        publication_id: 'publication-1',
        delivery_status: 'failed',
        delivery_attempts: 2,
        last_error: 'AIRE unavailable',
      },
    });

    expect(screen.getByRole('button', { name: /retry sync/i })).toBeTruthy();
    expect(screen.getByRole('alert').textContent).toContain('AIRE unavailable');
  });

  it('labels verified hours without implying they were imported, processed, or paid', () => {
    renderCard({
      ...baseCalendar,
      cutoff_state: 'batch_verified',
      can_publish: false,
      finalized_batch: {
        event_id: 'event-1',
        verification_status: 'verified',
        verification_attempts: 1,
        occurred_at: '2026-10-18T17:00:00+10:00',
        payroll_batch_id: 'AIRE-PAY-1',
        payroll_batch_checksum: 'a'.repeat(64),
        summary: { total_hours: 12.5 },
        issues: { held: 0 },
      },
    });

    expect(screen.getByText('12.50 verified batch hours')).toBeTruthy();
    expect(screen.getByText(/do not import hours, calculate payroll, issue checks, or mark anyone paid/i)).toBeTruthy();
  });

  it('calls the publish API, disables actions while waiting, and refreshes after success', async () => {
    const user = userEvent.setup();
    const onRefresh = vi.fn().mockResolvedValue(undefined);
    let release!: () => void;
    apiMocks.publish.mockReturnValue(new Promise<void>((resolve) => { release = resolve; }));
    renderCard(baseCalendar, onRefresh);

    const publish = screen.getByRole('button', { name: /publish cutoff to aire/i }) as HTMLButtonElement;
    await user.click(publish);

    expect(apiMocks.publish).toHaveBeenCalledWith(42);
    expect(publish.disabled).toBe(true);
    release();
    await waitFor(() => expect(onRefresh).toHaveBeenCalledOnce());
    await waitFor(() => expect(publish.disabled).toBe(false));
  });

  it('calls the retry API and presents a rejected request as an actionable error', async () => {
    const user = userEvent.setup();
    apiMocks.retry.mockRejectedValue(new Error('AIRE is temporarily unavailable'));
    renderCard({
      ...baseCalendar,
      cutoff_state: 'publication_failed',
      can_publish: false,
      can_retry: true,
    });

    await user.click(screen.getByRole('button', { name: /retry sync/i }));

    expect(apiMocks.retry).toHaveBeenCalledWith(42);
    await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('AIRE is temporarily unavailable'));
  });
});
