import { useCallback, useEffect, useState, type ReactElement } from 'react';
import { Link, useParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate, formatGuam, statusVariant } from '@/lib/payrollSubmissionFormat';
import { adminPayrollSubmissionsApi, clientPayrollSubmissionsApi, type PeriodSummary } from '@/services/payrollSubmissions';

export function PayrollPeriodsList({ audience }: { audience: 'client' | 'staff' }): ReactElement {
  const { companyId } = useParams();
  const api = audience === 'client' ? clientPayrollSubmissionsApi : adminPayrollSubmissionsApi;
  const base = audience === 'client' ? '/payroll-files' : companyId ? `/companies/${companyId}/payroll-submissions` : '/settings/payroll-submissions';
  const [rows, setRows] = useState<PeriodSummary[] | null>(null);
  const [derived, setDerived] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    try {
      setError(null);
      const response = await api.list();
      setRows(response.data);
      setDerived(response.meta.derives_from_schedule);
    } catch (err) { setError(err instanceof Error ? err.message : 'Could not load pay periods'); }
  }, [api]);
  useEffect(() => { void load(); }, [load]);

  return (
    <div>
      <Header title="Pay period files"
        description={audience === 'client' ? 'Send each pay period’s Revel payroll and changes, then review the draft.' : 'What each client sent for a pay period, and where review stands.'} />
      <div className="mx-auto max-w-5xl space-y-4 p-4 sm:p-6 lg:p-8">
        <p className="text-sm text-neutral-600">{derived ? 'Periods follow the pay schedule.' : 'Periods are the pay periods Cornerstone has set up.'} {audience === 'client' ? 'A period opens for files on its last day.' : 'Change the schedule in Pay Schedule settings.'}</p>
        {error && <div role="alert" className="rounded-lg border border-danger-200 p-4"><p>{error}</p><Button variant="outline" className="mt-2" onClick={() => void load()}>Try again</Button></div>}
        {!rows && !error && <p role="status">Loading pay periods…</p>}
        {rows && !rows.length && <p className="rounded-lg border border-neutral-200 bg-white p-6 text-neutral-700">{audience === 'client' ? 'No pay periods are open yet. Cornerstone will set up the next one.' : 'No pay periods yet. Set the pay schedule or create the pay period first.'}</p>}
        {rows && rows.length > 0 && <ul className="divide-y divide-neutral-200 rounded-xl border border-neutral-200 bg-white">
          {rows.map(row => <li key={row.ref}>
            <Link to={`${base}/${row.ref}`} className="flex min-h-11 flex-col gap-2 p-4 hover:bg-primary-50 focus-visible:outline-2 focus-visible:outline-offset-2 sm:flex-row sm:items-center sm:justify-between">
              <span className="min-w-0">
                <span className="block font-semibold text-neutral-950">Payroll {row.label}</span>
                <span className="mt-1 block text-sm text-neutral-600">
                  {row.pay_date ? `Pay date ${formatDate(row.pay_date)}` : 'Pay date set by Cornerstone'}
                  {row.current_revision ? ` · Revision ${row.current_revision} sent ${formatGuam(row.last_submitted_at)}` : ''}
                  {!row.open_for_files && row.status === 'waiting_for_files' ? ` · Opens ${formatDate(row.opens_on)}` : ''}
                </span>
              </span>
              <span className="flex shrink-0 items-center gap-2">
                {row.unread && <Badge variant="warning">New</Badge>}
                <Badge variant={statusVariant(row.status)}>{row.status_label}</Badge>
              </span>
            </Link>
          </li>)}
        </ul>}
      </div>
    </div>
  );
}
