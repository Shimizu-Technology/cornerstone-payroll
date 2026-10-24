import { Link } from 'react-router';
import { Button } from '@/components/ui/button';
import { employeePath } from '@/lib/routes';
import { formatCurrency } from '@/lib/utils';
import type { PayRunSectionProps } from './usePayRunController';

/** Drafts can retain calculated/imported records. Keep the former Overview review entry point. */
export function PayRunSavedRecords({ isDraft, payrollItems, companyId, currentPath, setReviewingItem }: PayRunSectionProps<'results'>) {
  const records = payrollItems.filter(item => item.payroll_included !== false);
  if (!isDraft || !records.length) return null;
  return <details className="rounded-xl border border-neutral-200 bg-white">
    <summary className="cursor-pointer px-4 py-3 font-semibold text-primary-800">Saved payroll records ({records.length})</summary>
    <div className="divide-y divide-neutral-200">{records.map(item => <div key={item.id} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
      <Link className="font-semibold text-primary-800" to={employeePath(companyId, item.employee_id, 'overview', { returnTo: currentPath })}>{item.employee_name}</Link>
      <div className="flex items-center gap-3"><span className="text-right text-sm tabular-nums text-neutral-950">{formatCurrency(Number(item.net_pay || 0))} net<span className="block text-xs text-neutral-600">{formatCurrency(Number(item.gross_pay || 0))} gross</span></span><Button variant="outline" aria-label={`Open payroll item for ${item.employee_name}`} onClick={() => setReviewingItem(item)}>Open record</Button></div>
    </div>)}</div>
  </details>;
}
