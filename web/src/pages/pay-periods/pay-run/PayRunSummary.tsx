

import { Card, CardContent } from '@/components/ui/card';

import { formatCurrency } from '@/lib/utils';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunSummary({
  contractorItems,
  hasCorrectionPayBasisHold,
  payrollItems,
  totalContractorPay,
  totalDRTDeposit,
  totalDeductions,
  totalGross,
  totalNet
}: PayRunSectionProps<'summary'>) {
  return (<>
<section aria-label="Saved payroll totals" className="mb-5">
        {hasCorrectionPayBasisHold && <div role="note" className="mb-4 rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm text-neutral-950">Saved payroll amounts are retained. Review the source evidence and pay setup for held correction records before recalculating or approving. These totals are saved amounts, not a new-pay forecast.</div>}
        {/* Summary Cards */}
        {payrollItems.length > 0 && (
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5 lg:gap-4">
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-neutral-600">Employees</p>
                <p className="mt-1 text-2xl font-semibold text-neutral-950">{payrollItems.length}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-neutral-600">{hasCorrectionPayBasisHold ? 'Saved gross pay' : 'Gross pay'}</p>
                <p className="mt-1 whitespace-nowrap tabular-nums text-xl font-semibold text-neutral-950 sm:text-2xl">{formatCurrency(totalGross)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-neutral-600">{hasCorrectionPayBasisHold ? 'Saved deductions' : 'Total deductions'}</p>
                <p className="mt-1 whitespace-nowrap tabular-nums text-xl font-semibold text-neutral-950 sm:text-2xl">{formatCurrency(totalDeductions)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-neutral-600">{hasCorrectionPayBasisHold ? 'Saved net pay' : 'Net pay'}</p>
                <p className="mt-1 whitespace-nowrap tabular-nums text-xl font-semibold text-neutral-950 sm:text-2xl">{formatCurrency(totalNet)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-neutral-600">{hasCorrectionPayBasisHold ? 'Saved DRT deposit' : 'DRT deposit'}</p>
                <p className="mt-1 whitespace-nowrap tabular-nums text-xl font-semibold text-neutral-950 sm:text-2xl">{formatCurrency(totalDRTDeposit)}</p>
              </CardContent>
            </Card>
            {contractorItems.length > 0 && (
              <Card>
                <CardContent className="pt-5 pb-4">
                  <p className="text-xs font-medium text-neutral-600">1099 contractors ({contractorItems.length})</p>
                  <p className="mt-1 whitespace-nowrap tabular-nums text-xl font-semibold text-neutral-950 sm:text-2xl">{formatCurrency(totalContractorPay)}</p>
                </CardContent>
              </Card>
            )}
          </div>
        )}

      </section>
  </>);
}
