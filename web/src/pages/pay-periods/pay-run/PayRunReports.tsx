

import { ReportsDownloadPanel } from '@/components/reports/ReportsDownloadPanel';

import { PayrollFinalRecordPanel } from '@/components/payroll/PayrollFinalRecordPanel';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunReports({
  companyId,
  finalRecordRefreshToken,
  isCommitted,
  isDraft,
  payPeriod,
  payRunId,
  payrollItems
}: PayRunSectionProps<'reports'>) {
  return (<>
{isCommitted && <PayrollFinalRecordPanel companyId={companyId} payPeriodId={payRunId} refreshToken={finalRecordRefreshToken} />}
{!isDraft && payrollItems.length > 0 && (
          <ReportsDownloadPanel
            payPeriodId={payPeriod.id}
            payPeriodStatus={payPeriod.status}
            payDate={payPeriod.pay_date}
          />
        )}
  </>);
}
