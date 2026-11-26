import { FileLock2, TriangleAlert } from 'lucide-react';
import type { ReactElement } from 'react';
import type { PayrollSourceSummary } from '@/services/api';

interface PayrollSourceNoticeProps {
  summary?: PayrollSourceSummary | null;
  mentionFieldScope?: boolean;
}

export function PayrollSourceNotice({ summary, mentionFieldScope = false }: PayrollSourceNoticeProps): ReactElement | null {
  const adjustments = summary?.adjustments || { count: 0, gross_pay_delta: 0, net_pay_delta: 0 };
  if (!summary || (summary.quickbooks.record_count === 0 && (summary.prior_provider?.record_count ?? 0) === 0 && summary.quickbooks.excluded_unlinked_paycheck_count === 0 && adjustments.count === 0)) return null;

  const quickbooks = summary.quickbooks;
  const includedLabels = [
    summary.cornerstone.paycheck_count > 0 ? `${summary.cornerstone.paycheck_count} Cornerstone ${summary.cornerstone.paycheck_count === 1 ? 'paycheck' : 'paychecks'}` : null,
    quickbooks.paycheck_count > 0 ? `${quickbooks.paycheck_count} linked QuickBooks ${quickbooks.paycheck_count === 1 ? 'paycheck' : 'paychecks'}` : null,
    (summary.prior_provider?.paycheck_count ?? 0) > 0 ? `${summary.prior_provider!.paycheck_count} linked prior-provider ${summary.prior_provider!.paycheck_count === 1 ? 'paycheck' : 'paychecks'}` : null,
  ].filter(Boolean);

  return (
    <div className="space-y-3 rounded-2xl border border-amber-200 bg-amber-50 px-4 py-4 text-sm text-amber-950 sm:px-5">
      <div className="flex items-start gap-3">
        <FileLock2 className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" />
        <div>
          <p className="font-semibold">Combined payroll history</p>
          <p className="mt-1 leading-6 text-amber-800">
            This view includes {includedLabels.join(' and ') || 'locked QuickBooks balance history'}. {summary.source_statement}
          </p>
          {totalsBasisNote(summary) && <p className="mt-1 leading-6 text-amber-800">{totalsBasisNote(summary)}</p>}
          {quickbooks.opening_summary_count > 0 && (
            <p className="mt-1 leading-6 text-amber-800">
              It includes {quickbooks.opening_summary_count} QuickBooks opening {quickbooks.opening_summary_count === 1 ? 'summary' : 'summaries'} that preserve earlier totals without representing individual paychecks.
            </p>
          )}
          {mentionFieldScope && <p className="mt-1 leading-6 text-amber-800">Payroll field reconciliation below covers Cornerstone records only.</p>}
          {(summary.source_overlap?.employee_pay_date_count ?? 0) > 0 && (
            <p role="alert" className="mt-2 rounded-lg border border-red-300 bg-red-50 px-4 py-2 font-medium text-red-900">
              Both sources contain {summary.source_overlap?.employee_pay_date_count} matching employee/pay-date {summary.source_overlap?.employee_pay_date_count === 1 ? 'pair' : 'pairs'}. Both are included in the totals; reconcile these records before relying on the report.
            </p>
          )}
          {adjustments.count > 0 && (
            <p className="mt-1 leading-6 text-amber-800">
              {adjustments.count} recorded historical ledger {adjustments.count === 1 ? 'adjustment is' : 'adjustments are'} included separately (gross change {formatMoney(adjustments.gross_pay_delta)}; net change {formatMoney(adjustments.net_pay_delta)}). No source snapshot was rewritten.
            </p>
          )}
        </div>
      </div>
      {quickbooks.excluded_unlinked_paycheck_count > 0 && (
        <div className="flex items-start gap-2 rounded-xl border border-amber-300 bg-white/70 px-3 py-3 text-amber-900">
          <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" />
          <p>
            {quickbooks.excluded_unlinked_paycheck_count} QuickBooks {quickbooks.excluded_unlinked_paycheck_count === 1 ? 'record was' : 'records were'} excluded because no employee is linked. Excluded gross: {formatMoney(quickbooks.excluded_unlinked_gross_pay)}; net: {formatMoney(quickbooks.excluded_unlinked_net_pay)}.
          </p>
        </div>
      )}
    </div>
  );
}

const BRIDGED_FIELDS = 'Gross, non-taxable pay, Guam income tax, Social Security, Medicare, deductions and net pay';

// Full-year totals use the applied opening balance, as pay stubs and W-2GU do.
// A range that starts after January 1 can't, so its imported rows show as imported.
function totalsBasisNote(summary: PayrollSourceSummary): string | null {
  const basis = summary.historical_ytd_bridge?.totals_basis;
  if (basis === 'historical_ytd_bridge') return `${BRIDGED_FIELDS} for imported history come from the applied opening year-to-date balance, the same figures as pay stubs and W-2GU. Hours, 401(k), employer costs and other categories are shown as imported.`;
  if (basis === 'mixed') return `For some employees, ${BRIDGED_FIELDS.toLowerCase()} for imported history come from the applied opening year-to-date balance; everything else is shown as imported.`;
  if (basis === 'as_imported' && summary.historical_ytd_bridge.applied) return 'Imported figures are shown as imported. The opening year-to-date balance covers the year from January 1, so it applies only to ranges that include its whole period.';
  return null;
}

function formatMoney(value: number): string {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(Number(value) || 0);
}
