import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { ArrowLeft } from 'lucide-react';
import { formatDate, formatDateRange, payPeriodStatusConfig } from '@/lib/utils';
import type { PayPeriod } from '@/types';

const purposes: Record<string, string> = { regular: 'Regular', off_cycle_tips: 'Off-cycle tips', bonus: 'Bonus', commission: 'Commission', correction: 'Correction', final: 'Final paycheck', adjustment: 'Adjustment' };

export function PayRunRecordHeader({ payRun, client, returnTo, attention, actions, totals }: {
  payRun: PayPeriod; client?: string; returnTo: string; attention: ReactNode; actions?: ReactNode; totals?: ReactNode;
}) {
  const voided = payRun.correction_status === 'voided';
  const status = voided ? 'Voided' : payPeriodStatusConfig[payRun.status]?.label || payRun.status;
  return <header className="border-b border-neutral-200 bg-white px-4 pt-4 sm:px-6 lg:px-8" aria-label="Pay run identity">
    <Link to={returnTo} className="mb-2 inline-flex min-h-9 items-center gap-1 text-sm font-semibold text-neutral-600 hover:text-primary-800"><ArrowLeft className="h-4 w-4" aria-hidden="true" />Back</Link>
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start">
      <div className="min-w-0">
        <h1 className="font-display text-2xl font-extrabold tracking-tight text-neutral-950">{formatDateRange(payRun.start_date, payRun.end_date)}</h1>
        <p className="mt-1 break-words text-sm text-neutral-600">{client && <>{client} · </>}Pay date {formatDate(payRun.pay_date)} · {purposes[payRun.run_purpose] || payRun.run_purpose} · Run #{payRun.id}</p>
      </div>
    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1 text-sm sm:col-span-2 sm:row-start-2" aria-label="Payroll status and attention">
      <span className="inline-flex items-center gap-2 font-semibold text-neutral-950"><span aria-hidden="true" className={`h-2 w-2 rounded-full ${voided ? 'bg-danger-700' : payRun.status === 'committed' ? 'bg-success-700' : 'bg-primary-700'}`} />{status}</span>
      <div className="min-w-0 text-neutral-700">{attention}</div>
    </div>
      {actions && <div className="flex w-full items-start gap-2 sm:col-start-2 sm:row-start-1 sm:w-auto">{actions}</div>}
    </div>
    <div className="mt-4">{totals}</div>
  </header>;
}
