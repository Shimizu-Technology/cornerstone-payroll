import { Fragment, useEffect, useMemo, useState } from 'react';
import { ChevronDown, ChevronRight, Download } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { saveBlob } from '@/lib/save-blob';
import { cn } from '@/lib/utils';
import {
  clientProfitabilityApi,
  type ProfitabilityLine,
  type ProfitabilityPerson,
  type ProfitabilityReport,
  type CostBasis,
  type ReportPeriodMode,
  type ReportQuery,
} from '@/services/clientProfitability';
import { defaultPeriod, hours, isNegative, isZero, money, monthLabel, percent, recentMonths, recentQuarters } from './format';
import { SelectField } from './SelectField';

type Mode = ReportPeriodMode;

function PeriodPicker({ value, initialMode, onChange }: {
  value: { from: string; through: string };
  initialMode: Mode;
  onChange: (next: { from: string; through: string }) => void;
}) {
  const months = useMemo(() => recentMonths(new Date()), []);
  const quarters = useMemo(() => recentQuarters(new Date()), []);
  const [mode, setMode] = useState<Mode>(initialMode);

  function choose(next: Mode) {
    setMode(next);
    if (next === 'month') onChange({ from: value.through, through: value.through });
    if (next === 'quarter') {
      const quarter = quarters.find((entry) => entry.from <= value.through && value.through <= entry.through) ?? quarters[0];
      onChange({ from: quarter.from, through: quarter.through });
    }
  }

  return (
    <div className="space-y-3">
      <div role="radiogroup" aria-label="Period type" className="inline-flex rounded-full border border-neutral-200 bg-white p-1">
        {(['month', 'quarter', 'custom'] as Mode[]).map((option) => (
          <button key={option} type="button" role="radio" aria-checked={mode === option} onClick={() => choose(option)}
            className={cn('min-h-11 rounded-full px-4 text-sm font-semibold', mode === option ? 'bg-primary-700 text-white' : 'text-neutral-700 hover:bg-neutral-100')}>
            {option === 'month' ? 'Month' : option === 'quarter' ? 'Quarter' : 'Custom'}
          </button>
        ))}
      </div>
      {mode === 'month' && (
        <SelectField wrapperClassName="max-w-xs" label="Month" value={value.from} onChange={(event) => onChange({ from: event.target.value, through: event.target.value })}>
          {months.map((month) => <option key={month} value={month}>{monthLabel(month)}</option>)}
        </SelectField>
      )}
      {mode === 'quarter' && (
        <SelectField wrapperClassName="max-w-xs" label="Quarter" value={`${value.from}|${value.through}`}
          onChange={(event) => { const [from, through] = event.target.value.split('|'); onChange({ from, through }); }}>
          {quarters.map((quarter) => <option key={quarter.key} value={`${quarter.from}|${quarter.through}`}>{quarter.label}</option>)}
        </SelectField>
      )}
      {mode === 'custom' && (
        <div className="grid max-w-xl gap-3 sm:grid-cols-2">
          <SelectField label="From month" value={value.from}
            onChange={(event) => onChange({ from: event.target.value, through: event.target.value > value.through ? event.target.value : value.through })}>
            {months.map((month) => <option key={month} value={month}>{monthLabel(month)}</option>)}
          </SelectField>
          <SelectField label="Through month" value={value.through}
            onChange={(event) => onChange({ from: event.target.value < value.from ? event.target.value : value.from, through: event.target.value })}>
            {months.map((month) => <option key={month} value={month}>{monthLabel(month)}</option>)}
          </SelectField>
        </div>
      )}
    </div>
  );
}

function Toggle({ checked, onChange, label, help }: { checked: boolean; onChange: (value: boolean) => void; label: string; help: string }) {
  return (
    <label className="flex min-h-11 cursor-pointer items-start gap-3 rounded-xl border border-neutral-200 bg-white p-3">
      <input type="checkbox" className="mt-0.5 h-5 w-5 shrink-0 rounded border-neutral-300" checked={checked} onChange={(event) => onChange(event.target.checked)} />
      <span>
        <span className="block text-sm font-semibold text-neutral-900">{label}</span>
        <span className="block text-xs leading-5 text-neutral-600">{help}</span>
      </span>
    </label>
  );
}

function Metric({ label, value, detail, negative }: { label: string; value: string; detail?: string; negative?: boolean }) {
  return (
    <div className="rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm">
      <p className="text-sm font-medium text-neutral-600">{label}</p>
      <p className={cn('mt-1 text-2xl font-semibold tabular-nums', negative ? 'text-red-800' : 'text-neutral-950')}>{value}</p>
      {detail && <p className="mt-1 text-xs leading-5 text-neutral-600">{detail}</p>}
    </div>
  );
}

function PersonDetail({ person }: { person: ProfitabilityPerson }) {
  return (
    <div className="rounded-xl border border-neutral-200 bg-white p-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="font-semibold text-neutral-900">{person.name}{!person.linked && <span className="ml-2 text-xs font-normal text-amber-800">not linked to an employee</span>}</p>
        <p className="text-sm tabular-nums text-neutral-700">
          {hours(person.hours)} hrs{!isZero(person.pending_hours) && ` · ${hours(person.pending_hours)} pending`} · {money(person.cost)}
        </p>
      </div>
      <ul className="mt-2 space-y-1 text-sm text-neutral-700">
        {person.categories.map((category) => (
          <li key={`${category.category}|${category.task ?? ''}`} className="flex justify-between gap-3">
            <span>{category.category}{category.task ? ` · ${category.task}` : ''}</span>
            <span className="shrink-0 tabular-nums">{hours(category.hours)} hrs{!isZero(category.pending_hours) && ` (+${hours(category.pending_hours)} pending)`}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function People({ line }: { line: ProfitabilityLine }) {
  if (line.people.length === 0) return <p className="text-sm text-neutral-600">No hours logged for this client in this period.</p>;
  return (
    <div className="space-y-2">
      {!isZero(line.overhead_cost) && <p className="text-sm text-neutral-700">Includes {money(line.overhead_cost)} share of internal / overhead time.</p>}
      {line.people.map((person) => <PersonDetail key={person.tax_user_id} person={person} />)}
    </div>
  );
}

const COLUMNS = ['Hours', 'Pending', 'Cost', 'Fees', 'Tax prep', 'Margin', 'Margin %', 'Fees per hour'];

function DesktopTable({ lines, caption, expanded, onToggle, dimmed }: {
  lines: ProfitabilityLine[]; caption: string; expanded: Set<string>; onToggle: (key: string) => void; dimmed?: boolean;
}) {
  return (
    <div className="hidden overflow-x-auto rounded-2xl border border-neutral-200 bg-white shadow-sm md:block">
      <table className="w-full text-sm">
        <caption className="sr-only">{caption}</caption>
        <thead className="bg-neutral-50 text-left text-xs font-semibold text-neutral-600">
          <tr>
            <th scope="col" className="px-4 py-3">Client</th>
            {COLUMNS.map((column) => <th key={column} scope="col" className="px-3 py-3 text-right">{column}</th>)}
          </tr>
        </thead>
        <tbody className="divide-y divide-neutral-100">
          {lines.map((line) => {
            const open = expanded.has(line.key);
            return (
              <Fragment key={line.key}>
                <tr className={cn(dimmed && 'text-neutral-600')}>
                  <th scope="row" className="px-2 py-1 text-left font-medium">
                    <button type="button" onClick={() => onToggle(line.key)} aria-expanded={open}
                      className="flex min-h-11 w-full items-center gap-2 rounded-lg px-2 text-left text-neutral-900 hover:bg-neutral-50">
                      {open ? <ChevronDown className="h-4 w-4 shrink-0" aria-hidden="true" /> : <ChevronRight className="h-4 w-4 shrink-0" aria-hidden="true" />}
                      <span>{line.name}{line.kind === 'recipient' && <span className="ml-2 text-xs font-normal text-neutral-600">Invoice customer</span>}</span>
                    </button>
                  </th>
                  <td className="px-3 text-right tabular-nums">{hours(line.hours)}</td>
                  <td className="px-3 text-right tabular-nums">{isZero(line.pending_hours) ? '—' : hours(line.pending_hours)}</td>
                  <td className="px-3 text-right tabular-nums">{money(line.cost)}</td>
                  <td className="px-3 text-right tabular-nums">{money(line.fees)}</td>
                  <td className="px-3 text-right tabular-nums">{isZero(line.tax_prep_fees) ? '—' : money(line.tax_prep_fees)}</td>
                  <td className={cn('px-3 text-right font-semibold tabular-nums', isNegative(line.margin) && 'text-red-800')}>{money(line.margin)}</td>
                  <td className={cn('px-3 text-right tabular-nums', isNegative(line.margin_percent) && 'text-red-800')}>{percent(line.margin_percent)}</td>
                  <td className="px-3 text-right tabular-nums">{money(line.effective_rate)}</td>
                </tr>
                {open && (
                  <tr className="bg-neutral-50/70">
                    <td colSpan={COLUMNS.length + 1} className="px-4 py-3"><People line={line} /></td>
                  </tr>
                )}
              </Fragment>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function MobileCards({ lines, expanded, onToggle }: { lines: ProfitabilityLine[]; expanded: Set<string>; onToggle: (key: string) => void }) {
  return (
    <ul className="space-y-3 md:hidden">
      {lines.map((line) => {
        const open = expanded.has(line.key);
        return (
          <li key={line.key} className="rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm">
            <div className="flex items-start justify-between gap-3">
              <h3 className="text-base font-semibold text-neutral-950">
                {line.name}
                {line.kind === 'recipient' && <span className="block text-xs font-normal text-neutral-600">Invoice customer (no payroll)</span>}
              </h3>
              <p className={cn('shrink-0 text-base font-semibold tabular-nums', isNegative(line.margin) && 'text-red-800')}>{money(line.margin)}</p>
            </div>
            <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
              <div><dt className="text-neutral-600">Fees</dt><dd className="tabular-nums text-neutral-900">{money(line.fees)}</dd></div>
              <div><dt className="text-neutral-600">Cost</dt><dd className="tabular-nums text-neutral-900">{money(line.cost)}</dd></div>
              <div><dt className="text-neutral-600">Hours</dt><dd className="tabular-nums text-neutral-900">{hours(line.hours)}{!isZero(line.pending_hours) && ` (+${hours(line.pending_hours)} pending)`}</dd></div>
              <div><dt className="text-neutral-600">Margin %</dt><dd className="tabular-nums text-neutral-900">{percent(line.margin_percent)}</dd></div>
              <div><dt className="text-neutral-600">Tax prep fees</dt><dd className="tabular-nums text-neutral-900">{isZero(line.tax_prep_fees) ? '—' : money(line.tax_prep_fees)}</dd></div>
              <div><dt className="text-neutral-600">Fees per hour</dt><dd className="tabular-nums text-neutral-900">{money(line.effective_rate)}</dd></div>
            </dl>
            <Button variant="outline" onClick={() => onToggle(line.key)} aria-expanded={open} className="mt-3 w-full min-h-11">
              {open ? 'Hide people' : 'Show people and tasks'}
            </Button>
            {open && <div className="mt-3"><People line={line} /></div>}
          </li>
        );
      })}
    </ul>
  );
}

function LineGroup(props: { lines: ProfitabilityLine[]; caption: string; expanded: Set<string>; onToggle: (key: string) => void; dimmed?: boolean }) {
  return <><DesktopTable {...props} /><MobileCards {...props} /></>;
}

const REASONS: Record<string, string> = {
  not_linked: 'Not linked to anyone in Tax, so their pay can’t be matched to hours.',
  no_hours: 'No hours logged in Tax for this period.',
  unlinked_adjustments: 'Corrections to imported paychecks whose employee isn’t linked.',
};

function HowCalculated({ report }: { report: ProfitabilityReport }) {
  return (
    <details className="rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm sm:p-6">
      <summary className="flex min-h-11 cursor-pointer items-center text-base font-semibold text-neutral-950">How this is calculated</summary>
      <div className="mt-3 space-y-3 text-sm leading-6 text-neutral-700">
        <p><strong>Fees</strong> are issued invoices (not drafts or voids) linked to each client, by service month, without reimbursements. Discounts are spread across the lines. Payments and credits don’t change them.</p>
        {report.cost_basis.basis === 'work_period' ? (
          <p><strong>Cost</strong> counts pay by <strong>work period</strong> (Setup → Count pay by): each paycheck{report.practice_company ? ` from ${report.practice_company.name}` : ''} is spread evenly over the days of its pay period, and only the days in these months count. A check paid December 2 for November 16–30 counts in November. It includes gross pay, non-taxable pay, the employer’s Social Security and Medicare, employer contributions such as retirement match, and imported QuickBooks paychecks. That’s why it can differ from the Annual Payroll Summary, which counts each paycheck in the month it was paid. Each person’s share is split across the clients they logged hours to in Cornerstone Tax, in proportion to their approved hours. Imported paychecks that aren’t linked to an employee are left out of the totals and listed on their own.</p>
        ) : (
          <p><strong>Cost</strong> counts pay by <strong>pay date</strong>, the same “total payroll cost” the Annual Payroll Summary shows for{report.practice_company ? ` ${report.practice_company.name}` : ' the staff payroll client'} and these pay dates: gross pay, non-taxable pay, the employer’s Social Security and Medicare, and employer contributions such as retirement match, including imported QuickBooks paychecks. Each person’s share is split across the clients they logged hours to in Cornerstone Tax, in proportion to their approved hours. Imported paychecks that aren’t linked to an employee are left out of the totals, as in that summary, and listed on their own. To count pay in the months the work was done instead, change Setup → Count pay by.</p>
        )}
        <p><strong>Pending hours</strong> (not yet approved in Tax) are shown but only get cost when “Count pending hours” is on. <strong>Internal / overhead</strong> is time on Cornerstone’s own work; it gets its share of cost and stays on its own line unless you spread it across clients by hours.</p>
        <p><strong>Margin</strong> is fees minus cost. <strong>Fees per hour</strong> is fees divided by hours, so time on a client with no fees shows $0.00.{' '}
          {report.cost_basis.basis === 'work_period'
            ? 'Pay and hours are both matched by the days worked, so each month carries the pay for its own work, even when the paycheck came later.'
            : 'Pay is matched by pay date and hours by work date, so a month can look uneven when a paycheck covers work from the month before; quarters smooth that out.'}
        </p>
      </div>
      {report.staff.length > 0 && (
        <div className="mt-4 overflow-x-auto">
          <table className="w-full min-w-[560px] text-sm">
            <caption className="mb-2 text-left text-sm font-semibold text-neutral-900">Each person’s cost this period</caption>
            <thead className="text-left text-xs font-semibold text-neutral-600">
              <tr><th scope="col" className="py-2 pr-3">Person</th><th scope="col" className="px-3 text-right">Pay</th><th scope="col" className="px-3 text-right">Employer taxes</th><th scope="col" className="px-3 text-right">Benefits</th><th scope="col" className="px-3 text-right">Total cost</th><th scope="col" className="px-3 text-right">Hours</th><th scope="col" className="pl-3 text-right">Cost per hour</th></tr>
            </thead>
            <tbody className="divide-y divide-neutral-100">
              {report.staff.map((person) => (
                <tr key={person.key}>
                  <th scope="row" className="py-2 pr-3 text-left font-medium text-neutral-900">{person.name}
                    {person.status !== 'employee' && <span className="block text-xs font-normal text-neutral-600">{person.status === 'no_payroll' ? 'Not on payroll' : 'Not linked yet'}</span>}
                  </th>
                  <td className="px-3 text-right tabular-nums">{money(person.pay)}</td>
                  <td className="px-3 text-right tabular-nums">{money(person.employer_taxes)}</td>
                  <td className="px-3 text-right tabular-nums">{money(person.employer_contributions)}</td>
                  <td className="px-3 text-right tabular-nums">{money(person.cost)}</td>
                  <td className="px-3 text-right tabular-nums">{hours(person.hours)}</td>
                  <td className="pl-3 text-right tabular-nums">{money(person.cost_per_hour)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </details>
  );
}

export interface ReportDefaults {
  costPending: boolean;
  spreadOverhead: boolean;
  period: ReportPeriodMode;
  /** "Count pay by" from Setup; the report and its CSV both use it. */
  costBasis: CostBasis;
}

const BUILT_IN_DEFAULTS: ReportDefaults = { costPending: false, spreadOverhead: false, period: 'month', costBasis: 'pay_date' };

export function ReportView({ reloadKey, onGoTo, defaults = BUILT_IN_DEFAULTS }: {
  reloadKey: number;
  onGoTo: (tab: 'link' | 'setup') => void;
  /** The organization's saved starting point (Setup → Report defaults). */
  defaults?: ReportDefaults;
}) {
  const [period, setPeriod] = useState(() => defaultPeriod(defaults.period));
  const [costPending, setCostPending] = useState(defaults.costPending);
  const [spreadOverhead, setSpreadOverhead] = useState(defaults.spreadOverhead);
  // Fixed for as long as this report is open, like the other defaults: a
  // basis saved meanwhile (e.g. by another admin) applies the next time it opens.
  const [costBasis] = useState(defaults.costBasis);
  // The report on screen and the exact options that produced it: labels and
  // the CSV always describe what is shown, not options still loading.
  const [shown, setShown] = useState<{ report: ProfitabilityReport; query: ReportQuery } | null>(null);
  const report = shown?.report ?? null;
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [downloading, setDownloading] = useState(false);
  const query: ReportQuery = useMemo(() => ({ ...period, cost_pending: costPending, spread_overhead: spreadOverhead, cost_basis: costBasis }),
    [period, costPending, spreadOverhead, costBasis]);

  useEffect(() => {
    let current = true;
    setLoading(true);
    setError(null);
    void clientProfitabilityApi.report(query).then((data) => { if (current) setShown({ report: data, query }); })
      .catch((loadError: unknown) => {
        if (!current) return;
        setShown(null);
        setError(loadError instanceof Error ? loadError.message : 'Couldn’t load the report.');
      })
      .finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [query, reloadKey]);

  function toggle(key: string) {
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key); else next.add(key);
      return next;
    });
  }

  async function download() {
    if (!shown) return;
    setDownloading(true);
    try {
      const { blob, filename } = await clientProfitabilityApi.exportCsv(shown.query);
      saveBlob(blob, filename || `client-profitability-${shown.query.from}.csv`);
    } catch (downloadError) {
      setError(downloadError instanceof Error ? downloadError.message : 'Couldn’t download the CSV.');
    } finally {
      setDownloading(false);
    }
  }

  const otherLines = report ? [...(report.overhead ? [report.overhead] : []), ...report.unassigned] : [];
  const notLinked = report?.unassigned.filter((line) => line.kind === 'unlinked_client').length ?? 0;
  const staffNotLinked = report?.staff.filter((person) => person.status === 'not_linked').length ?? 0;

  return (
    <div className="space-y-6">
      <section aria-label="Report options" className="space-y-4 rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm sm:p-6">
        <PeriodPicker value={period} initialMode={defaults.period} onChange={setPeriod} />
        <div className="grid gap-3 lg:grid-cols-2">
          <Toggle checked={costPending} onChange={setCostPending} label="Count pending hours in cost"
            help="Hours still waiting for approval in Tax also get a share of staff pay." />
          <Toggle checked={spreadOverhead} onChange={setSpreadOverhead} label="Spread internal / overhead time across clients"
            help="Moves the cost of Cornerstone’s own time onto clients, in proportion to their hours." />
        </div>
        <Button variant="outline" onClick={() => void download()} loading={downloading} disabled={!shown || loading} className="min-h-11 sm:min-h-11">
          <Download className="mr-2 h-4 w-4" aria-hidden="true" />Download CSV
        </Button>
      </section>

      {error && <p role="alert" className="rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-900">{error}</p>}
      {loading && !report && <p role="status" className="text-sm text-neutral-600">Loading the report…</p>}

      {report && (
        <div className={cn('space-y-6', loading && 'opacity-60')} aria-busy={loading || undefined}>
          <h2 className="text-xl font-semibold text-neutral-950">{report.period.label}</h2>

          <div className="space-y-2">
            {!report.practice_company && (
              <p className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">
                Staff cost is $0 because the client that runs Cornerstone’s staff payroll isn’t chosen. <button type="button" className="min-h-11 font-semibold underline" onClick={() => onGoTo('setup')}>Open Setup</button>
              </p>
            )}
            {report.coverage.missing_month_labels.length > 0 && (
              <p className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">
                Hours for {report.coverage.missing_month_labels.join(', ')} haven’t been pulled from Tax yet. <button type="button" className="min-h-11 font-semibold underline" onClick={() => onGoTo('setup')}>Refresh hours</button>
              </p>
            )}
            {(notLinked > 0 || staffNotLinked > 0) && (
              <p className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">
                {notLinked > 0 && `${notLinked} Tax client${notLinked === 1 ? '' : 's'} `}{notLinked > 0 && staffNotLinked > 0 && 'and '}
                {staffNotLinked > 0 && `${staffNotLinked} staff member${staffNotLinked === 1 ? '' : 's'} `}
                aren’t linked yet, so some hours or pay aren’t counted against a client. <button type="button" className="min-h-11 font-semibold underline" onClick={() => onGoTo('link')}>Link them</button>
              </p>
            )}
            {report.cost_basis.basis === 'work_period' && (
              <p className="rounded-xl border border-neutral-200 bg-white p-3 text-sm text-neutral-700">
                Pay is counted by work period: {money(report.cost_basis.cost)}. The Annual Payroll Summary counts {money(report.cost_basis.annual_payroll_summary_cost)} for paychecks paid in these months
                {isZero(report.cost_basis.difference)
                  ? ', the same amount.'
                  : `, ${money(report.cost_basis.difference.replace('-', ''))} ${isNegative(report.cost_basis.difference) ? 'more' : 'less'}. The difference is pay for work done in one range but paid in another.`}
              </p>
            )}
            {!isZero(report.coverage.pending_hours) && (
              <p className="rounded-xl border border-neutral-200 bg-white p-3 text-sm text-neutral-700">
                {hours(report.coverage.pending_hours)} hours are still waiting for approval in Tax{report.options.cost_pending ? ' and are included in cost.' : ' and aren’t costed.'}
              </p>
            )}
          </div>

          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <Metric label="Fees" value={money(report.totals.fees)} detail={`${money(report.totals.tax_prep_fees)} tax prep · ${money(report.totals.other_fees)} other`} />
            <Metric label="Staff cost" value={money(report.totals.cost)} detail="Pay, employer taxes and benefits" />
            <Metric label="Margin" value={money(report.totals.margin)} detail={`${percent(report.totals.margin_percent)} of fees`} negative={isNegative(report.totals.margin)} />
            <Metric label="Hours" value={hours(report.totals.hours)} detail={`${money(report.totals.effective_rate)} fees per hour`} />
          </div>

          <section aria-labelledby="clients-heading" className="space-y-3">
            <h2 id="clients-heading" className="text-lg font-semibold text-neutral-950">Clients</h2>
            {report.clients.length === 0
              ? <p className="rounded-2xl border border-neutral-200 bg-white p-6 text-sm text-neutral-600">No client has hours or fees in this period yet.</p>
              : <LineGroup lines={report.clients} caption="Profit by client" expanded={expanded} onToggle={toggle} />}
          </section>

          {(otherLines.length > 0 || report.unallocated_costs.length > 0 || !isZero(report.unlinked_fees.fees) || report.imported_pay_not_linked.paycheck_count > 0) && (
            <section aria-labelledby="other-heading" className="space-y-3">
              <h2 id="other-heading" className="text-lg font-semibold text-neutral-950">Not tied to a client</h2>
              {report.overhead?.spread && <p className="text-sm text-neutral-700">Internal / overhead cost is spread across the clients above; it’s listed here for reference and counted once in the totals.</p>}
              {otherLines.length > 0 && <LineGroup lines={otherLines} caption="Internal, unassigned and unlinked hours" expanded={expanded} onToggle={toggle} dimmed />}
              {report.unallocated_costs.length > 0 && (
                <ul className="space-y-2">
                  {report.unallocated_costs.map((entry) => (
                    <li key={`${entry.employee_id ?? 'unlinked'}-${entry.reason}`} className="flex flex-wrap items-baseline justify-between gap-2 rounded-xl border border-neutral-200 bg-white p-3 text-sm">
                      <span><strong className="text-neutral-900">{entry.name}</strong><span className="block text-neutral-600">{REASONS[entry.reason]}</span></span>
                      <span className="tabular-nums text-neutral-900">{money(entry.cost)} pay not matched to hours</span>
                    </li>
                  ))}
                </ul>
              )}
              {report.imported_pay_not_linked.paycheck_count > 0 && (
                <div className="flex flex-wrap items-baseline justify-between gap-2 rounded-xl border border-dashed border-neutral-300 bg-white p-3 text-sm">
                  <span>
                    <strong className="text-neutral-900">Imported pay not linked to an employee</strong>
                    <span className="block text-neutral-600">
                      {report.imported_pay_not_linked.paycheck_count} imported paycheck{report.imported_pay_not_linked.paycheck_count === 1 ? '' : 's'}. Not in the totals or any client, matching the Annual Payroll Summary. Link the worker in Data Migration to count it.
                    </span>
                  </span>
                  <span className="tabular-nums text-neutral-900">{money(report.imported_pay_not_linked.cost)}</span>
                </div>
              )}
              {!isZero(report.unlinked_fees.fees) && (
                <p className="rounded-xl border border-neutral-200 bg-white p-3 text-sm text-neutral-800">
                  {money(report.unlinked_fees.fees)} in fees are on invoices that aren’t linked to a payroll client. Link the client on the invoice in Invoice Center to count them.
                </p>
              )}
            </section>
          )}

          <HowCalculated report={report} />
        </div>
      )}
    </div>
  );
}
