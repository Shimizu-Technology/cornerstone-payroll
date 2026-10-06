import { useEffect, useState, type ReactElement } from 'react';
import { FileCheck2, Pencil } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { annualRetirementLimitsApi, employeesApi } from '@/services/api';
import { formatCurrency, formatGuamDateTime } from '@/lib/utils';
import { retirementErrorMessage } from '@/lib/retirement-error';
import { useAuth } from '@/contexts/AuthContext';
import type { AnnualRetirementLimit, Employee, EmployeeRetirementYearInput, EmployeeRetirementYearInputDraft, HistoricalRetirementReportingGroup, HistoricalRetirementReview, HistoricalRetirementSource } from '@/types';

const blank = (taxYear: number): EmployeeRetirementYearInputDraft => ({
  tax_year: taxYear, prior_year_wage_status: 'unknown', prior_year_fica_wages: null,
  prior_year_wage_source: '', external_traditional_deferrals: 0, external_roth_deferrals: 0,
  eligible_compensation_before_system: 0, employer_additions_before_system: 0,
  non_roth_after_tax_before_system: 0, opening_balances_verified: false, historical_retirement_review: {}, source_reference: '', reason: '',
});

const reportingLabels: Record<HistoricalRetirementReportingGroup, string> = {
  '401k_pre_tax': 'Traditional 401(k)',
  '401k_after_tax': 'Roth 401(k)',
  '401k_non_roth_after_tax': '401(k) non-Roth after-tax',
};
const bucketLabel = (bucket: string): string => bucket === 'pretax_deduction_breakdown' ? 'Pre-tax deductions' : 'After-tax deductions';

function isCurrentReview(review: HistoricalRetirementReview | undefined, source: HistoricalRetirementSource | undefined): boolean {
  const classifications = review?.classifications;
  return Boolean(source && source.classifications.length > 0 && review?.balance_digest === source.balance_digest &&
    classifications?.length === source.classifications.length && source.classifications.every((retained) =>
      classifications.some((entry) => entry.source_bucket === retained.source_bucket && entry.source_label === retained.source_label &&
        entry.amount === retained.amount && Object.hasOwn(reportingLabels, entry.reporting_group))));
}

export function EmployeeRetirementYearPanel({ employee, initialYear }: { employee: Employee; initialYear?: number }): ReactElement {
  const { hasCapability } = useAuth();
  const canManage = hasCapability('manage_client_configuration');
  const [year, setYear] = useState(() => initialYear != null && Number.isInteger(initialYear) && initialYear >= 2000 && initialYear <= 2200 ? initialYear : new Date().getFullYear());
  const [records, setRecords] = useState<EmployeeRetirementYearInput[]>([]);
  const [historicalSources, setHistoricalSources] = useState<HistoricalRetirementSource[]>([]);
  const [reviewingHistorical, setReviewingHistorical] = useState(false);
  const [classifications, setClassifications] = useState<(HistoricalRetirementReportingGroup | '')[]>([]);
  const [historicalConfirmed, setHistoricalConfirmed] = useState(false);
  const [limits, setLimits] = useState<AnnualRetirementLimit[]>([]);
  const [draft, setDraft] = useState(() => blank(year));
  const [editing, setEditing] = useState(false);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    setRecords([]);
    setLimits([]);
    setHistoricalSources([]);
    setEditing(false);
    Promise.all([employeesApi.retirementYearInputs(employee.id), annualRetirementLimitsApi.list()])
      .then(([inputs, annual]) => { if (active) { setRecords(inputs.data); setHistoricalSources(inputs.historical_retirement_sources || []); setLimits(annual.data); } })
      .catch((caught: unknown) => { if (active) setError(caught instanceof Error ? caught.message : 'Could not load retirement evidence.'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [employee.id, reload]);

  const current = records.find((record) => Number(record.tax_year) === year);
  const historicalSource = historicalSources.find((source) => Number(source.tax_year) === year && source.classifications.length > 0);
  const historicalReviewed = isCurrentReview(current?.historical_retirement_review, historicalSource);
  const startHistoricalReview = (): void => {
    setReviewingHistorical(true);
    setClassifications(historicalSource?.classifications.map(() => '') || []);
    setHistoricalConfirmed(false);
  };
  const annual = limits.find((limit) => Number(limit.tax_year) === year);
  const election = [...(employee.retirement_elections || []), ...[employee.current_retirement_election, employee.upcoming_retirement_election].filter((entry) => entry != null)]
    .filter((entry) => entry.effective_on <= `${year}-12-31`).sort((a, b) => b.effective_on.localeCompare(a.effective_on))[0];
  const birthYear = employee.date_of_birth ? Number(employee.date_of_birth.slice(0, 4)) : null;
  const age = birthYear ? year - birthYear : null;
  const wageEvidencePending = !current || current.prior_year_wage_status === 'unknown';
  const rothUnavailable = annual && current?.prior_year_wage_status === 'verified' && Number(current.prior_year_fica_wages) > Number(annual.roth_catch_up_wage_threshold) && !election?.roth_available;
  const catchUp = annual && election?.catch_up_enabled && age != null && age >= 50 && !rothUnavailable
    ? Number(age >= 60 && age <= 63 ? annual.enhanced_catch_up_limit : annual.catch_up_limit) : 0;
  const ceiling = annual ? Number(annual.elective_deferral_limit) + catchUp : null;
  const set = <K extends keyof EmployeeRetirementYearInputDraft>(key: K, value: EmployeeRetirementYearInputDraft[K]): void => setDraft((old) => ({ ...old, [key]: value }));
  const edit = (): void => {
    setDraft(current ? { ...blank(year), ...current, tax_year: year, reason: '', historical_retirement_review: historicalReviewed ? current.historical_retirement_review : {} } : blank(year));
    setReviewingHistorical(false);
    setHistoricalConfirmed(false);
    if (historicalSource && !historicalReviewed) startHistoricalReview();
    setEditing(true);
    setError(null);
    setNotice(null);
  };
  const save = async (): Promise<void> => {
    if (!draft.source_reference.trim() || !draft.reason.trim()) {
      setError('Add the evidence reference and a review note before saving.');
      return;
    }
    if (draft.prior_year_wage_status !== 'unknown' && !draft.prior_year_wage_source.trim()) {
      setError(`Add the source used to verify ${year - 1} employer wages.`);
      return;
    }
    let historicalReview = draft.historical_retirement_review || {};
    if (historicalSource && reviewingHistorical) {
      if (classifications.length !== historicalSource.classifications.length || classifications.some((group) => !group)) {
        setError('Choose the contribution type for every retained historical amount. Labels and current elections do not confirm its type.');
        return;
      }
      if (!historicalConfirmed) {
        setError('Confirm the retained historical contribution classifications against the evidence before saving.');
        return;
      }
      historicalReview = {
        balance_digest: historicalSource.balance_digest,
        classifications: historicalSource.classifications.map((source, index) => ({ ...source, reporting_group: classifications[index] as HistoricalRetirementReportingGroup })),
      };
    }
    try {
      setSaving(true);
      setError(null);
      const result = await employeesApi.createRetirementYearInput(employee.id, { ...draft, historical_retirement_review: historicalReview });
      setRecords((old) => [result.data, ...old]);
      setEditing(false);
      setNotice(`${year} retirement records saved. Recalculate affected draft payroll to use them.`);
    } catch (caught) {
      setError(retirementErrorMessage(caught, 'Could not save retirement evidence.'));
    } finally { setSaving(false); }
  };

  return <Card id="retirement-year-evidence" tabIndex={-1} className="scroll-mt-24">
    <CardHeader className="flex flex-col gap-4 border-b border-neutral-100 sm:flex-row sm:items-start sm:justify-between">
      <div><CardTitle className="flex items-center gap-2"><FileCheck2 className="h-5 w-5 text-primary-700" />2 · Yearly retirement checks</CardTitle>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-neutral-600">Confirm prior-year wages from this employer and any retirement amounts outside saved payroll. These records help payroll apply annual limits and catch-up rules correctly.</p></div>
      <label className="block shrink-0 text-sm font-medium text-neutral-700">Payroll year<NumericInput aria-label="Retirement evidence payroll year" className="mt-2 w-full sm:w-28" min={2000} max={2200} inputMode="numeric" emptyValue={null} disabled={saving} value={year} onValueChange={(value) => {
        if (value != null && Number.isInteger(value) && value >= 2000 && value <= 2200) { setYear(value); setEditing(false); setNotice(null); }
      }} /></label>
    </CardHeader>
    <CardContent className="space-y-5 p-5 sm:p-6">
      {loading ? <p role="status" className="text-sm text-neutral-600">Loading annual evidence…</p> : <>
        {notice && <p role="status" className="rounded-xl bg-success-50 p-4 text-sm text-success-800">{notice}</p>}
        {error && <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-800"><p>{error}</p>{!editing && <Button className="mt-3" variant="outline" onClick={() => setReload((value) => value + 1)}>Retry loading evidence</Button>}</div>}
        {!annual && !error && <p className="rounded-xl bg-warning-50 p-4 text-sm leading-6 text-warning-900">Verified annual limits are missing for {year}. A platform administrator must add them in Tax Configuration before retirement payroll can run.</p>}
        {annual && <div className="grid gap-3 sm:grid-cols-3">
          <Value label="IRS regular employee limit" value={formatCurrency(Number(annual.elective_deferral_limit))} />
          <Value label={wageEvidencePending && catchUp > 0 ? 'Potential catch-up — evidence pending' : 'Permitted age-based catch-up'} value={formatCurrency(catchUp)} />
          <Value label={wageEvidencePending && catchUp > 0 ? 'Potential IRS employee ceiling' : 'IRS employee ceiling'} value={formatCurrency(ceiling || 0)} />
        </div>}
        <p className="text-sm leading-6 text-neutral-600"><a href="#retirement-plan" className="font-semibold text-primary-700 underline underline-offset-2">Review contribution settings</a> to change the amounts deducted each payroll. Saving yearly records does not change those amounts.</p>
        {annual && <p className="text-xs leading-5 text-neutral-500">Age at year end: {age == null ? 'DOB needs verification' : age}. This preview uses {election ? `the election effective ${election.effective_on}` : 'legacy settings'} at year end; each paycheck uses its actual pay-date election. The ceiling combines Traditional and Roth. Plan restrictions, outside contributions, and available compensation may reduce it.</p>}
        {historicalSource && <fieldset disabled={saving} className={`min-w-0 rounded-xl border p-4 ${historicalReviewed ? 'border-neutral-200 bg-neutral-50' : 'border-warning-200 bg-warning-50'}`} aria-label="Retained historical retirement contributions">
          <p className="text-sm font-semibold text-neutral-900">{historicalReviewed ? 'Imported contribution types verified' : 'Confirm imported contribution types'}</p>
          <p className="mt-2 text-sm leading-6 text-neutral-700">Classify the retained retirement totals using the source evidence. This review does not rewrite gross pay, net pay, or taxes already paid. A separate historical tax-bucket or filing review may still be needed.</p>
          <div className="mt-3 space-y-3">{historicalSource.classifications.map((source, index) => <div key={`${source.source_bucket}:${source.source_label}`} className="rounded-lg border border-neutral-200 bg-white p-3">
            <div className="flex flex-wrap items-start justify-between gap-2"><p className="break-words text-sm font-semibold text-neutral-900">{source.source_label}</p><p className="text-sm font-semibold tabular-nums text-neutral-900">{formatCurrency(Number(source.amount))}</p></div>
            <p className="mt-1 text-xs leading-5 text-neutral-600">Original payroll category: {bucketLabel(source.source_bucket)}</p>
            {editing && reviewingHistorical ? <div className="mt-3"><Field label={`Contribution type for ${source.source_label} (${bucketLabel(source.source_bucket)})`}><Select value={classifications[index] || ''} onChange={(event) => {
              const group = event.target.value as HistoricalRetirementReportingGroup | '';
              setClassifications((old) => old.map((value, position) => position === index ? group : value));
              setHistoricalConfirmed(false);
            }}><option value="">Choose a verified contribution type</option>{Object.entries(reportingLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</Select></Field></div>
              : historicalReviewed && <p className="mt-2 text-sm text-neutral-700">Reviewed as: {reportingLabels[current!.historical_retirement_review!.classifications!.find((entry) => entry.source_bucket === source.source_bucket && entry.source_label === source.source_label)!.reporting_group]}</p>}
          </div>)}</div>
          {editing && reviewingHistorical && <label className="mt-4 flex gap-3 text-sm leading-6 text-neutral-700"><input className="mt-1 h-4 w-4 shrink-0 accent-primary-700" type="checkbox" checked={historicalConfirmed} onChange={(event) => setHistoricalConfirmed(event.target.checked)} />I confirmed each retained historical contribution type against the source evidence, including whether after-tax amounts are designated Roth or non-Roth.</label>}
          {editing && historicalReviewed && !reviewingHistorical && <Button className="mt-3" variant="outline" onClick={startHistoricalReview}>Review imported types again</Button>}
          {!editing && !historicalReviewed && !error && canManage && <Button className="mt-3" variant="outline" onClick={edit}>Review yearly records</Button>}
        </fieldset>}
        {!editing ? <>
          <div className={`rounded-xl border p-4 text-sm leading-6 ${current && current.prior_year_wage_status !== 'unknown' ? 'border-success-200 bg-success-50 text-success-900' : 'border-warning-200 bg-warning-50 text-warning-900'}`}>
            <p className="font-semibold">{current?.prior_year_wage_status === 'verified' ? `${year - 1} employer Social Security wages verified: ${formatCurrency(Number(current.prior_year_fica_wages))}` : current?.prior_year_wage_status === 'no_prior_employer_wages' ? `Verified: no covered wages from this employer in ${year - 1}` : `${year - 1} employer wages need verification before catch-up`}</p>
            <p>{current?.prior_year_wage_source || 'Missing history is not treated as zero. Use the sponsoring employer’s wage evidence, including any applicable administrator-directed aggregation.'}</p>
            {annual && current?.prior_year_wage_status === 'verified' && Number(current.prior_year_fica_wages) > Number(annual.roth_catch_up_wage_threshold) && <p className="mt-2 font-semibold">Roth catch-up is required for this employer. Earlier designated Roth deferrals may satisfy the requirement; ordinary pre-tax deferrals remain permitted.</p>}
            {rothUnavailable && <p className="mt-2 font-semibold">Catch-up is unavailable until designated Roth support is verified in the retirement election. The regular employee limit still applies.</p>}
            {annual && <p className="mt-2">For {year}, prior-year covered employer wages above {formatCurrency(Number(annual.roth_catch_up_wage_threshold))} require Roth catch-up treatment.</p>}
          </div>
          {current && <><div className="grid gap-3 sm:grid-cols-2"><Value label="Other-employer Traditional deferrals" value={formatCurrency(Number(current.external_traditional_deferrals))} /><Value label="Other-employer Roth deferrals" value={formatCurrency(Number(current.external_roth_deferrals))} /></div>
            <details className="rounded-xl border border-neutral-200 p-4"><summary className="cursor-pointer text-sm font-semibold text-neutral-700">Additional recorded balances</summary><div className="mt-4 grid gap-3 sm:grid-cols-3"><Value label="Eligible compensation" value={formatCurrency(Number(current.eligible_compensation_before_system))} /><Value label="Employer additions" value={formatCurrency(Number(current.employer_additions_before_system))} /><Value label="Non-Roth after-tax" value={formatCurrency(Number(current.non_roth_after_tax_before_system))} /></div><p className="mt-3 text-sm text-neutral-600">Opening balance verification: {current.opening_balances_verified ? 'Confirmed' : 'Not recorded'}.</p></details>
            <p className="break-words text-sm leading-6 text-neutral-600">Evidence: {current.source_reference}<br />Review note: {current.reason}{current.created_at && <><br />Recorded {formatGuamDateTime(current.created_at)}{current.created_by_name ? ` by ${current.created_by_name}` : ''}</>}</p></>}
          {!error && canManage && (!historicalSource || historicalReviewed) && <Button variant="outline" onClick={edit}><Pencil className="mr-2 h-4 w-4" />{current ? 'Record updated yearly records' : 'Review yearly records'}</Button>}
        </> : <fieldset disabled={saving} className="space-y-5">
          <div><p className="text-sm font-semibold text-neutral-900">Prior-year employer wages for catch-up</p><p className="mt-1 text-sm leading-6 text-neutral-600">Verify these wages before catch-up payroll. If they exceed the IRS threshold, catch-up must satisfy the Roth requirement. Ordinary Traditional contributions remain permitted.</p></div>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label={`${year - 1} wages from this employer`}><Select value={draft.prior_year_wage_status} onChange={(event) => {
              const status = event.target.value as EmployeeRetirementYearInputDraft['prior_year_wage_status'];
              set('prior_year_wage_status', status);
              if (status !== 'verified') set('prior_year_fica_wages', status === 'unknown' ? null : 0);
            }}><option value="unknown">Not yet verified</option><option value="verified">Verified covered Social Security wages</option><option value="no_prior_employer_wages">Verified no prior-year covered employer wages</option></Select></Field>
            {draft.prior_year_wage_status === 'verified' && <Field label="Verified prior-year employer Social Security wages" helper="Use the applicable prior-year employer wage record, not household income or Medicare wages."><NumericInput value={draft.prior_year_fica_wages} onValueChange={(value) => set('prior_year_fica_wages', value || 0)} min={0} fixedDecimalsOnBlur={2} /></Field>}
            {draft.prior_year_wage_status !== 'unknown' && <Field label="Employer wage evidence reference"><Input value={draft.prior_year_wage_source} onChange={(event) => set('prior_year_wage_source', event.target.value)} placeholder="W-2GU / administrator verification reference" /></Field>}
          </div>
          <details className="rounded-xl border border-neutral-200 p-4">
            <summary className="cursor-pointer text-sm font-semibold text-neutral-800">Contributions at another employer</summary>
            <p className="mt-3 text-sm leading-6 text-neutral-600">Enter verified elective deferrals sharing the personal 402(g) limit, such as another 401(k) or 403(b). Exclude 457(b), employer contributions, rollovers, and non-Roth after-tax contributions. Do not repeat amounts already included in this employee’s imported YTD.</p>
            <div className="mt-4 grid gap-4 sm:grid-cols-2"><Field label="Other-employer Traditional contributions"><NumericInput value={draft.external_traditional_deferrals} onValueChange={(value) => set('external_traditional_deferrals', value || 0)} min={0} fixedDecimalsOnBlur={2} /></Field><Field label="Other-employer Roth contributions"><NumericInput value={draft.external_roth_deferrals} onValueChange={(value) => set('external_roth_deferrals', value || 0)} min={0} fixedDecimalsOnBlur={2} /></Field></div>
          </details>
          <details className="rounded-xl border border-neutral-200 p-4">
            <summary className="cursor-pointer text-sm font-semibold text-neutral-800">Additional balances missing from saved payroll</summary>
            <p className="mt-3 text-sm leading-6 text-neutral-600">Use administrator-certified amounts absent from saved payroll. Existing employee Traditional and Roth YTD remain in the historical bridge. These balances supplement it; they must not duplicate its employer match or saved paychecks.</p>
            <div className="mt-4 grid gap-4 sm:grid-cols-2">
              <Field label="Eligible compensation before the system"><NumericInput value={draft.eligible_compensation_before_system} onValueChange={(value) => set('eligible_compensation_before_system', value || 0)} min={0} fixedDecimalsOnBlur={2} /></Field>
              <Field label="Employer additions before the system" helper="Include applicable matching, nonelective contributions and allocated forfeitures."><NumericInput value={draft.employer_additions_before_system} onValueChange={(value) => set('employer_additions_before_system', value || 0)} min={0} fixedDecimalsOnBlur={2} /></Field>
              <Field label="Non-Roth after-tax contributions before the system"><NumericInput value={draft.non_roth_after_tax_before_system} onValueChange={(value) => set('non_roth_after_tax_before_system', value || 0)} min={0} fixedDecimalsOnBlur={2} /></Field>
            </div>
            <label className="mt-4 flex gap-3 text-sm leading-6 text-neutral-700"><input className="mt-1 h-4 w-4 shrink-0 accent-primary-700" type="checkbox" checked={draft.opening_balances_verified} onChange={(event) => set('opening_balances_verified', event.target.checked)} />I verified these opening balances and checked that they do not overlap saved payroll or imported match amounts.</label>
          </details>
          <div className="grid gap-4 sm:grid-cols-2"><Field label="Evidence reference"><Input value={draft.source_reference} onChange={(event) => set('source_reference', event.target.value)} placeholder="Document or administrator review reference" /></Field><Field label="Review note"><Input value={draft.reason} onChange={(event) => set('reason', event.target.value)} placeholder="What was verified or corrected" /></Field></div>
          <div className="flex flex-wrap justify-end gap-3"><Button variant="outline" disabled={saving} onClick={() => { setEditing(false); setError(null); }}>Cancel</Button><Button disabled={saving} onClick={() => void save()}>{saving ? 'Saving…' : 'Save verified records'}</Button></div>
        </fieldset>}
        {!editing && records.filter((record) => Number(record.tax_year) === year).length > 1 && <details className="border-t border-neutral-200 pt-4"><summary className="cursor-pointer text-sm font-semibold text-neutral-700">Previous evidence reviews</summary><ul className="mt-3 space-y-3 text-sm leading-6 text-neutral-600">{records.filter((record) => Number(record.tax_year) === year && record.id !== current?.id).map((record) => <li key={record.id} className="break-words rounded-xl bg-neutral-50 p-3">{record.reason} · {record.source_reference}{record.created_at && <span className="block text-xs">{formatGuamDateTime(record.created_at)}</span>}</li>)}</ul></details>}
      </>}
    </CardContent>
  </Card>;
}

function Field({ label, helper, children }: { label: string; helper?: string; children: ReactElement }): ReactElement {
  return <label className="block text-sm font-medium text-neutral-700">{label}{helper && <span className="mt-1 block text-xs font-normal leading-5 text-neutral-500">{helper}</span>}<span className="mt-2 block">{children}</span></label>;
}
function Value({ label, value }: { label: string; value: string }): ReactElement {
  return <div className="rounded-xl border border-neutral-200 p-4"><p className="text-xs font-semibold text-neutral-500">{label}</p><p className="mt-2 text-lg font-bold tabular-nums text-neutral-900">{value}</p></div>;
}
