import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { formatCurrency, formatDate, formatGuamDateTime } from '@/lib/utils';
import type { PayrollLiabilityReconciliation } from '@/types';

interface PayrollLiabilityPanelProps {
  reconciliation: PayrollLiabilityReconciliation | null;
  loading: boolean;
  error: string | null;
}

const categoryLabels: Record<string, string> = {
  guam_income_tax_withheld: 'Guam income tax withheld',
  social_security_employee: 'Social Security — employee',
  social_security_employer: 'Social Security — employer',
  medicare_employee: 'Medicare — employee',
  medicare_employer: 'Medicare — employer',
  additional_medicare_employee: 'Additional Medicare — employee',
  retirement_employee: 'Retirement — employee',
  roth_retirement_employee: 'Roth retirement — employee',
  retirement_employer: 'Retirement — employer',
  roth_retirement_employer: 'Roth retirement — employer',
  insurance_employee: 'Insurance — employee',
  garnishment: 'Garnishment',
  child_support: 'Child support',
  benefit_employee: 'Benefit — employee',
  benefit_employer: 'Benefit — employer',
  other_payroll_liability: 'Other payroll liability',
};

const postingTypeLabels: Record<string, string> = {
  commit: 'Payroll committed',
  historical_backfill: 'Historical payroll captured',
  replacement: 'Liability date replaced',
  reversal: 'Liabilities reversed',
};

export function PayrollLiabilityPanel({ reconciliation, loading, error }: PayrollLiabilityPanelProps) {
  if (loading) {
    return (
      <Card className="p-5">
        <div className="h-5 w-52 animate-pulse rounded bg-gray-200" />
        <div className="mt-3 h-4 w-80 max-w-full animate-pulse rounded bg-gray-100" />
      </Card>
    );
  }

  if (error) {
    return (
      <Card className="border-red-200 bg-red-50 p-5">
        <h3 className="font-semibold text-red-900">Payroll liability ledger unavailable</h3>
        <p className="mt-1 text-sm text-red-700">{error}</p>
      </Card>
    );
  }

  if (!reconciliation || reconciliation.status === 'not_applicable') return null;

  const statusConfig = {
    posted: { label: 'Posted', variant: 'success' as const, tone: 'border-emerald-200 bg-emerald-50', text: 'text-emerald-900' },
    attention_required: { label: 'Review needed', variant: 'warning' as const, tone: 'border-amber-200 bg-amber-50', text: 'text-amber-900' },
    legacy_unposted: { label: 'Historical · not posted', variant: 'warning' as const, tone: 'border-amber-200 bg-amber-50', text: 'text-amber-900' },
    reversed: { label: 'Reversed', variant: 'default' as const, tone: 'border-gray-200 bg-gray-50', text: 'text-gray-900' },
    not_applicable: { label: 'Not applicable', variant: 'default' as const, tone: 'border-gray-200 bg-gray-50', text: 'text-gray-900' },
  }[reconciliation.status];

  return (
    <Card className={statusConfig.tone}>
      <div className="flex flex-col gap-3 border-b border-current/10 p-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h3 className={`font-semibold ${statusConfig.text}`}>Payroll Liability Ledger</h3>
            <Badge variant={statusConfig.variant}>{statusConfig.label}</Badge>
          </div>
          <p className="mt-1 text-sm text-gray-700">
            Immutable obligations recorded from the stored values on this committed payroll. No tax amounts are recalculated here.
          </p>
        </div>
        <div className="sm:text-right">
          <p className="text-xs font-medium uppercase tracking-wider text-gray-500">Net recorded liability</p>
          <p className={`text-2xl font-bold ${statusConfig.text}`}>{formatCurrency(reconciliation.net_liability)}</p>
        </div>
      </div>

      {reconciliation.status === 'legacy_unposted' ? (
        <div className="p-4 text-sm text-amber-900">
          This payroll predates the liability ledger. Its saved payroll and calculations are unchanged. An operator must preview and explicitly run the historical backfill before liability reconciliation is available.
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-5 p-4 lg:grid-cols-2">
          <div>
            <h4 className="text-xs font-semibold uppercase tracking-wider text-gray-500">By liability category</h4>
            <div className="mt-2 divide-y rounded-lg border border-gray-200 bg-white">
              {Object.entries(reconciliation.totals_by_category).map(([category, amount]) => (
                <div key={category} className="flex items-center justify-between gap-4 px-3 py-2 text-sm">
                  <span className="text-gray-700">{categoryLabels[category] || category.replaceAll('_', ' ')}</span>
                  <span className="font-medium text-gray-950">{formatCurrency(amount)}</span>
                </div>
              ))}
              {Object.keys(reconciliation.totals_by_category).length === 0 && (
                <p className="px-3 py-3 text-sm text-gray-500">No outstanding amount remains on this payroll.</p>
              )}
            </div>
          </div>

          <div>
            <h4 className="text-xs font-semibold uppercase tracking-wider text-gray-500">By recipient</h4>
            <div className="mt-2 divide-y rounded-lg border border-gray-200 bg-white">
              {Object.entries(reconciliation.totals_by_authority).map(([authority, amount]) => (
                <div key={authority} className="flex items-center justify-between gap-4 px-3 py-2 text-sm">
                  <span className="text-gray-700">{authority}</span>
                  <span className="font-medium text-gray-950">{formatCurrency(amount)}</span>
                </div>
              ))}
              {Object.keys(reconciliation.totals_by_authority).length === 0 && (
                <p className="px-3 py-3 text-sm text-gray-500">No recipient balance remains on this payroll.</p>
              )}
            </div>
          </div>
        </div>
      )}

      {reconciliation.unclassified_components.length > 0 && (
        <div className="mx-4 mb-4 rounded-lg border border-amber-300 bg-amber-50 p-3">
          <p className="text-sm font-semibold text-amber-900">Some deductions need a liability category and payee</p>
          <ul className="mt-2 space-y-1 text-sm text-amber-900">
            {reconciliation.unclassified_components.map((component, index) => (
              <li key={`${component.payroll_item_id}-${component.source}-${index}`}>
                {component.label}: {formatCurrency(component.amount)} — {component.reason}
              </li>
            ))}
          </ul>
        </div>
      )}

      {reconciliation.postings.length > 0 && (
        <details className="border-t border-current/10 bg-white/60 px-4 py-3">
          <summary className="cursor-pointer text-sm font-medium text-gray-700">
            Journal history ({reconciliation.postings.length} {reconciliation.postings.length === 1 ? 'posting' : 'postings'})
          </summary>
          <div className="mt-3 space-y-2">
            {reconciliation.postings.map((posting) => (
              <div key={posting.id} className="rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <span className="font-medium text-gray-900">{postingTypeLabels[posting.posting_type]}</span>
                    <span className="ml-2 text-gray-500">Liability date {formatDate(posting.liability_date)}</span>
                  </div>
                  <span className={posting.net_amount < 0 ? 'font-semibold text-red-700' : 'font-semibold text-gray-900'}>
                    {formatCurrency(posting.net_amount)}
                  </span>
                </div>
                <p className="mt-1 text-xs text-gray-500">
                  Recorded {formatGuamDateTime(posting.posted_at)}
                  {posting.posted_by_name ? ` by ${posting.posted_by_name}` : ''}
                  {posting.reason ? ` · ${posting.reason}` : ''}
                </p>
              </div>
            ))}
          </div>
        </details>
      )}

      <div className="border-t border-current/10 px-4 py-3 text-xs text-gray-600">
        This phase records what payroll created. Recording payments, allocations, confirmation numbers, and proof of settlement will be added in the payment-ledger PR; this status does not mean an authority or payee has been paid.
      </div>
    </Card>
  );
}
