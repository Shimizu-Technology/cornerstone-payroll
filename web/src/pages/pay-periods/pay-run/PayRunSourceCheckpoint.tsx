

import { AirePayrollCockpit } from '@/components/payroll/AirePayrollCockpit';

import { runPurposeLabels } from './payRunSupport';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunSourceCheckpoint({
  aireSourceRefreshToken,
  currentAireRecord,
  hoursMap,
  invalidateAireSource,
  loadPayPeriod,
  payPeriod,
  setTimeTrackingAutoPreview,
  setTimeTrackingImportOpen
}: PayRunSectionProps<'source'>) {
  return (<>
<div id="time-tracking-sync" tabIndex={-1} className="scroll-mt-24">
        {payPeriod.run_purpose !== 'regular' && payPeriod.time_tracking?.aire_calendar && (
          <div className="rounded-2xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-700">
            <h3 className="font-semibold text-neutral-950">Manual {runPurposeLabels[payPeriod.run_purpose]?.toLowerCase() || 'special run'} · selected employees only</h3>
            <p className="mt-1">Only entered pay belongs to this run. The regular time tracking cutoff and full-period hours do not apply. After commitment, link exact source hours below when they are covered by this payroll.</p>
          </div>
        )}
        {payPeriod.run_purpose === 'regular' && payPeriod.time_tracking?.aire_calendar && (
          <AirePayrollCockpit
            key={payPeriod.id}
            payPeriodId={payPeriod.id}
            payPeriodStatus={payPeriod.status}
            payrollHours={hoursMap}
            aireRecord={currentAireRecord}
            calendar={payPeriod.time_tracking.aire_calendar}
            refreshToken={aireSourceRefreshToken}
            onSourceChanged={invalidateAireSource}
            onRefresh={async () => {
              invalidateAireSource();
              return (await loadPayPeriod(payPeriod.id, true, true)) !== 'failed';
            }}
            onReviewFinalizedBatch={() => {
              setTimeTrackingAutoPreview(true);
              setTimeTrackingImportOpen(true);
            }}
          />
        )}

        </div>
  </>);
}
