

import { TimecardOcrPanel } from '@/components/payroll/TimecardOcrPanel';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunTimecardOcr({
  handlePayrollItemApplied,
  isDraft,
  payPeriod
}: PayRunSectionProps<'ocr'>) {
  return (<>
{isDraft && (
          <TimecardOcrPanel
            payPeriodId={payPeriod.id}
            onPayrollUpdated={handlePayrollItemApplied}
          />
        )}
  </>);
}
