// @vitest-environment jsdom
import { act, cleanup, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { AirePayrollCalendarState } from '@/types';
import { useAireCalendarRefresh } from './useAireCalendarRefresh';
const api = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock('@/services/api', () => ({ payPeriodsApi: api }));
const calendar = { enabled: true, source_id: 3, cutoff_state: 'batch_verifying', publication: { delivery_status: 'delivered' } } as AirePayrollCalendarState;
const response = (value = calendar, id = 2, companyId = 1) => ({ pay_period: { id, company_id: companyId, time_tracking: { aire_calendar: value } } });
beforeEach(() => { vi.useFakeTimers(); vi.clearAllMocks(); api.get.mockResolvedValue(response()); });
afterEach(() => { cleanup(); vi.useRealTimers(); });
const advance = async (ms = 5_000) => { await act(async () => { await vi.advanceTimersByTimeAsync(ms); }); };
it('follows verification automatically and stops after a verified batch', async () => {
  const onUpdated = vi.fn();
  const verified = { ...calendar, cutoff_state: 'batch_verified' } as AirePayrollCalendarState;
  api.get.mockResolvedValue(response(verified));
  const { rerender } = renderHook(({ value }) => useAireCalendarRefresh({ companyId: 1, payPeriodId: 2, calendar: value, enabled: true, onUpdated }), { initialProps: { value: calendar } });
  await advance();
  expect(api.get).toHaveBeenCalledWith(2, 1);
  expect(onUpdated).toHaveBeenCalledWith(verified);
  rerender({ value: verified });
  await advance(60_000);
  expect(api.get).toHaveBeenCalledTimes(1);
});
it('discards a late response after navigating to another company/run', async () => {
  let finish!: (value: ReturnType<typeof response>) => void;
  api.get.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  const onUpdated = vi.fn();
  const { rerender } = renderHook(({ id }) => useAireCalendarRefresh({ companyId: 1, payPeriodId: id, calendar, enabled: true, onUpdated }), { initialProps: { id: 2 } });
  await advance();
  rerender({ id: 9 });
  await act(async () => { finish(response({ ...calendar, cutoff_state: 'batch_verified' } as AirePayrollCalendarState)); });
  expect(onUpdated).not.toHaveBeenCalled();
});
it('shows a retry warning on failure and recovers without overlapping requests', async () => {
  api.get.mockRejectedValueOnce(new Error('Unavailable'));
  const { result } = renderHook(() => useAireCalendarRefresh({ companyId: 1, payPeriodId: 2, calendar, enabled: true, onUpdated: vi.fn() }));
  await advance(); expect(result.current).toMatch(/could not refresh automatically/);
  await advance(); expect(result.current).toBeNull();
  expect(api.get).toHaveBeenCalledTimes(2);
});
it('does not poll a hidden processing tab or accept a different source', async () => {
  const onUpdated = vi.fn();
  const { rerender, result } = renderHook(({ enabled }) => useAireCalendarRefresh({ companyId: 1, payPeriodId: 2, calendar, enabled, onUpdated }), { initialProps: { enabled: false } });
  await advance(); expect(api.get).not.toHaveBeenCalled();
  api.get.mockResolvedValue(response({ ...calendar, source_id: 99 }));
  rerender({ enabled: true }); await advance();
  expect(onUpdated).not.toHaveBeenCalled(); expect(result.current).toMatch(/could not refresh/);
});
