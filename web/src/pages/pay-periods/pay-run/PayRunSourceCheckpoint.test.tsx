// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { PayPeriod } from '@/types';
import type { PayRunSectionProps } from './usePayRunController';
import { PayRunSourceCheckpoint } from './PayRunSourceCheckpoint';

const cockpit = vi.hoisted(() => vi.fn());
vi.mock('@/components/payroll/AirePayrollCockpit', () => ({
  AirePayrollCockpit: (props: unknown) => { cockpit(props); return <div>Connected source</div>; },
}));

afterEach(() => { cleanup(); vi.clearAllMocks(); });

const period = {
  id: 17, status: 'draft', run_purpose: 'regular',
  time_tracking: { linked_aire_records: [], aire_calendar: { enabled: true, cutoff_at: '2026-10-22T17:00:00+10:00' } },
} as unknown as PayPeriod;

function renderSource(payPeriod = period, overrides: Partial<PayRunSectionProps<'source'>> = {}) {
  const props = {
    payPeriod, companyId: '1', hoursMap: {}, currentAireRecord: null, aireSourceRefreshToken: 0,
    invalidateAireSource: vi.fn(), loadPayPeriod: vi.fn(),
    setTimeTrackingAutoPreview: vi.fn(), setTimeTrackingImportOpen: vi.fn(), ...overrides,
  } as unknown as PayRunSectionProps<'source'>;
  render(<MemoryRouter><PayRunSourceCheckpoint {...props} /></MemoryRouter>);
  return props;
}

describe('PayRunSourceCheckpoint', () => {
  it('opts regular connected runs into the compact presentation and preserves import and refresh callbacks', async () => {
    const props = renderSource();
    const connectedProps = cockpit.mock.lastCall![0];
    expect(connectedProps.presentation).toBe('checkpoint');
    expect(connectedProps.sourceCoverageRequired).toBe(true);
    connectedProps.onReviewFinalizedBatch();
    expect(props.setTimeTrackingAutoPreview).toHaveBeenCalledWith(true);
    expect(props.setTimeTrackingImportOpen).toHaveBeenCalledWith(true);
    await connectedProps.onRefresh();
    expect(props.invalidateAireSource).toHaveBeenCalledOnce();
    expect(props.loadPayPeriod).toHaveBeenCalledWith(17, true, true);
    expect(screen.queryByRole('button', { name: /calculate/i })).toBeNull();
  });

  it('uses the coverage guard rather than treating an available batch as imported hours', () => {
    renderSource({ ...period, time_tracking: { ...period.time_tracking!, linked_aire_records: [{ id: 1 }] as never } });
    expect(cockpit.mock.lastCall![0].sourceCoverageRequired).toBe(false);
  });

  it('keeps selected late hours and the original-payroll link outside the regular checkpoint', () => {
    renderSource({ ...period, late_hours_origin_pay_period_id: 12 });
    expect(screen.getByText('Late hours adjustment · selected source hours only')).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Return to original payroll' }).getAttribute('href')).toContain('/12/work');
    expect(cockpit).not.toHaveBeenCalled();
  });

  it('explains why an adjustment does not use the regular cutoff', () => {
    renderSource({ ...period, run_purpose: 'adjustment' });
    expect(screen.getByText(/regular time tracking cutoff and full-period hours do not apply/)).toBeTruthy();
    expect(cockpit).not.toHaveBeenCalled();
  });
});

it.each(['draft', 'calculated'] as const)('allows %s coverage review only while idle', status => {
  const review = vi.fn();
  renderSource({ ...period, status }, { onReviewSourceCoverage: review, sourceCoverageProcessing: false });
  const slot = cockpit.mock.lastCall![0].sourceCoverageAction;
  render(<MemoryRouter>{slot}</MemoryRouter>);
  const button = screen.getByRole('button', { name: 'Review source coverage' });
  fireEvent.click(button); expect(review).toHaveBeenCalledOnce();
  cleanup();
  renderSource({ ...period, status }, { onReviewSourceCoverage: review, sourceCoverageProcessing: true });
  render(<MemoryRouter>{cockpit.mock.lastCall![0].sourceCoverageAction}</MemoryRouter>);
  const disabled = screen.getByRole('button', { name: 'Review source coverage' }) as HTMLButtonElement;
  expect(disabled.disabled).toBe(true); fireEvent.click(disabled); expect(review).toHaveBeenCalledOnce();
});
it('does not expose calculation coverage review for an approved run', () => {
  renderSource({ ...period, status: 'approved' }, { onReviewSourceCoverage: vi.fn() });
  expect(cockpit.mock.lastCall![0].sourceCoverageAction).toBeFalsy();
});
