

import { PayrollLiabilityPanel } from '@/components/payroll/PayrollLiabilityPanel';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunLiabilities({
  isCommitted,
  liabilityError,
  liabilityLoading,
  liabilityReconciliation
}: PayRunSectionProps<'liabilities'>) {
  return (<>
{isCommitted && (
          <PayrollLiabilityPanel
            reconciliation={liabilityReconciliation}
            loading={liabilityLoading}
            error={liabilityError}
          />
        )}
  </>);
}
