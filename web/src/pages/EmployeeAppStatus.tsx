import { useEffect, useId, useMemo, useState } from 'react';
import { Link } from 'react-router';
import { ArrowDown, ArrowUp, ArrowUpDown, Download } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { AccountCell, AnswerCell, TermsFact } from '@/components/employee-app/AppStatusFacts';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useCompany } from '@/contexts/CompanyContext';
import { employeeAppRolloutPath, employeeAppStatusPath, employeePath } from '@/lib/routes';
import { saveBlob } from '@/lib/save-blob';
import { employeeAppOff } from '@/services/employee-app-rollout-api';
import {
  employeeAppStatusApi, opensCoverageNote, type AppStatusFilter, type AppStatusQuery, type AppStatusReport, type AppStatusRow,
} from '@/services/employee-app-status-api';

const STATUS_FILTERS: [AppStatusFilter, string][] = [
  ['not_signed_up', 'Not signed up'],
  ['signed_up_no_opens', 'Signed up, no recorded opens'],
  ['invite_expired', 'Invite expired'],
  ['terms_not_accepted', 'Hasn’t accepted terms'],
  ['no_paperless_answer', 'No paperless answer'],
  ['kept_paper', 'Kept paper (needs paper copies)'],
];

type SortKey = 'name' | 'account';
const textLink = 'inline-flex min-h-11 items-center text-sm font-semibold text-primary-800 underline underline-offset-2 [overflow-wrap:anywhere]';

export function EmployeeAppStatus({ audience }: { audience: 'admin' | 'client' }) {
  const { activeCompany } = useCompany();
  if (!activeCompany) return <WorkspaceLoader label="Loading client" />;
  return <CompanyAppStatus key={`${activeCompany.id}:${audience}`} companyId={activeCompany.id} audience={audience} />;
}

function useDebounced<T>(value: T, delay = 250): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(value), delay);
    return () => window.clearTimeout(timer);
  }, [value, delay]);
  return debounced;
}

function CompanyAppStatus({ companyId, audience }: { companyId: number; audience: 'admin' | 'client' }) {
  const api = useMemo(() => employeeAppStatusApi(companyId, audience), [companyId, audience]);
  // The result on screen and the exact params it was loaded with: exports use these.
  const [loaded, setLoaded] = useState<{ report: AppStatusReport; params: AppStatusQuery } | null>(null);
  const report = loaded?.report ?? null;
  const [loadError, setLoadError] = useState('');
  const [attempt, setAttempt] = useState(0);
  const [filter, setFilter] = useState<AppStatusFilter | null>(null);
  const [departmentId, setDepartmentId] = useState('');
  const [role, setRole] = useState('');
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<{ key: SortKey; direction: 'asc' | 'desc' }>({ key: 'name', direction: 'asc' });
  const [downloading, setDownloading] = useState<'csv' | 'xlsx' | null>(null);
  const [downloadError, setDownloadError] = useState('');
  const query = useDebounced(search.trim());
  const searchId = useId();

  // Filtering happens in the API, so the export matches what's on screen.
  const params: AppStatusQuery = useMemo(() => ({
    filter: filter ?? undefined, department_id: departmentId || undefined, role: role || undefined, q: query || undefined,
  }), [filter, departmentId, role, query]);

  useEffect(() => {
    let current = true;
    void api.get(params).then(({ data }) => {
      if (current) { setLoaded({ report: data, params }); setLoadError(''); }
    }).catch(() => {
      if (current) setLoadError('Could not load the employee app status. Try again.');
    });
    return () => { current = false; };
  }, [api, params, attempt]);

  const rows = useMemo(() => sortRows(report?.employees ?? [], sort.key, sort.direction), [report, sort]);
  const returnTo = employeeAppStatusPath(companyId);
  const recordPath = (employeeId: number) => employeePath(companyId, employeeId, 'overview', { returnTo });
  const toggleSort = (key: SortKey) => setSort((current) => ({
    key, direction: current.key === key && current.direction === 'asc' ? 'desc' : 'asc',
  }));

  // Until the result for the current filters arrives, the screen shows the
  // previous one; exporting then would not match it, so Download waits.
  const stale = !loaded || loaded.params !== params;

  async function download(format: 'csv' | 'xlsx') {
    if (!loaded || stale) return;
    setDownloading(format);
    setDownloadError('');
    try {
      const { blob, filename } = await api.download(format, loaded.params);
      saveBlob(blob, filename || `employee-app-status.${format}`);
    } catch {
      setDownloadError('Could not download the report. Try again.');
    } finally {
      setDownloading(null);
    }
  }

  const summary = report?.summary;
  return (
    <div>
      <Header title="Employee app status" mobileSticky={false} actions={
        <Link className={textLink} to={employeeAppRolloutPath(companyId)}>{audience === 'client' ? 'Invites' : 'Rollout and invites'}</Link>
      } />
      <div className="mx-auto max-w-6xl space-y-5 p-4 sm:p-6 lg:p-8">
        {loadError && <div className="flex flex-wrap items-center gap-2"><p role="alert" className="text-sm text-danger-700">{loadError}</p><Button type="button" variant="outline" onClick={() => setAttempt((value) => value + 1)}>Try again</Button></div>}
        {!report && !loadError && <WorkspaceLoader label="Loading employee app status" />}
        {report && summary && <>
          {!report.enabled && <p role="status" className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-800">{employeeAppOff}</p>}
          <section aria-label="Summary" className="space-y-3">
            <p className="text-2xl font-semibold text-neutral-950">
              <span className="tabular-nums">{summary.signed_up}</span> of <span className="tabular-nums">{summary.total}</span> signed up
              <span className="text-neutral-500"> · </span>
              <span className="tabular-nums">{summary.opened}</span> {summary.opened === 1 ? 'has' : 'have'} opened the app
            </p>
            <p className="text-sm text-neutral-700">
              Signed up means their app account works now. {opensCoverageNote(report.opens_recorded_since)}
            </p>
            {!report.delivery_consent_enabled && (
              <p className="text-sm text-neutral-700">Employees aren’t asked about paperless pay stubs or W-2GU yet. Paper copies continue for everyone.</p>
            )}
          </section>

          <section aria-label="Filters" className="space-y-3">
            <div className="flex flex-wrap gap-2" role="group" aria-label="Show only">
              <FilterChip label="All active employees" count={summary.total} pressed={filter === null} onClick={() => setFilter(null)} />
              {STATUS_FILTERS.map(([key, label]) => (
                <FilterChip key={key} label={label} count={summary[key]} pressed={filter === key}
                  onClick={() => setFilter((current) => (current === key ? null : key))} />
              ))}
            </div>
            <div className="grid gap-3 sm:grid-cols-3">
              <div className="space-y-1.5">
                <label htmlFor={searchId} className="text-sm font-semibold text-neutral-800">Search by name</label>
                <Input id={searchId} type="search" value={search} onChange={(event) => setSearch(event.target.value)} className="text-base" autoComplete="off" />
              </div>
              {report.departments.length > 0 && (
                <Select label="Department" value={departmentId} onChange={(event) => setDepartmentId(event.target.value)}
                  options={[{ value: '', label: 'All departments' }, ...report.departments.map((department) => ({ value: String(department.id), label: department.name }))]} />
              )}
              {report.roles.length > 0 && (
                <Select label="Role" value={role} onChange={(event) => setRole(event.target.value)}
                  options={[{ value: '', label: 'All roles' }, ...report.roles.map((name) => ({ value: name, label: name }))]} />
              )}
            </div>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p role="status" aria-live="polite" className="text-sm text-neutral-700">
                {stale ? 'Updating…' : `Showing ${rows.length} ${rows.length === 1 ? 'employee' : 'employees'}`}
              </p>
              <div className="flex flex-wrap gap-2">
                <Button type="button" variant="outline" loading={downloading === 'csv'} disabled={downloading !== null || stale} onClick={() => void download('csv')}>
                  <Download aria-hidden="true" className="size-4" /> CSV
                </Button>
                <Button type="button" variant="outline" loading={downloading === 'xlsx'} disabled={downloading !== null || stale} onClick={() => void download('xlsx')}>
                  <Download aria-hidden="true" className="size-4" /> Excel
                </Button>
              </div>
            </div>
            {downloadError && <p role="alert" className="text-sm text-danger-700">{downloadError}</p>}
          </section>

          {rows.length === 0 ? (
            <p className="rounded-xl border border-neutral-200 bg-white p-4 text-sm text-neutral-700">No employees match these filters.</p>
          ) : <>
            <div className="sm:hidden">
              <Select label="Sort by" value={`${sort.key}:${sort.direction}`}
                onChange={(event) => {
                  const [key, direction] = event.target.value.split(':') as [SortKey, 'asc' | 'desc'];
                  setSort({ key, direction });
                }}
                options={[
                  { value: 'name:asc', label: 'Name, A to Z' },
                  { value: 'name:desc', label: 'Name, Z to A' },
                  { value: 'account:asc', label: 'App account, needs attention first' },
                  { value: 'account:desc', label: 'App account, signed up first' },
                ]} />
            </div>
            <ul className="space-y-3 sm:hidden" aria-label="Employees">
              {rows.map((row) => (
                <li key={row.id}>
                  <MobileRecordCard>
                    <Link className="text-base font-semibold text-primary-800 underline underline-offset-2 [overflow-wrap:anywhere]" to={recordPath(row.id)}>{row.name}</Link>
                    {(row.department || row.role) && <p className="mt-1 text-sm text-neutral-600">{[row.department?.name, row.role].filter(Boolean).join(' · ')}</p>}
                    <div className="mt-3 grid grid-cols-2 gap-3">
                      <MobileField label="App account" value={<AccountCell account={row.account} showLastOpened />} className="col-span-2" />
                      <MobileField label="Terms" value={<TermsFact terms={row.terms} />} className="col-span-2" />
                      <MobileField label="Pay stubs" value={<AnswerCell fact={row.pay_statements} />} />
                      <MobileField label="W-2GU" value={<AnswerCell fact={row.w2gu} />} />
                    </div>
                  </MobileRecordCard>
                </li>
              ))}
            </ul>
            <Card className="hidden sm:block">
              <Table stickyHeader containerClassName="max-h-[40rem]">
                <TableHeader>
                  <TableRow>
                    <SortHead label="Employee" column="name" sort={sort} onToggle={toggleSort} />
                    <SortHead label="App account" column="account" sort={sort} onToggle={toggleSort} />
                    <TableHead>Terms</TableHead>
                    <TableHead>Pay stubs</TableHead>
                    <TableHead>W-2GU</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((row) => (
                    <TableRow key={row.id}>
                      <TableCell>
                        <div className="w-48 whitespace-normal [overflow-wrap:anywhere]">
                          <Link className="font-semibold text-primary-800 underline underline-offset-2" to={recordPath(row.id)}>{row.name}</Link>
                          {(row.department || row.role) && <p className="text-xs text-neutral-600">{[row.department?.name, row.role].filter(Boolean).join(' · ')}</p>}
                        </div>
                      </TableCell>
                      <TableCell className="whitespace-normal"><AccountCell account={row.account} showLastOpened /></TableCell>
                      <TableCell><TermsFact terms={row.terms} /></TableCell>
                      <TableCell><AnswerCell fact={row.pay_statements} /></TableCell>
                      <TableCell><AnswerCell fact={row.w2gu} /></TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </Card>
          </>}
        </>}
      </div>
    </div>
  );
}

function FilterChip({ label, count, pressed, onClick }: { label: string; count: number; pressed: boolean; onClick: () => void }) {
  return (
    <button type="button" aria-pressed={pressed} onClick={onClick}
      className={`inline-flex min-h-11 items-center gap-2 rounded-full border px-4 text-sm font-semibold transition-colors ${pressed
        ? 'border-primary-700 bg-primary-700 text-white'
        : 'border-neutral-300 bg-white text-neutral-800 hover:border-primary-300'}`}>
      {label}{' '}
      <span className={`tabular-nums ${pressed ? 'text-white' : 'text-neutral-600'}`}>{count}</span>
    </button>
  );
}

function SortHead({ label, column, sort, onToggle }: {
  label: string;
  column: SortKey;
  sort: { key: SortKey; direction: 'asc' | 'desc' };
  onToggle: (column: SortKey) => void;
}) {
  const active = sort.key === column;
  const Icon = !active ? ArrowUpDown : sort.direction === 'asc' ? ArrowUp : ArrowDown;
  return (
    <TableHead aria-sort={active ? (sort.direction === 'asc' ? 'ascending' : 'descending') : 'none'} className="bg-gray-50">
      <button type="button" onClick={() => onToggle(column)}
        className="inline-flex min-h-11 items-center gap-1.5 rounded text-left text-xs font-medium text-neutral-600 hover:text-neutral-900">
        {label}
        <Icon aria-hidden="true" className="size-3.5" />
      </button>
    </TableHead>
  );
}

const ACCOUNT_ORDER = ['not_invited', 'invite_expired', 'locked', 'reinvited', 'invited', 'revoked', 'deactivated', 'former', 'active'];

function sortRows(rows: AppStatusRow[], key: SortKey, direction: 'asc' | 'desc'): AppStatusRow[] {
  const value = (row: AppStatusRow): string | number => {
    switch (key) {
      case 'account': return ACCOUNT_ORDER.indexOf(row.account.status);
      default: return row.name.toLowerCase();
    }
  };
  const sign = direction === 'asc' ? 1 : -1;
  // Array#sort is stable, so ties keep the API's name order.
  return [...rows].sort((a, b) => {
    const left = value(a);
    const right = value(b);
    return left < right ? -sign : left > right ? sign : 0;
  });
}
