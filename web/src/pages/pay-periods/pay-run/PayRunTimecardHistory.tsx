

import { TimecardHistoryPanel } from '@/components/payroll/TimecardHistoryPanel';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunTimecardHistory({
  isDraft,
  payPeriod
}: PayRunSectionProps<'timecardHistory'>) {
  return (<>
{!isDraft && (
          <TimecardHistoryPanel payPeriodId={payPeriod.id} />
        )}
  </>);
}
