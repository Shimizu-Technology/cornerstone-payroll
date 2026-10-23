import { useEffect, useRef, useState } from 'react';
import { payPeriodsApi } from '@/services/api';
import type { AirePayrollCalendarState } from '@/types';

// Read-only polling follows delivery/verification. It never locks or imports time.
export function useAireCalendarRefresh({ companyId, payPeriodId, calendar, enabled, onUpdated }: {
  companyId: number;
  payPeriodId: number;
  calendar?: AirePayrollCalendarState | null;
  enabled: boolean;
  onUpdated: (calendar: AirePayrollCalendarState) => void;
}) {
  const [error, setError] = useState<string | null>(null);
  const onUpdatedRef = useRef(onUpdated);
  onUpdatedRef.current = onUpdated;
  const snapshot = JSON.stringify(calendar);
  const state = calendar?.cutoff_state;
  const sourceId = calendar?.source_id;
  const cutoffAt = calendar?.cutoff_at;
  const shouldFollow = enabled && Boolean(calendar?.enabled) && Boolean(calendar?.publication)
    && !['batch_verified', 'batch_rejected', 'publication_failed', 'schedule_changed'].includes(state || '');

  useEffect(() => {
    setError(null);
    if (!shouldFollow) return;
    let current = true;
    let inFlight = false;
    let timer: ReturnType<typeof setTimeout>;
    const delay = () => ['publishing', 'finalized', 'batch_verifying', 'batch_verification_failed', 'due', 'cutoff_due'].includes(state || '')
      || (cutoffAt && Date.parse(cutoffAt) <= Date.now()) ? 5_000 : 30_000;
    const refresh = async () => {
      if (!current || inFlight || document.visibilityState === 'hidden') return;
      inFlight = true;
      try {
        const result = await payPeriodsApi.get(payPeriodId, companyId);
        if (!current) return;
        const updated = result.pay_period.time_tracking?.aire_calendar;
        if (result.pay_period.id !== payPeriodId || result.pay_period.company_id !== companyId || updated?.source_id !== sourceId) {
          throw new Error('The time tracking status did not match this client and payroll.');
        }
        setError(null);
        if (updated && JSON.stringify(updated) !== snapshot) onUpdatedRef.current(updated);
      } catch {
        if (current) setError('Time tracking status could not refresh automatically. Retrying; use Refresh to check the connection.');
      } finally {
        inFlight = false;
      }
    };
    const schedule = () => {
      timer = setTimeout(() => { void refresh().finally(() => { if (current) schedule(); }); }, delay());
    };
    const onVisible = () => { if (document.visibilityState !== 'hidden') void refresh(); };
    schedule();
    window.addEventListener('focus', onVisible);
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      current = false;
      clearTimeout(timer);
      window.removeEventListener('focus', onVisible);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [companyId, payPeriodId, sourceId, cutoffAt, shouldFollow, snapshot, state]);

  return error;
}
