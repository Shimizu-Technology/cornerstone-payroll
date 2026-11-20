import { useCallback, useEffect, useState, type ReactElement } from 'react';
import { Link, useSearchParams } from 'react-router';
import { AlertCircle, ArrowRight, CheckCircle2, ClipboardList, RefreshCw } from 'lucide-react';
import { FilingSubmitterCard } from '@/components/year-end/FilingSubmitterCard';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { MobileRecordCard } from '@/components/ui/mobile-record';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { yearEndApi } from '@/services/api';
import { formatDate } from '@/lib/utils';
import {
  clientStatusLabel,
  parseYearEndTaxYear,
  yearEndTaxYears,
  type YearEndClientRow,
  type YearEndClientsOverview,
} from '@/lib/year-end';

function statusVariant(row: YearEndClientRow): 'success' | 'warning' | 'danger' | 'info' | 'default' {
  if (row.status === 'ready') return 'success';
  if (row.status === 'not_filing') return 'default';
  if (row.status === 'check_needed') return 'info';
  return row.issue_summary.some((item) => item.code === 'FILER_NOT_CHOSEN') ? 'danger' : 'warning';
}

function issueChipLabel(item: YearEndClientRow['issue_summary'][number]): string {
  if (item.code === 'EMPLOYEE_DETAILS_MISSING') {
    return `${item.count} ${item.count === 1 ? 'employee needs' : 'employees need'} an SSN or address`;
  }
  return item.label;
}

function whoFiles(row: YearEndClientRow): string | null {
  if (!row.w2 || !row.form_1099) return null;
  return `W-2s: ${row.w2.label} · 1099s: ${row.form_1099.label}`;
}

// Words, not symbols, so screen readers announce each filing's state.
function filingProgressText(row: YearEndClientRow): string {
  return (row.filing_progress ?? []).map((filing) => `${filing.label} ${filing.status.replaceAll('_', ' ')}`).join(' · ');
}

function ClientStatus({ row }: { row: YearEndClientRow }): ReactElement {
  return (
    <Badge variant={statusVariant(row)} className="gap-1">
      {row.status === 'ready' && <CheckCircle2 className="h-3.5 w-3.5" aria-hidden="true" />}
      {clientStatusLabel(row)}
    </Badge>
  );
}

function IssueChips({ row }: { row: YearEndClientRow }): ReactElement | null {
  if (row.status === 'ready') {
    return <p className="text-sm text-neutral-600">{row.marked_ready_at ? `W-2s marked ready ${formatDate(row.marked_ready_at)}` : 'Nothing left to do'}</p>;
  }
  if (row.status === 'check_needed') {
    return <p className="text-sm text-neutral-700">{row.check_reason ?? 'Open the checklist to re-check.'}</p>;
  }
  if (row.issue_summary.length === 0) return null;
  return (
    <div className="space-y-2">
      <ul className="flex flex-wrap gap-1.5" aria-label={`What is left for ${row.name}`}>
        {row.issue_summary.map((item) => (
          <li key={item.code}>
            <Badge variant="outline" wrap>{issueChipLabel(item)}</Badge>
          </li>
        ))}
      </ul>
      {row.efile_check_pending && <p className="text-sm text-neutral-700">More may show after the employee e-file check.</p>}
    </div>
  );
}

function OpenLink({ row }: { row: YearEndClientRow }): ReactElement {
  const primary = row.status === 'needs_action' || row.status === 'check_needed';
  const verb = row.status === 'check_needed' ? 'Check' : primary ? 'Fix' : 'Open';
  return (
    <Link
      to={row.checklist_path}
      aria-label={`${verb} ${row.name}`}
      className={primary
        ? 'inline-flex min-h-11 w-full items-center justify-center gap-1.5 rounded-full bg-primary-700 px-4 py-2 text-sm font-semibold text-white transition hover:bg-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2 sm:w-auto'
        : 'inline-flex min-h-11 w-full items-center justify-center gap-1.5 rounded-full border border-neutral-300 bg-white px-4 py-2 text-sm font-semibold text-neutral-800 transition hover:border-primary-300 hover:text-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2 sm:w-auto'}
    >
      {verb}
      <ArrowRight className="h-4 w-4" aria-hidden="true" />
    </Link>
  );
}

function ClientSection({ title, rows, description }: { title: string; rows: YearEndClientRow[]; description: string }): ReactElement | null {
  if (rows.length === 0) return null;
  const headingId = `year-end-${title.toLowerCase().replace(/\W+/g, '-')}`;
  return (
    <section aria-labelledby={headingId} className="space-y-3">
      <div>
        <h2 id={headingId} className="font-display text-lg font-bold text-neutral-950">{title} <span className="text-neutral-500">({rows.length})</span></h2>
        <p className="text-sm text-neutral-600">{description}</p>
      </div>

      <div className="space-y-3 sm:hidden">
        {rows.map((row) => (
          <MobileRecordCard key={row.company_id}>
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="font-semibold text-neutral-950 [overflow-wrap:anywhere]">{row.name}</p>{!!row.filing_progress?.length && <p className="mt-1 text-xs text-neutral-600">{filingProgressText(row)}</p>}
                {!row.active && <Badge variant="outline" className="mt-1">Inactive record</Badge>}
              </div>
              <ClientStatus row={row} />
            </div>
            <div className="mt-3 space-y-2">
              <IssueChips row={row} />
              {whoFiles(row) && <p className="text-xs text-neutral-600">{whoFiles(row)}</p>}
            </div>
            <div className="mt-4"><OpenLink row={row} /></div>
          </MobileRecordCard>
        ))}
      </div>

      <Card className="hidden overflow-hidden sm:block">
        <Table className="[&_td]:px-4 [&_th]:px-4">
          <TableHeader>
            <TableRow>
              <TableHead>Client</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>What is left</TableHead>
              <TableHead>Who files</TableHead>
              <TableHead className="text-right"><span className="sr-only">Action</span></TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.company_id}>
                <TableCell className="min-w-[10rem] whitespace-normal!">
                  <p className="font-semibold text-neutral-950">{row.name}</p>{!!row.filing_progress?.length && <p className="mt-1 text-xs text-neutral-600">{filingProgressText(row)}</p>}
                  {!row.active && <Badge variant="outline" className="mt-1">Inactive record</Badge>}
                </TableCell>
                <TableCell className="whitespace-nowrap"><ClientStatus row={row} /></TableCell>
                <TableCell className="min-w-[14rem] whitespace-normal!"><IssueChips row={row} /></TableCell>
                <TableCell className="min-w-[12rem] whitespace-normal! text-sm text-neutral-700">{whoFiles(row) ?? 'Not chosen yet'}</TableCell>
                <TableCell className="text-right"><OpenLink row={row} /></TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </Card>
    </section>
  );
}

export function YearEnd(): ReactElement {
  const [searchParams, setSearchParams] = useSearchParams();
  const year = parseYearEndTaxYear(searchParams.get('year'));
  const [loaded, setLoaded] = useState<YearEndClientsOverview | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);

  const load = useCallback(async (signal: { cancelled: boolean }) => {
    setLoading(true);
    setError(null);
    try {
      const response = await yearEndApi.clients(year);
      if (!signal.cancelled) setLoaded(response.data);
    } catch (err) {
      if (!signal.cancelled) {
        setLoaded(null);
        setError(err instanceof Error ? err.message : 'The year-end list could not be loaded.');
      }
    } finally {
      if (!signal.cancelled) setLoading(false);
    }
  }, [year]);

  useEffect(() => {
    const signal = { cancelled: false };
    void load(signal);
    return () => { signal.cancelled = true; };
  }, [load, attempt]);

  // Another year's list never shows while the selected year loads.
  const overview = loaded?.tax_year === year ? loaded : null;
  const rows = overview?.clients ?? [];
  // A client that changed after it was marked ready needs a re-check, so it is on the to-do list too.
  const toDo = rows.filter((row) => row.status === 'needs_action' || row.status === 'check_needed');
  const ready = rows.filter((row) => row.status === 'ready');
  const notFiling = rows.filter((row) => row.status === 'not_filing');
  const hiddenParts = [
    overview?.hidden.test_workspaces ? `${overview.hidden.test_workspaces} test workspace${overview.hidden.test_workspaces === 1 ? '' : 's'}` : null,
    overview?.hidden.inactive_without_payroll ? `${overview.hidden.inactive_without_payroll} inactive record${overview.hidden.inactive_without_payroll === 1 ? '' : 's'} with no ${year} payroll` : null,
  ].filter(Boolean);

  return (
    <div>
      <Header
        title="Year-End Filing"
        description={`Get every client's ${year} W-2GUs and 1099s ready. Work from the top: the clients with the most left to fix come first.`}
        contextLabel="Tax year"
        contextValue={String(year)}
        mobileSticky={false}
        actions={(
          <div className="flex items-end gap-2">
            <Button variant="outline" disabled={loading} onClick={() => setAttempt((value) => value + 1)}>
              <RefreshCw className="mr-1.5 h-4 w-4" aria-hidden="true" />Refresh
            </Button>
            <div className="w-32">
              <Select
                label="Tax year"
                value={String(year)}
                onChange={(event) => setSearchParams({ year: event.target.value })}
                className="min-h-11"
              >
                {yearEndTaxYears().map((option) => <option key={option} value={option}>{option}</option>)}
              </Select>
            </div>
          </div>
        )}
      />

      <div className="space-y-6 p-4 sm:p-6 lg:p-8">
        <FilingSubmitterCard />
        {error && (
          <Card role="alert" className="border-danger-200 bg-danger-50/40 p-4 sm:p-5">
            <p className="flex gap-2 font-semibold text-danger-800"><AlertCircle className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" />The year-end list could not be loaded.</p>
            <p className="mt-1 text-sm text-danger-700">{error}</p>
            <Button size="sm" variant="outline" className="mt-3" onClick={() => setAttempt((value) => value + 1)}>
              <RefreshCw className="mr-1.5 h-4 w-4" aria-hidden="true" />Try again
            </Button>
          </Card>
        )}

        {loading && !overview && (
          <div className="space-y-3" role="status" aria-label="Loading clients">
            {[0, 1, 2].map((index) => <div key={index} className="h-24 animate-pulse rounded-2xl bg-neutral-100" />)}
          </div>
        )}

        {overview && (
          <>
            {!!overview.filing_reminder_count && <p className="text-sm font-semibold text-warning-800">{overview.filing_reminder_count === 1 ? '1 client needs' : `${overview.filing_reminder_count} clients need`} filing attention. Review portal submissions and agency results before the deadline.</p>}
            <dl className="grid grid-cols-3 gap-2 sm:max-w-xl sm:gap-3">
              {[
                { label: 'To do', value: overview.counts.needs_action + (overview.counts.check_needed ?? 0), tone: 'text-warning-800' },
                { label: 'Ready', value: overview.counts.ready, tone: 'text-success-800' },
                { label: 'Not filed by us', value: overview.counts.not_filing, tone: 'text-neutral-700' },
              ].map((stat) => (
                <div key={stat.label} className="rounded-2xl border border-neutral-200 bg-white px-3 py-3 text-center sm:px-4">
                  <dt className="text-xs font-semibold text-neutral-600">{stat.label}</dt>
                  <dd className={`mt-1 font-display text-2xl font-extrabold ${stat.tone}`}>{stat.value}</dd>
                </div>
              ))}
            </dl>

            {rows.length === 0 ? (
              <Card className="p-6 text-center">
                <ClipboardList className="mx-auto h-8 w-8 text-neutral-400" aria-hidden="true" />
                <h2 className="mt-3 font-display text-lg font-bold text-neutral-950">No clients to show for {year}</h2>
                <p className="mx-auto mt-1 max-w-md text-sm text-neutral-600">
                  None of the clients you can open have {year} payroll or a year-end decision yet.
                </p>
              </Card>
            ) : (
              <>
                <ClientSection title="To do" rows={toDo} description="Open a client to see each item and fix it, or to re-check one that changed after it was marked ready." />
                <ClientSection title="Ready" rows={ready} description="W-2s are marked ready on the current numbers." />
                <ClientSection title="Not filed by Cornerstone" rows={notFiling} description="The client, another provider, or nobody files these forms. Nothing to do here unless that changes." />
              </>
            )}

            {hiddenParts.length > 0 && (
              <p className="text-xs text-neutral-600">Hidden: {hiddenParts.join(' and ')}.</p>
            )}
          </>
        )}
      </div>
    </div>
  );
}
