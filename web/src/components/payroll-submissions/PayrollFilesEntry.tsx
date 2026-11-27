import { formatDateRange } from '@/lib/display-date';
import { useCallback, useEffect, useState, type ReactElement } from 'react';
import { Link } from 'react-router';
import { useCompany } from '@/contexts/CompanyContext';
import { useClientViewOnly } from '@/hooks/useClientViewOnly';
import { FileSpreadsheet } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { clientPayrollStatus } from '@/lib/clientPayrollStatus';
import { hasPortalSubmittableAdapter, intakeAdaptersForPayPeriod } from '@/lib/importSources';
import { currentSubmissionPeriod, formatDate, statusVariant } from '@/lib/payrollSubmissionFormat';
import { clientPayrollSubmissionsApi, type PeriodSummary } from '@/services/payrollSubmissions';
import type { CompanyListItem } from '@/services/api';

function portalSourcePhrase(company?: Pick<CompanyListItem, 'payroll_intake_adapters' | 'payroll_intake_source_types'> | null): string {
  const adapter = intakeAdaptersForPayPeriod(company?.payroll_intake_adapters, company?.payroll_intake_source_types)
    .find((candidate) => candidate.portal?.submittable);
  if (adapter?.key === 'mosa_revel') return 'the Revel payroll';
  if (adapter?.key === 'cornerstone_workbook') return 'your hours workbook';
  if (adapter?.label) return `your ${adapter.label}`;
  return 'your payroll files';
}

function actionLabel(period: PeriodSummary, viewOnly: boolean): string {
  if (viewOnly) return 'View pay period files';
  if (period.review_pay_period_id) return 'Open pay period files';
  if (period.status === 'draft_ready') return 'Review the draft';
  if (period.status === 'waiting_for_files') return period.open_for_files ? 'Send payroll files' : 'Open pay period files';
  if (period.status === 'changes_requested') return 'Send updated payroll files';
  return 'Open pay period files';
}

function detailLine(period: PeriodSummary): string {
  const parts = [period.pay_date ? `Pay date ${formatDate(period.pay_date)}` : 'Pay date set by Cornerstone'];
  if (period.status === 'waiting_for_files' && !period.open_for_files) parts.push(`Opens for files ${formatDate(period.opens_on)}`);
  if (period.status === 'waiting_for_files' && period.open_for_files) parts.push('Nothing sent yet');
  return parts.join(' · ');
}

/** The client Home entry to Pay Period Files: the current period, its status, and how it differs from Pay Periods. */
export function PayrollFilesEntry(): ReactElement | null {
  const { activeCompany } = useCompany();
  return hasPortalSubmittableAdapter(activeCompany) && activeCompany
    ? <EnabledPayrollFilesEntry key={activeCompany.id} sourcePhrase={portalSourcePhrase(activeCompany)} />
    : null;
}

function EnabledPayrollFilesEntry({ sourcePhrase }: { sourcePhrase: string }): ReactElement {
  const viewOnly = useClientViewOnly();
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
    <Card aria-labelledby="send-payroll-files-heading" role="region" className={viewOnly ? 'border-neutral-200 bg-white' : 'border-primary-300 bg-primary-50/60'}>
      <CardContent className="py-6">
        <div className="flex flex-col gap-5 lg:flex-row lg:items-center lg:justify-between">
          <div className="min-w-0">
            <p className={`flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.14em] ${viewOnly ? 'text-neutral-600' : 'text-primary-700'}`}>
              <FileSpreadsheet className="h-4 w-4" aria-hidden="true" />Pay period files
            </p>
            <h2 id="send-payroll-files-heading" className="mt-2 text-xl font-semibold tracking-tight text-neutral-900">
              {viewOnly ? 'View pay period files' : 'Send payroll files for this pay period'}
            </h2>
            {!rows && !error && <p role="status" className="mt-2 text-sm text-neutral-600">Checking your current pay period…</p>}
            {error && <p role="alert" className="mt-2 text-sm text-danger-700">We could not load your current pay period. You can still open Pay period files.</p>}
            {rows && !period && <p className="mt-2 text-sm text-neutral-700">No pay period is open for files yet. Cornerstone will set up the next one.</p>}
            {period && (
              <div className="mt-2 space-y-1">
                <p className="flex flex-wrap items-center gap-2 text-base font-semibold text-neutral-900">
                  <span>Payroll {formatDateRange(period.start_date, period.end_date) || period.label}</span>
                  <Badge variant={statusVariant(period.status)}>{period.client_payroll_status && period.client_payroll_status !== 'preparing' ? clientPayrollStatus(period.client_payroll_status) : period.status_label}</Badge>
                  {period.unread && <Badge variant="warning">New</Badge>}
                </p>
                <p className="text-sm text-neutral-600">{detailLine(period)}</p>
              </div>
            )}
            <p className="mt-3 max-w-2xl text-sm leading-6 text-neutral-700">
              <span className="font-semibold">Pay period files</span> is where {viewOnly ? `client managers send Cornerstone ${sourcePhrase} and report changes for a pay period.` : `you send Cornerstone ${sourcePhrase} and report changes for a pay period.`}
              {' '}<span className="font-semibold">Pay periods</span> shows open payrolls, published previews and payroll history.
            </p>
          </div>
          <div className="flex flex-col gap-2 sm:flex-row lg:flex-col lg:items-stretch">
            {error ? <Button type="button" variant="outline" onClick={() => void load()}>Try again</Button> : null}
            <Link
              to={target}
              className={viewOnly
                ? 'inline-flex min-h-11 items-center justify-center whitespace-nowrap rounded-full border border-neutral-300 bg-white px-5 py-2.5 text-sm font-semibold tracking-[-0.01em] text-neutral-900 hover:bg-neutral-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2'
                : 'inline-flex min-h-11 items-center justify-center whitespace-nowrap rounded-full bg-primary-700 px-5 py-2.5 text-sm font-semibold tracking-[-0.01em] text-white hover:bg-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2'}
            >
              {period ? actionLabel(period, viewOnly) : viewOnly ? 'View pay period files' : 'Open pay period files'}
            </Link>
            {period && <Link to="/payroll-files" className="inline-flex min-h-11 items-center justify-center text-sm font-medium text-primary-800 underline">See all pay periods for files</Link>}
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
