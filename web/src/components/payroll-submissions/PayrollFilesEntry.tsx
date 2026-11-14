import { useCallback, useEffect, useState, type ReactElement } from 'react';
import { Link } from 'react-router';
import { useCompany } from '@/contexts/CompanyContext';
import { FileSpreadsheet } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { currentSubmissionPeriod, formatDate, statusVariant } from '@/lib/payrollSubmissionFormat';
import { clientPayrollSubmissionsApi, type PeriodSummary } from '@/services/payrollSubmissions';

function actionLabel(period: PeriodSummary): string {
  if (period.status === 'draft_ready') return 'Review the draft';
  if (period.status === 'waiting_for_files') return period.open_for_files ? 'Send payroll files' : 'Open payroll files';
  if (period.status === 'changes_requested') return 'Send updated payroll files';
  return 'Open payroll files';
}

function detailLine(period: PeriodSummary): string {
  const parts = [period.pay_date ? `Pay date ${formatDate(period.pay_date)}` : 'Pay date set by Cornerstone'];
  if (period.status === 'waiting_for_files' && !period.open_for_files) parts.push(`Opens for files ${formatDate(period.opens_on)}`);
  if (period.status === 'waiting_for_files' && period.open_for_files) parts.push('Nothing sent yet');
  return parts.join(' · ');
}

/** The client Home entry to Payroll Files: the current period, its status, and how it differs from Pay Periods. */
export function PayrollFilesEntry(): ReactElement | null {
  const { activeCompany } = useCompany();
  return activeCompany?.payroll_intake_source_types?.includes('mosa_revel') ? <EnabledPayrollFilesEntry key={activeCompany.id} /> : null;
}

function EnabledPayrollFilesEntry(): ReactElement {
  const [rows, setRows] = useState<PeriodSummary[] | null>(null);
  const [error, setError] = useState(false);
  const load = useCallback(async () => {
    setError(false);
    try { setRows((await clientPayrollSubmissionsApi.list()).data); } catch { setError(true); }
  }, []);
  useEffect(() => { void load(); }, [load]);

  const period = rows ? currentSubmissionPeriod(rows) : null;
  const target = period ? `/payroll-files/${encodeURIComponent(period.ref)}` : '/payroll-files';
  return (
    <Card aria-labelledby="send-payroll-files-heading" role="region" className="border-primary-300 bg-primary-50/60">
      <CardContent className="py-6">
        <div className="flex flex-col gap-5 lg:flex-row lg:items-center lg:justify-between">
          <div className="min-w-0">
            <p className="flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.14em] text-primary-700">
              <FileSpreadsheet className="h-4 w-4" aria-hidden="true" />Payroll files
            </p>
            <h2 id="send-payroll-files-heading" className="mt-2 text-xl font-semibold tracking-tight text-neutral-900">Send payroll files for this pay period</h2>
            {!rows && !error && <p role="status" className="mt-2 text-sm text-neutral-600">Checking your current pay period…</p>}
            {error && <p role="alert" className="mt-2 text-sm text-danger-700">We could not load your current pay period. You can still open Payroll Files.</p>}
            {rows && !period && <p className="mt-2 text-sm text-neutral-700">No pay period is open for files yet. Cornerstone will set up the next one.</p>}
            {period && (
              <div className="mt-2 space-y-1">
                <p className="flex flex-wrap items-center gap-2 text-base font-semibold text-neutral-900">
                  <span>Payroll {period.label}</span>
                  <Badge variant={statusVariant(period.status)}>{period.status_label}</Badge>
                  {period.unread && <Badge variant="warning">New</Badge>}
                </p>
                <p className="text-sm text-neutral-600">{detailLine(period)}</p>
              </div>
            )}
            <p className="mt-3 max-w-2xl text-sm leading-6 text-neutral-700">
              <span className="font-semibold">Payroll Files</span> is where you send Cornerstone the Revel payroll and any changes for a pay period, then review the draft.
              {' '}<span className="font-semibold">Pay Periods</span> shows payrolls Cornerstone has already processed, with each employee’s pay.
            </p>
          </div>
          <div className="flex flex-col gap-2 sm:flex-row lg:flex-col lg:items-stretch">
            {error ? <Button type="button" variant="outline" onClick={() => void load()}>Try again</Button> : null}
            <Link to={target} className="inline-flex min-h-11 items-center justify-center whitespace-nowrap rounded-full bg-primary-700 px-5 py-2.5 text-sm font-semibold tracking-[-0.01em] text-white hover:bg-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2">
              {period ? actionLabel(period) : 'Open Payroll Files'}
            </Link>
            {period && <Link to="/payroll-files" className="inline-flex min-h-11 items-center justify-center text-sm font-medium text-primary-800 underline">See all pay periods for files</Link>}
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
