import { useEffect, useState } from 'react';
import {
  AlertTriangle,
  CalendarClock,
  CheckCircle2,
  Clock3,
  RefreshCw,
  Send,
  ShieldCheck,
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { cutoffDistance, lockedBatchCopy } from '@/lib/aire-payroll-calendar';
import { formatGuamDateTime } from '@/lib/utils';
import { payPeriodsApi } from '@/services/api';
import type { AirePayrollCalendarState } from '@/types';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

type Props = {
  payPeriodId: number;
  calendar: AirePayrollCalendarState;
  onRefresh: () => Promise<void> | void;
};

const stateLabels: Record<AirePayrollCalendarState['cutoff_state'], string> = {
  unpublished: 'Not published',
  publishing: 'Publishing',
  publication_failed: 'Sync needs attention',
  schedule_changed: 'Update required',
  scheduled: 'Scheduled',
  upcoming: 'Scheduled',
  due: 'Cutoff due',
  cutoff_due: 'Cutoff due',
  finalized: 'Batch finalized',
  batch_verifying: 'Verifying batch',
  batch_verification_failed: 'Verification retrying',
  batch_rejected: 'Batch needs review',
  batch_verified: 'Batch verified',
};

function statusTone(state: AirePayrollCalendarState['cutoff_state']) {
  if (state === 'batch_verified') return 'success' as const;
  if (['publication_failed', 'batch_rejected'].includes(state)) return 'danger' as const;
  if (['schedule_changed', 'due', 'cutoff_due', 'finalized', 'batch_verification_failed'].includes(state)) return 'warning' as const;
  if (['publishing', 'batch_verifying', 'scheduled', 'upcoming'].includes(state)) return 'info' as const;
  return 'default' as const;
}

export function AirePayrollCalendarCard({ payPeriodId, calendar, onRefresh }: Props) {
  const { isManager } = useAuth();
  const [busy, setBusy] = useState<'publish' | 'retry' | 'refresh' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(() => new Date());
  const distance = cutoffDistance(calendar.cutoff_at, now);
  const batch = calendar.finalized_batch;
  const batchCopy = lockedBatchCopy(batch);

  useEffect(() => {
    const timer = window.setInterval(() => setNow(new Date()), 60_000);
    return () => window.clearInterval(timer);
  }, []);

  const run = async (action: 'publish' | 'retry' | 'refresh') => {
    setBusy(action);
    setError(null);
    try {
      if (action === 'publish') await payPeriodsApi.publishAireCalendar(payPeriodId);
      if (action === 'retry') await payPeriodsApi.retryAireCalendarDelivery(payPeriodId);
      await onRefresh();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not update the AIRE payroll calendar');
    } finally {
      setBusy(null);
    }
  };

  const primaryAction = calendar.needs_revision ? 'Update AIRE schedule' : 'Publish cutoff to AIRE';
  const transitionInProgress = calendar.cutoff_state === 'publishing' || calendar.cutoff_state === 'batch_verifying';

  return (
    <Card className="overflow-hidden border-primary-200 bg-gradient-to-br from-primary-50/90 via-white to-white">
      <CardContent className="p-0">
        <div className="flex flex-col gap-6 border-b border-primary-100 px-6 py-6 lg:flex-row lg:items-start lg:justify-between">
          <div className="flex max-w-3xl items-start gap-4">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-primary-100 text-primary-800">
              <CalendarClock className="h-5 w-5" aria-hidden="true" />
            </div>
            <div>
              <div className="flex flex-wrap items-center gap-2">
                <h3 className="font-display text-base font-bold text-neutral-950">AIRE payroll cutoff</h3>
                <Badge variant={statusTone(calendar.cutoff_state)}>{stateLabels[calendar.cutoff_state]}</Badge>
                {calendar.publication && <Badge variant="default">Schedule v{calendar.publication.schedule_version}</Badge>}
              </div>
              <p className="mt-2 text-sm leading-6 text-neutral-600">
                Cornerstone sets the payroll calendar. AIRE independently locks eligible time at the cutoff, records held hours, and sends the immutable batch back here.
              </p>
            </div>
          </div>

          <div className="flex flex-wrap gap-2 lg:justify-end">
            <Button type="button" variant="outline" size="sm" onClick={() => void run('refresh')} disabled={busy !== null}>
              <RefreshCw className={`mr-2 h-4 w-4 ${busy === 'refresh' ? 'animate-spin' : ''}`} />
              Refresh
            </Button>
            {isManager && calendar.can_retry && (
              <Button type="button" variant="outline" size="sm" onClick={() => void run('retry')} disabled={busy !== null}>
                <RefreshCw className="mr-2 h-4 w-4" />
                {busy === 'retry' ? 'Retrying…' : 'Retry sync'}
              </Button>
            )}
            {isManager && calendar.can_publish && (calendar.cutoff_state === 'unpublished' || calendar.needs_revision) && (
              <Button type="button" size="sm" onClick={() => void run('publish')} disabled={busy !== null}>
                <Send className="mr-2 h-4 w-4" />
                {busy === 'publish' ? 'Publishing…' : primaryAction}
              </Button>
            )}
          </div>
        </div>

        <div className="grid divide-y divide-primary-100 sm:grid-cols-3 sm:divide-x sm:divide-y-0" aria-live="polite">
          <div className="px-6 py-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Cutoff</p>
            <p className="mt-2 font-semibold text-neutral-950">
              {calendar.cutoff_at ? formatGuamDateTime(calendar.cutoff_at) : 'Not available'}
            </p>
            {distance && <p className="mt-2 text-xs text-neutral-500">{distance}</p>}
          </div>
          <div className="px-6 py-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">AIRE delivery</p>
            <p className="mt-2 font-semibold text-neutral-950">
              {calendar.publication?.delivery_status === 'delivered'
                ? 'Schedule received'
                : calendar.publication?.delivery_status === 'failed'
                  ? 'Retry required'
                  : calendar.publication ? 'Waiting for delivery' : 'Not sent'}
            </p>
            <p className="mt-2 text-xs text-neutral-500">{calendar.source_name}</p>
          </div>
          <div className="px-6 py-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Locked batch</p>
            <p className="mt-2 font-semibold text-neutral-950">{batchCopy.headline}</p>
            <p className="mt-2 text-xs text-neutral-500">{batchCopy.detail}</p>
          </div>
        </div>

        {!calendar.eligible && calendar.eligibility_error && (
          <div className="flex items-start gap-4 border-t border-warning-200 bg-warning-50 px-6 py-4 text-sm text-warning-950" role="status">
            <Clock3 className="h-4 w-4 shrink-0" aria-hidden="true" />
            <div><p className="font-semibold">This run is not ready for AIRE scheduling</p><p className="mt-2 leading-6 text-warning-800">{calendar.eligibility_error}</p></div>
          </div>
        )}

        {(error || calendar.publication?.last_error || batch?.last_error) && (
          <div className="flex items-start gap-4 border-t border-danger-200 bg-danger-50 px-6 py-4 text-sm text-danger-800" role="alert">
            <AlertTriangle className="h-4 w-4 shrink-0" aria-hidden="true" />
            <div><p className="font-semibold">AIRE connection needs attention</p><p className="mt-2 break-words leading-6 text-danger-800">{error || batch?.last_error || calendar.publication?.last_error}</p></div>
          </div>
        )}

        {batch?.verification_status === 'verified' && (
          <div className="border-t border-success-200 bg-success-50/80 px-6 py-4">
            <div className="flex items-start gap-4">
              <CheckCircle2 className="h-5 w-5 shrink-0 text-success-700" aria-hidden="true" />
              <div className="min-w-0">
                <p className="font-semibold text-success-800">AIRE’s finalized batch is verified and ready to review</p>
                <p className="mt-2 text-sm leading-6 text-success-700">
                  Batch <span className="font-mono font-semibold">{batch.payroll_batch_id}</span> · checksum <span className="font-mono">{batch.payroll_batch_checksum.slice(0, 12)}…</span>
                </p>
              </div>
            </div>
          </div>
        )}

        <div className="flex items-start gap-2 border-t border-primary-100 bg-white/70 px-6 py-4 text-xs leading-5 text-neutral-500">
          <ShieldCheck className="h-4 w-4 shrink-0 text-primary-700" aria-hidden="true" />
          <p>{transitionInProgress ? 'Cornerstone is waiting for the integration worker. Refresh in a moment.' : 'Scheduling and finalization do not import hours, calculate payroll, issue checks, or mark anyone paid.'}</p>
        </div>
      </CardContent>
    </Card>
  );
}
