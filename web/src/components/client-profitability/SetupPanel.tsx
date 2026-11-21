import { useMemo, useState } from 'react';
import { CheckCircle2, CircleAlert, Clock3, RefreshCw } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  clientProfitabilityApi,
  type CostBasis,
  type ProfitabilityOverview,
  type ReportPeriodMode,
  type WorkHourImportStatus,
} from '@/services/clientProfitability';
import { formatDate, formatDateTime, hours, monthLabel, recentMonths } from './format';
import { SelectField } from './SelectField';

export function ConnectionSteps({ overview }: { overview: ProfitabilityOverview }) {
  const { connection } = overview;
  return (
    <section aria-labelledby="connect-heading" className="rounded-2xl border border-amber-200 bg-amber-50 p-4 sm:p-6">
      <h2 id="connect-heading" className="flex items-center gap-2 text-lg font-semibold text-amber-950">
        <CircleAlert className="h-5 w-5 shrink-0" aria-hidden="true" />
        Cornerstone Tax isn’t connected yet
      </h2>
      <p className="mt-2 text-sm leading-6 text-amber-950">
        This report reads staff hours from Cornerstone Tax. Nothing is pulled until Leon finishes these steps on the servers:
      </p>
      <ol className="mt-3 list-decimal space-y-2 pl-5 text-sm leading-6 text-amber-950">
        <li>Make one long random secret and set it as <code className="rounded bg-white px-1">PAYROLL_WORK_HOURS_SECRET</code> on <strong>both</strong> the Tax and Payroll servers.</li>
        <li>On Payroll, set <code className="rounded bg-white px-1">CORNERSTONE_TAX_API_URL</code> to Tax’s web address (it must start with https://).</li>
        <li>Below, choose the client in Payroll that runs Cornerstone’s own staff payroll.</li>
        <li>Refresh hours from Tax, then link Tax clients and staff to Payroll.</li>
      </ol>
      {connection.missing.length > 0 && (
        <p className="mt-3 text-sm text-amber-950">Still missing: {connection.missing.join(', ')}</p>
      )}
      {connection.problem && <p className="mt-1 text-sm text-amber-950">{connection.problem}</p>}
    </section>
  );
}

function ImportRow({ entry }: { entry: WorkHourImportStatus }) {
  const icon = entry.status === 'succeeded'
    ? <CheckCircle2 className="h-4 w-4 text-emerald-700" aria-hidden="true" />
    : entry.status === 'failed' ? <CircleAlert className="h-4 w-4 text-red-700" aria-hidden="true" />
      : <Clock3 className="h-4 w-4 text-neutral-600" aria-hidden="true" />;
  const label = { succeeded: 'Done', failed: 'Didn’t finish', queued: 'Waiting to start', running: 'Pulling hours…' }[entry.status];
  return (
    <li className="rounded-xl border border-neutral-200 bg-white p-3 text-sm">
      <div className="flex flex-wrap items-center gap-2 font-medium text-neutral-900">
        {icon}<span>{label}</span>
        <span className="text-neutral-600">· {formatDate(entry.range_start)} – {formatDate(entry.range_end)}</span>
      </div>
      <p className="mt-1 text-neutral-600">
        {entry.trigger === 'scheduled' ? 'Nightly refresh' : `Asked by ${entry.requested_by ?? 'an admin'}`} · {formatDateTime(entry.finished_at ?? entry.created_at)}
        {entry.status === 'succeeded' && ` · ${hours(entry.total_hours)} hours in ${entry.row_count} rows`}
        {entry.status === 'succeeded' && entry.pending_entries > 0 && ` · ${entry.pending_entries} entries still waiting for approval in Tax`}
        {entry.status === 'succeeded' && entry.open_clock_entries > 0 && ` · ${entry.open_clock_entries} clocks still open`}
      </p>
      {entry.error_message && <p className="mt-1 text-red-800">{entry.error_message}</p>}
    </li>
  );
}

interface SetupPanelProps {
  overview: ProfitabilityOverview;
  onChanged: (overview?: ProfitabilityOverview) => void;
  /** The refresh the page is watching (it keeps watching on other tabs). */
  activeImport: WorkHourImportStatus | null;
  monitorError: string | null;
  onStarted: (started: WorkHourImportStatus) => void;
}

export function SetupPanel({ overview, onChanged, activeImport, monitorError, onStarted }: SetupPanelProps) {
  const months = useMemo(() => recentMonths(new Date()), []);
  const [practiceCompanyId, setPracticeCompanyId] = useState(String(overview.settings.practice_company_id ?? ''));
  const [financeBookId, setFinanceBookId] = useState(String(overview.settings.finance_book_id ?? ''));
  const [taxPrep, setTaxPrep] = useState<string[]>(overview.settings.tax_prep_service_names);
  const [defaultCostPending, setDefaultCostPending] = useState(overview.settings.default_cost_pending);
  const [defaultSpreadOverhead, setDefaultSpreadOverhead] = useState(overview.settings.default_spread_overhead);
  const [defaultPeriodMode, setDefaultPeriodMode] = useState<ReportPeriodMode>(overview.settings.default_period);
  const [costBasis, setCostBasis] = useState<CostBasis>(overview.settings.cost_basis);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<{ tone: 'error' | 'success'; text: string } | null>(null);
  const [from, setFrom] = useState(months[1]);
  const [through, setThrough] = useState(months[0]);
  const [startError, setStartError] = useState<string | null>(null);
  const refreshing = activeImport;
  const refreshError = startError ?? monitorError;

  const serviceNames = Array.from(new Set([...overview.options.service_names, ...taxPrep]));

  async function save() {
    setSaving(true);
    setMessage(null);
    try {
      const updated = await clientProfitabilityApi.updateSettings({
        practice_company_id: practiceCompanyId ? Number(practiceCompanyId) : null,
        finance_book_id: financeBookId ? Number(financeBookId) : null,
        tax_prep_service_names: taxPrep,
        default_cost_pending: defaultCostPending,
        default_spread_overhead: defaultSpreadOverhead,
        default_period: defaultPeriodMode,
        cost_basis: costBasis,
      });
      setMessage({ tone: 'success', text: 'Settings saved.' });
      onChanged(updated);
    } catch (error) {
      setMessage({ tone: 'error', text: error instanceof Error ? error.message : 'Couldn’t save the settings.' });
    } finally {
      setSaving(false);
    }
  }

  async function refresh() {
    setStartError(null);
    try {
      const { import: started } = await clientProfitabilityApi.refresh(from <= through ? from : through, from <= through ? through : from);
      onStarted(started);
    } catch (error) {
      setStartError(error instanceof Error ? error.message : 'Couldn’t start the refresh.');
    }
  }

  const busy = refreshing !== null && ['queued', 'running'].includes(refreshing.status);
  const imports = refreshing && !overview.imports.some((entry) => entry.id === refreshing.id) ? [refreshing, ...overview.imports] : overview.imports
    .map((entry) => (refreshing && entry.id === refreshing.id ? refreshing : entry));

  return (
    <div className="space-y-6">
      <section aria-labelledby="refresh-heading" className="rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm sm:p-6">
        <h2 id="refresh-heading" className="text-lg font-semibold text-neutral-950">Refresh hours from Tax</h2>
        <p className="mt-1 text-sm leading-6 text-neutral-600">
          Pulls every staff member’s hours for these months and replaces what Payroll had stored for them. Payroll also refreshes last month and this month every night.
        </p>
        <div className="mt-4 grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
          <SelectField label="Refresh from" value={from} onChange={(event) => setFrom(event.target.value)}>
            {months.map((month) => <option key={month} value={month}>{monthLabel(month)}</option>)}
          </SelectField>
          <SelectField label="Refresh through" value={through} onChange={(event) => setThrough(event.target.value)}>
            {months.map((month) => <option key={month} value={month}>{monthLabel(month)}</option>)}
          </SelectField>
          <Button onClick={() => void refresh()} disabled={!overview.connection.connected || busy} loading={busy} className="min-h-11 sm:min-h-11">
            <RefreshCw className="mr-2 h-4 w-4" aria-hidden="true" />Refresh hours from Tax
          </Button>
        </div>
        {!overview.connection.connected && <p className="mt-3 text-sm text-neutral-600">Available once Cornerstone Tax is connected.</p>}
        {refreshError && <p role="alert" className="mt-3 text-sm text-red-800">{refreshError}</p>}
        {busy && <p role="status" className="mt-3 text-sm text-neutral-700">Pulling hours from Cornerstone Tax…</p>}
        {imports.length > 0 && (
          <>
            <h3 className="mt-5 text-sm font-semibold text-neutral-900">Recent refreshes</h3>
            <ul className="mt-2 space-y-2">{imports.map((entry) => <ImportRow key={entry.id} entry={entry} />)}</ul>
          </>
        )}
      </section>

      <section aria-labelledby="settings-heading" className="rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm sm:p-6">
        <h2 id="settings-heading" className="text-lg font-semibold text-neutral-950">Where the numbers come from</h2>
        <div className="mt-4 grid gap-4 lg:grid-cols-2">
          <SelectField label="Client that runs Cornerstone’s own staff payroll" value={practiceCompanyId}
            onChange={(event) => setPracticeCompanyId(event.target.value)} help="Staff cost is the pay and employer taxes from this client’s payroll runs.">
            <option value="">Choose a client…</option>
            {overview.options.companies.map((company) => <option key={company.id} value={company.id}>{company.name}</option>)}
          </SelectField>
          <SelectField label="Financial book with client invoices" value={financeBookId} onChange={(event) => setFinanceBookId(event.target.value)}
            help="Fees come from issued invoices in this book that are linked to a payroll client.">
            <option value="">Use the default book</option>
            {overview.options.finance_books.map((book) => <option key={book.id} value={book.id}>{book.name}</option>)}
          </SelectField>
        </div>
        <fieldset className="mt-5">
          <legend className="text-sm font-medium text-neutral-700">Which services are tax preparation?</legend>
          <p className="mt-1 text-xs leading-5 text-neutral-600">
            Invoice lines whose product/service name matches a ticked service show in the “Tax prep” column. The names come from your saved services and from issued invoices.
          </p>
          {serviceNames.length === 0 ? (
            <p className="mt-2 text-sm text-neutral-600">No service names found yet. Add a saved service such as “Tax Preparation” in Invoice Center.</p>
          ) : (
            <div className="mt-2 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              {serviceNames.map((name) => (
                <label key={name} className="flex min-h-11 items-center gap-3 rounded-xl border border-neutral-200 px-3 text-sm text-neutral-800">
                  <input type="checkbox" className="h-5 w-5 rounded border-neutral-300 text-primary-700"
                    checked={taxPrep.some((selected) => selected.toLowerCase() === name.toLowerCase())}
                    onChange={(event) => setTaxPrep((current) => event.target.checked
                      ? [...current, name]
                      : current.filter((selected) => selected.toLowerCase() !== name.toLowerCase()))} />
                  {name}
                </label>
              ))}
            </div>
          )}
        </fieldset>
        <fieldset className="mt-6">
          <legend className="text-sm font-medium text-neutral-700">Count pay by</legend>
          <p className="mt-1 text-xs leading-5 text-neutral-600">Which month a paycheck’s cost lands in. Hours are always split the same way.</p>
          <div className="mt-2 grid gap-2 lg:grid-cols-2">
            {([
              ['pay_date', 'Pay date', 'The month the paycheck was paid. Matches the Annual Payroll Summary.'],
              ['work_period', 'Work period', 'Spread over the days the paycheck covers: a check paid Dec 2 for Nov 16–30 counts in November.'],
            ] as Array<[CostBasis, string, string]>).map(([value, label, hint]) => (
              <label key={value} className="flex min-h-11 cursor-pointer items-start gap-3 rounded-xl border border-neutral-200 p-3">
                <input type="radio" name="cost-basis" className="mt-0.5 h-5 w-5 shrink-0" value={value} checked={costBasis === value}
                  onChange={() => setCostBasis(value)} />
                <span><span className="block text-sm font-semibold text-neutral-900">{label}</span><span className="block text-xs leading-5 text-neutral-600">{hint}</span></span>
              </label>
            ))}
          </div>
        </fieldset>
        <fieldset className="mt-6">
          <legend className="text-sm font-medium text-neutral-700">Report defaults</legend>
          <p className="mt-1 text-xs leading-5 text-neutral-600">Where the report starts each time it opens. You can still change these on the report for one view.</p>
          <div className="mt-2 grid gap-2 lg:grid-cols-2">
            <label className="flex min-h-11 cursor-pointer items-start gap-3 rounded-xl border border-neutral-200 p-3">
              <input type="checkbox" className="mt-0.5 h-5 w-5 shrink-0 rounded border-neutral-300" checked={defaultCostPending}
                onChange={(event) => setDefaultCostPending(event.target.checked)} />
              <span><span className="block text-sm font-semibold text-neutral-900">Count pending hours in cost</span><span className="block text-xs leading-5 text-neutral-600">Hours still waiting for approval in Tax also get a share of staff pay.</span></span>
            </label>
            <label className="flex min-h-11 cursor-pointer items-start gap-3 rounded-xl border border-neutral-200 p-3">
              <input type="checkbox" className="mt-0.5 h-5 w-5 shrink-0 rounded border-neutral-300" checked={defaultSpreadOverhead}
                onChange={(event) => setDefaultSpreadOverhead(event.target.checked)} />
              <span><span className="block text-sm font-semibold text-neutral-900">Spread internal/overhead time across clients</span><span className="block text-xs leading-5 text-neutral-600">Moves the cost of Cornerstone’s own time onto clients, by their hours.</span></span>
            </label>
            <SelectField wrapperClassName="lg:max-w-xs" label="Default period" value={defaultPeriodMode}
              onChange={(event) => setDefaultPeriodMode(event.target.value as ReportPeriodMode)} help="The report opens on last month, or the quarter that holds it.">
              <option value="month">Month</option>
              <option value="quarter">Quarter</option>
              <option value="custom">Custom months</option>
            </SelectField>
          </div>
        </fieldset>
        <div className="mt-5 flex flex-wrap items-center gap-3">
          <Button onClick={() => void save()} loading={saving} className="min-h-11 sm:min-h-11">Save settings</Button>
          {message && <p role={message.tone === 'error' ? 'alert' : 'status'} className={message.tone === 'error' ? 'text-sm text-red-800' : 'text-sm text-emerald-800'}>{message.text}</p>}
        </div>
      </section>
    </div>
  );
}
