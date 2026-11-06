

import { NonEmployeeChecksPanel } from '@/components/checks/NonEmployeeChecksPanel';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunNonEmployeeChecks({
  checkPrintRefreshToken,
  handleNonEmployeeChecksChanged,
  handleNonEmployeeChecksLoaded,
  isCommitted,
  isVoided,
  payPeriod
}: PayRunSectionProps<'nonEmployeeChecks'>) {
  return (<>
{isCommitted && payPeriod.company_id && (
          <NonEmployeeChecksPanel
            payPeriodId={payPeriod.id}
            companyId={payPeriod.company_id}
            payPeriodStatus={payPeriod.status}
            payPeriodVoided={isVoided}
            payDate={payPeriod.pay_date}
            refreshToken={checkPrintRefreshToken}
            onChecksLoaded={handleNonEmployeeChecksLoaded}
            onChecksChanged={handleNonEmployeeChecksChanged}
          />
        )}
  </>);
}
