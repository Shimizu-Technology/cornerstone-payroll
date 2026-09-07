import { FileLock2, TriangleAlert } from 'lucide-react';
import type { ReactElement } from 'react';
import type { PayrollSourceSummary } from '@/services/api';

interface PayrollSourceNoticeProps {
  summary?: PayrollSourceSummary | null;
  mentionFieldScope?: boolean;
}

export function PayrollSourceNotice({ summary, mentionFieldScope = false }: PayrollSourceNoticeProps): ReactElement | null {
  if (!summary || (summary.quickbooks.paycheck_count === 0 && summary.quickbooks.excluded_unlinked_paycheck_count === 0)) return null;

  const quickbooks = summary.quickbooks;
  const importedLabel = `${quickbooks.paycheck_count} linked QuickBooks ${quickbooks.paycheck_count === 1 ? 'record' : 'records'}`;
  const cornerstoneLabel = `${summary.cornerstone.paycheck_count} Cornerstone ${summary.cornerstone.paycheck_count === 1 ? 'record' : 'records'}`;

  return (
    <div className="space-y-3 rounded-2xl border border-amber-200 bg-amber-50 px-4 py-4 text-sm text-amber-950 sm:px-5">
      <div className="flex items-start gap-3">
        <FileLock2 className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" />
        <div>
          <p className="font-semibold">Combined payroll history</p>
          <p className="mt-1 leading-6 text-amber-800">
            This view combines {cornerstoneLabel} with {importedLabel}. {summary.source_statement}
          </p>
          {quickbooks.opening_summary_count > 0 && (
            <p className="mt-1 leading-6 text-amber-800">
              It includes {quickbooks.opening_summary_count} QuickBooks opening {quickbooks.opening_summary_count === 1 ? 'summary' : 'summaries'} that preserve earlier totals without representing individual paychecks.
            </p>
          )}
          {mentionFieldScope && <p className="mt-1 leading-6 text-amber-800">Payroll field reconciliation below covers Cornerstone records only.</p>}
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

function formatMoney(value: number): string {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(Number(value) || 0);
}
