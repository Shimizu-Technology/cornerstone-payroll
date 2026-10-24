import { formatCurrency } from '@/lib/utils';
import { Alert } from '@/components/ui/alert';
import type { PayRunSectionProps } from './usePayRunController';

export function PayRunSummary({ contractorItems, hasCorrectionPayBasisHold, payrollItems, totalContractorPay, totalDRTDeposit, totalDeductions, totalGross, totalNet }: PayRunSectionProps<'summary'>) {
  const values = [
    { label: 'Employees', value: String(payrollItems.length) },
    { label: hasCorrectionPayBasisHold ? 'Saved gross pay' : 'Gross pay', value: formatCurrency(totalGross) },
    { label: hasCorrectionPayBasisHold ? 'Saved deductions' : 'Total deductions', value: formatCurrency(totalDeductions) },
    { label: hasCorrectionPayBasisHold ? 'Saved net pay' : 'Net pay', value: formatCurrency(totalNet), net: true },
    { label: hasCorrectionPayBasisHold ? 'Saved DRT deposit' : 'DRT deposit', value: formatCurrency(totalDRTDeposit) },
    ...(contractorItems.length ? [{ label: `1099 contractors (${contractorItems.length})`, value: formatCurrency(totalContractorPay) }] : []),
  ];
  return <section aria-label="Saved payroll totals">
    <dl className="grid grid-cols-2 divide-neutral-200 border-t border-neutral-200 py-3 sm:flex sm:flex-wrap sm:divide-x">
      {values.map(({ label, value, net }) => <div key={label} className={`min-w-0 px-3 py-2 first:pl-0 sm:flex-1 ${net ? 'col-span-2 sm:col-span-1' : ''}`}>
        <dt className="text-xs font-medium text-neutral-600">{label}</dt><dd className="mt-1 break-words text-xl font-semibold tabular-nums text-neutral-950">{value}</dd>
      </div>)}
    </dl>
    {hasCorrectionPayBasisHold && <Alert role="note" className="mb-4">Saved payroll amounts are retained. Review the source evidence and pay setup for held correction records before recalculating or approving. These totals are saved amounts, not a new-pay forecast.</Alert>}
  </section>;
}
