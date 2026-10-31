import { useEffect, useRef, useMemo } from 'react';
import { formatCurrency } from '@/lib/utils';
import { Alert } from '@/components/ui/alert';
import type { PayRunSectionProps } from './usePayRunController';

export function PayRunSummary({ payRunId, contractorItems, hasCorrectionPayBasisHold, payrollItems, totalContractorPay, totalDRTDeposit, totalDeductions, totalGross, totalNet }: PayRunSectionProps<'summary'>) {
  const values = useMemo(() => [
    { label: 'Employees', value: String(payrollItems.length) },
    { label: hasCorrectionPayBasisHold ? 'Saved gross pay' : 'Gross pay', value: formatCurrency(totalGross) },
    { label: hasCorrectionPayBasisHold ? 'Saved deductions' : 'Total deductions', value: formatCurrency(totalDeductions) },
    { label: hasCorrectionPayBasisHold ? 'Saved net pay' : 'Net pay', value: formatCurrency(totalNet), net: true },
    { label: hasCorrectionPayBasisHold ? 'Saved DRT deposit' : 'DRT deposit', value: formatCurrency(totalDRTDeposit) },
    ...(contractorItems.length ? [{ label: `1099 contractors (${contractorItems.length})`, value: formatCurrency(totalContractorPay) }] : []),
  ], [payrollItems.length, contractorItems.length, hasCorrectionPayBasisHold, totalGross, totalDeductions, totalNet, totalDRTDeposit, totalContractorPay]);
  const previous = useRef<{ id: number; values: Map<string, string> } | null>(null);
  const highlights = useRef(new Map<string, HTMLSpanElement>());
  useEffect(() => {
    if (previous.current?.id === payRunId) {
      const reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
      for (const item of values) if (previous.current.values.get(item.label) !== item.value) {
        const element = highlights.current.get(item.label);
        element?.getAnimations?.().forEach(animation => animation.cancel());
        element?.animate?.([{ opacity: 1 }, { opacity: 0 }], { duration: reduced ? 150 : 250, easing: 'ease-out' });
      }
    }
    previous.current = { id: payRunId, values: new Map(values.map(item => [item.label, item.value])) };
  }, [payRunId, values]);
  return <section aria-label="Saved payroll totals">
    <dl className="grid grid-cols-2 divide-neutral-200 border-t border-neutral-200 py-3 sm:flex sm:flex-wrap sm:divide-x">
      {values.map(({ label, value, net }) => <div key={label} className={`relative min-w-0 py-2 sm:flex-1 sm:px-3 sm:first:pl-0 ${net ? 'order-last col-span-2 sm:order-none sm:col-span-1' : ''}`}>
        <span aria-hidden="true" ref={element => { if (element) highlights.current.set(label, element); else highlights.current.delete(label); }} className="pointer-events-none absolute inset-0 rounded-lg bg-primary-50 opacity-0" />
        <dt className="relative text-xs font-medium text-neutral-600">{label}</dt><dd className="relative mt-1 break-words text-xl font-semibold tabular-nums text-neutral-950">{value}</dd>
      </div>)}
    </dl>
    {hasCorrectionPayBasisHold && <Alert id="pay-basis-hold" tabIndex={-1} role="note" className="mb-4 scroll-mt-4">Saved payroll amounts are retained. Review the source evidence and pay setup for held correction records before recalculating or approving. These totals are saved amounts, not a new-pay forecast.</Alert>}
  </section>;
}
