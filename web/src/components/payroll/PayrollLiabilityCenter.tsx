import { useMemo, useState } from 'react';
import { AlertTriangle, CalendarClock, CheckCircle2, Landmark, Loader2, ReceiptText } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { formatCurrency, formatDate, formatDateRange } from '@/lib/utils';
import { payrollLiabilityCenterApi } from '@/services/api';
import type {
  PayrollLiabilityCenter as PayrollLiabilityCenterData,
  PayrollLiabilityCenterObligation,
  PayrollLiabilityObligationStatus,
} from '@/types';

interface Props {
  center: PayrollLiabilityCenterData | null;
  loading: boolean;
  error: string | null;
  onPrepare: (obligations: PayrollLiabilityCenterObligation[]) => void;
  onUpdated: (center: PayrollLiabilityCenterData) => void;
}

const STATUS: Record<PayrollLiabilityObligationStatus, { label: string; className: string }> = {
  unpaid: { label: 'Not prepared', className: 'bg-neutral-100 text-neutral-700' },
  partially_prepared: { label: 'Partly prepared', className: 'bg-blue-100 text-blue-800' },
  prepared: { label: 'Prepared · not paid', className: 'bg-blue-100 text-blue-800' },
  partially_paid: { label: 'Partly paid', className: 'bg-amber-100 text-amber-900' },
  paid: { label: 'Paid', className: 'bg-success-100 text-success-800' },
  overdue: { label: 'Overdue', className: 'bg-danger-100 text-danger-800' },
  credit: { label: 'Credit · review', className: 'bg-purple-100 text-purple-800' },
};

const CATEGORY_LABELS: Record<string, string> = {
  guam_income_tax_withheld: 'Guam income tax withheld',
  social_security_employee: 'Employee Social Security',
  social_security_employer: 'Employer Social Security',
  medicare_employee: 'Employee Medicare',
  medicare_employer: 'Employer Medicare',
  additional_medicare_employee: 'Additional Medicare',
  retirement_employee: 'Employee 401(k)',
  roth_retirement_employee: 'Employee Roth 401(k)',
  retirement_employer: 'Employer 401(k)',
  roth_retirement_employer: 'Employer Roth contribution',
  insurance_employee: 'Employee insurance',
  garnishment: 'Garnishment',
  child_support: 'Child support',
  benefit_employee: 'Employee benefit',
  benefit_employer: 'Employer benefit',
  other_payroll_liability: 'Other payroll liability',
};

export function PayrollLiabilityCenter({ center, loading, error, onPrepare, onUpdated }: Props) {
  const [dueDrafts, setDueDrafts] = useState<Record<string, string>>({});
  const [savingKey, setSavingKey] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const groups = useMemo(() => {
    const grouped = new Map<string, PayrollLiabilityCenterObligation[]>();
    center?.obligations.forEach((obligation) => {
      grouped.set(obligation.authority, [...(grouped.get(obligation.authority) || []), obligation]);
    });
    return Array.from(grouped.entries()).map(([authority, obligations]) => ({ authority, obligations }));
  }, [center]);

  const saveDueDate = async (obligation: PayrollLiabilityCenterObligation) => {
    const dueDate = dueDrafts[obligation.key] ?? obligation.due_date ?? '';
    if (!dueDate) return;
    setSavingKey(obligation.key);
    setActionError(null);
    try {
      const response = await payrollLiabilityCenterApi.updateDueDate({
        pay_period_id: obligation.pay_period_id,
        authority: obligation.authority,
        due_date: dueDate,
      });
      onUpdated(response.payroll_liability_center);
      setDueDrafts((current) => {
        const next = { ...current };
        delete next[obligation.key];
        return next;
      });
    } catch (caught) {
      setActionError(caught instanceof Error ? caught.message : 'Unable to save the due date');
    } finally {
      setSavingKey(null);
    }
  };

  if (loading) {
    return <Card className="p-4 sm:p-6"><div className="h-6 w-56 animate-pulse rounded-lg bg-neutral-200" /><div className="mt-4 h-24 animate-pulse rounded-xl bg-neutral-100" /></Card>;
  }

  if (error) {
    return <Card className="border-danger-200 bg-danger-50 p-4 sm:p-6"><div className="flex gap-3"><AlertTriangle className="mt-0.5 h-5 w-5 text-danger-600" /><div><h2 className="font-semibold text-danger-900">Payroll liabilities are unavailable</h2><p className="mt-2 text-sm text-danger-800">{error}</p></div></div></Card>;
  }

  if (!center) return null;

  return (
    <Card className="overflow-hidden border-primary-100">
      <div className="bg-gradient-to-br from-primary-950 via-primary-900 to-primary-800 p-4 text-white sm:p-6">
        <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
          <div className="max-w-3xl">
            <div className="flex items-center gap-2 text-primary-200"><Landmark className="h-4 w-4" /><span className="text-xs font-bold uppercase tracking-[0.16em]">Payroll liability center</span></div>
            <h2 className="mt-2 font-display text-2xl font-bold">Know exactly what is owed, prepared, and paid.</h2>
            <p className="mt-2 text-sm leading-6 text-primary-100">Amounts come from committed payroll. Preparing a payment reserves the exact journal entries; nothing counts as paid until a staff member explicitly confirms it.</p>
          </div>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4 xl:min-w-[560px]">
            <Summary label="Calculated" value={center.totals.calculated_amount} />
            <Summary label="Prepared" value={center.totals.prepared_amount} />
            <Summary label="Paid" value={center.totals.paid_amount} tone="success" />
            <Summary label="Still owed" value={center.totals.outstanding_amount} tone={center.totals.overdue_count > 0 ? 'danger' : 'warning'} />
          </div>
        </div>
      </div>

      {actionError && <div role="alert" className="m-4 rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800 sm:mx-6">{actionError}</div>}

      {groups.length === 0 ? (
        <div className="p-6 text-center"><CheckCircle2 className="mx-auto h-8 w-8 text-success-600" /><p className="mt-2 font-semibold text-neutral-900">No committed payroll liabilities yet</p><p className="mt-2 text-sm text-neutral-500">Committed payrolls will appear here automatically.</p></div>
      ) : (
        <div className="divide-y divide-neutral-200">
          {groups.map(({ authority, obligations }) => {
            const unreserved = obligations.reduce((sum, item) => sum + Math.max(item.unreserved_amount, 0), 0);
            const outstanding = obligations.reduce((sum, item) => sum + item.outstanding_amount, 0);
            const preparable = obligations.filter((item) => item.unreserved_amount > 0);
            return (
              <section key={authority} className="p-4 sm:p-6">
                <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
                  <div><h3 className="font-display text-lg font-bold text-neutral-950">{authority}</h3><p className="mt-2 text-sm text-neutral-500">{formatCurrency(outstanding)} still owed across {obligations.length} payroll {obligations.length === 1 ? 'obligation' : 'obligations'}.</p></div>
                  {preparable.length > 1 && <Button type="button" onClick={() => onPrepare(preparable)}>Prepare combined {formatCurrency(unreserved)} payment</Button>}
                </div>

                <div className="mt-4 overflow-hidden rounded-xl border border-neutral-200">
                  {obligations.map((obligation) => {
                    const status = STATUS[obligation.status];
                    const dueValue = dueDrafts[obligation.key] ?? obligation.due_date ?? '';
                    return (
                      <div key={obligation.key} className="grid gap-4 border-t border-neutral-100 bg-white p-4 first:border-t-0 xl:grid-cols-[minmax(220px,1.2fr)_minmax(240px,1.3fr)_repeat(3,minmax(100px,.55fr))_minmax(150px,.7fr)] xl:items-center">
                        <div><p className="font-semibold text-neutral-950">{formatDateRange(obligation.period_start, obligation.period_end)}</p><p className="mt-2 text-xs text-neutral-500">Paid {formatDate(obligation.pay_date)} · liability {formatDate(obligation.liability_date)}</p><Badge className={`mt-2 ${status.className}`}>{status.label}</Badge></div>
                        <div><p className="text-xs font-semibold uppercase tracking-wider text-neutral-500">What this includes</p><div className="mt-2 flex flex-wrap gap-2">{obligation.categories.map((category) => <span key={category.category} className="rounded-lg bg-neutral-100 px-2 py-1 text-xs text-neutral-700">{CATEGORY_LABELS[category.category] || category.category.replaceAll('_', ' ')} · {formatCurrency(category.amount)}</span>)}</div></div>
                        <Amount label="Calculated" value={obligation.calculated_amount} />
                        <Amount label="Paid" value={obligation.paid_amount} tone="success" />
                        <Amount label="Still owed" value={obligation.outstanding_amount} tone={obligation.status === 'overdue' ? 'danger' : 'default'} />
                        <div>
                          <div className="flex items-end gap-2"><Input id={`liability-due-date-${obligation.pay_period_id}-${obligation.authority.toLowerCase().replaceAll(/[^a-z0-9]+/g, '-')}`} aria-label={`Due date for ${authority} ${obligation.period_end}`} label="Due date" type="date" value={dueValue} onChange={(event) => setDueDrafts((current) => ({ ...current, [obligation.key]: event.target.value }))} /><Button type="button" size="sm" variant="ghost" className="mb-0.5" disabled={!dueValue || dueValue === obligation.due_date || savingKey === obligation.key} onClick={() => void saveDueDate(obligation)}>{savingKey === obligation.key ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Save'}</Button></div>
                          {obligation.unreserved_amount > 0 && <Button type="button" size="sm" variant="outline" className="mt-2 w-full" onClick={() => onPrepare([obligation])}><ReceiptText className="mr-2 h-4 w-4" />Prepare {formatCurrency(obligation.unreserved_amount)}</Button>}
                          {obligation.prepared_amount > obligation.paid_amount && obligation.unreserved_amount <= 0 && obligation.outstanding_amount > 0 && <p className="mt-2 text-xs leading-5 text-blue-700">Payment prepared below; confirm it only after it is actually issued.</p>}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </section>
            );
          })}
        </div>
      )}

      <div className="flex gap-2 border-t border-neutral-200 bg-neutral-50 px-4 py-3 text-xs leading-5 text-neutral-600 sm:px-6"><CalendarClock className="mt-0.5 h-4 w-4 shrink-0" /><p>Due dates are reviewed by Cornerstone staff. The system does not guess legal deposit deadlines. Voiding a payment releases its reserved liabilities while preserving the payment and audit history.</p></div>
    </Card>
  );
}

function Summary({ label, value, tone = 'default' }: { label: string; value: number; tone?: 'default' | 'success' | 'warning' | 'danger' }) {
  const valueClass = { default: 'text-white', success: 'text-success-200', warning: 'text-warning-200', danger: 'text-danger-200' }[tone];
  return <div className="rounded-xl border border-white/10 bg-white/10 p-3"><p className="text-[11px] font-bold uppercase tracking-wider text-primary-200">{label}</p><p className={`mt-2 font-display text-lg font-bold ${valueClass}`}>{formatCurrency(value)}</p></div>;
}

function Amount({ label, value, tone = 'default' }: { label: string; value: number; tone?: 'default' | 'success' | 'danger' }) {
  const valueClass = { default: 'text-neutral-950', success: 'text-success-700', danger: 'text-danger-700' }[tone];
  return <div><p className="text-xs font-semibold uppercase tracking-wider text-neutral-500 xl:text-right">{label}</p><p className={`mt-2 font-display text-lg font-bold xl:text-right ${valueClass}`}>{formatCurrency(value)}</p></div>;
}
