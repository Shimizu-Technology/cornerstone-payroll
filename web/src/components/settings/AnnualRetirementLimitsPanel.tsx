import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { ExternalLink, Pencil, Plus } from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { annualRetirementLimitsApi, ApiError } from '@/services/api';
import type { AnnualRetirementLimit, AnnualRetirementLimitInput } from '@/types';
import { Button } from '@/components/ui/button';
import { NumericInput } from '@/components/ui/numeric-input';

const amountFields = [
  { key: 'elective_deferral_limit', label: 'Regular employee deferral limit', help: 'Traditional and Roth employee deferrals share this limit.' },
  { key: 'catch_up_limit', label: 'Age 50+ catch-up allowance', help: 'Additional allowance when the plan permits catch-up.' },
  { key: 'enhanced_catch_up_limit', label: 'Age 60–63 catch-up allowance', help: 'Replaces the ordinary catch-up allowance for these ages.' },
  { key: 'roth_catch_up_wage_threshold', label: 'Prior-year wage threshold for Roth catch-up', help: 'Covered wages above this amount require Roth catch-up.' },
  { key: 'annual_additions_limit', label: 'Combined annual additions limit', help: 'Employee and employer additions together; permitted catch-up is excluded.' },
  { key: 'compensation_limit', label: 'Employer contribution compensation limit', help: 'Limits compensation used for employer contributions. It does not stop employee deferrals by itself.' },
] as const;

type AmountKey = typeof amountFields[number]['key'];
type Draft = Record<AmountKey, number | null> & {
  tax_year: number | null;
  source_name: string;
  source_url: string;
  reason: string;
};
type Editor = { id: number | null; draft: Draft };

const currency = (value: number) => new Intl.NumberFormat('en-US', {
  style: 'currency', currency: 'USD', maximumFractionDigits: 0,
}).format(Number(value));

function safeSourceUrl(value: string): string | null {
  try {
    const url = new URL(value);
    return ['https:', 'http:'].includes(url.protocol) ? url.href : null;
  } catch {
    return null;
  }
}

function errorMessage(error: unknown, fallback: string) {
  if (error instanceof ApiError) {
    const details = Object.entries(error.fieldErrors).flatMap(([field, messages]) =>
      messages.map((message) => `${field.replaceAll('_', ' ')}: ${message}`));
    return details.length ? `${error.message}. ${details.join('; ')}` : error.message;
  }
  return error instanceof Error ? error.message : fallback;
}

export function AnnualRetirementLimitsPanel() {
  const { isSuperAdmin } = useAuth();
  const [serverCanManage, setServerCanManage] = useState(false);
  const canManage = isSuperAdmin && serverCanManage;
  const [limits, setLimits] = useState<AnnualRetirementLimit[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [editor, setEditor] = useState<Editor | null>(null);
  const [saving, setSaving] = useState(false);
  const firstInput = useRef<HTMLInputElement>(null);
  const editorHeading = useRef<HTMLHeadingElement>(null);
  const addButton = useRef<HTMLButtonElement>(null);

  const loadLimits = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      const response = await annualRetirementLimitsApi.list();
      setLimits(response.data);
      setServerCanManage(response.can_manage ?? true);
    } catch (error) {
      setLoadError(errorMessage(error, 'Could not load retirement limits. Please try again.'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void loadLimits(); }, [loadLimits]);
  useEffect(() => {
    editorHeading.current?.focus();
  }, [editor?.id]);

  const startEditor = (record?: AnnualRetirementLimit) => {
    setSaveError(null);
    setSuccess(null);
    setEditor({
      id: record?.id ?? null,
      draft: record ? {
        tax_year: Number(record.tax_year),
        elective_deferral_limit: record.elective_deferral_limit == null ? null : Number(record.elective_deferral_limit),
        catch_up_limit: record.catch_up_limit == null ? null : Number(record.catch_up_limit),
        enhanced_catch_up_limit: record.enhanced_catch_up_limit == null ? null : Number(record.enhanced_catch_up_limit),
        roth_catch_up_wage_threshold: record.roth_catch_up_wage_threshold == null ? null : Number(record.roth_catch_up_wage_threshold),
        annual_additions_limit: record.annual_additions_limit == null ? null : Number(record.annual_additions_limit),
        compensation_limit: record.compensation_limit == null ? null : Number(record.compensation_limit),
        source_name: record.source_name, source_url: record.source_url, reason: '',
      } : {
        tax_year: Math.max(new Date().getFullYear(), ...limits.map((limit) => Number(limit.tax_year) + 1)),
        elective_deferral_limit: null,
        catch_up_limit: null,
        enhanced_catch_up_limit: null,
        roth_catch_up_wage_threshold: null,
        annual_additions_limit: null,
        compensation_limit: null,
        source_name: '', source_url: '', reason: '',
      },
    });
  };

  const updateDraft = <K extends keyof Draft>(field: K, value: Draft[K]) => {
    setEditor((current) => current ? { ...current, draft: { ...current.draft, [field]: value } } : null);
  };

  const closeEditor = () => {
    setEditor(null);
    setSaveError(null);
    addButton.current?.focus();
  };

  const save = async (event: FormEvent) => {
    event.preventDefault();
    if (!editor || !canManage || saving) return;
    const { draft, id } = editor;
    const validYear = draft.tax_year !== null && Number.isInteger(draft.tax_year) && draft.tax_year >= 2020 && draft.tax_year <= 2100;
    if (!validYear || amountFields.some(({ key }) => draft[key] === null || !Number.isFinite(draft[key]) || Number(draft[key]) < 0)) {
      setSaveError('Enter a whole tax year from 2020 to 2100 and all six verified limit amounts.');
      firstInput.current?.focus();
      return;
    }
    if (!draft.source_name.trim() || !safeSourceUrl(draft.source_url.trim()) || !draft.reason.trim()) {
      setSaveError('Enter the source name, a complete http or https source URL, and the reason for this change.');
      return;
    }
    setSaving(true);
    setSaveError(null);
    try {
      const payload = { ...draft, source_name: draft.source_name.trim(), source_url: draft.source_url.trim(), reason: draft.reason.trim() } as AnnualRetirementLimitInput;
      const response = id === null
        ? await annualRetirementLimitsApi.create(payload)
        : await annualRetirementLimitsApi.update(id, payload);
      setLimits((current) => [...current.filter((limit) => limit.id !== response.data.id), response.data]);
      setEditor(null);
      setSuccess(`${response.data.tax_year} retirement limits saved. The source and reason were recorded.`);
      addButton.current?.focus();
    } catch (error) {
      setSaveError(errorMessage(error, 'Could not save retirement limits. Your entries are still here; please try again.'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <section aria-labelledby="annual-retirement-limits-title" className="rounded-xl border border-neutral-200 bg-white p-4 shadow-sm sm:p-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 id="annual-retirement-limits-title" className="text-xl font-semibold text-neutral-950">Annual 401(k) limits</h2>
          <p className="mt-1 text-sm text-neutral-600">Standard 401(k) limits shared across companies. Employee plan settings determine whether catch-up is permitted.</p>
        </div>
        {canManage && <Button ref={addButton} variant="outline" onClick={() => startEditor()} disabled={loading || !!loadError || !!editor} className="self-start">
          <Plus aria-hidden="true" className="mr-2 h-4 w-4" />Add retirement year
        </Button>}
      </div>
      {success && <p role="status" className="mt-4 rounded-lg bg-green-50 p-3 text-sm text-green-800">{success}</p>}
      {loading && <p role="status" className="mt-4 text-sm text-neutral-600">Loading retirement limits…</p>}
      {loadError && <div role="alert" className="mt-4 rounded-lg bg-danger-50 p-3 text-sm text-danger-800">
        <p>{loadError}</p><Button variant="outline" className="mt-3" onClick={() => void loadLimits()}>Retry retirement limits</Button>
      </div>}
      {!loading && !loadError && limits.length === 0 && <p className="mt-4 rounded-lg bg-neutral-50 p-4 text-sm text-neutral-600">No retirement years have been configured. A super administrator can add verified IRS limits before retirement payroll is calculated.</p>}
      {!loading && !loadError && <div className="mt-5 space-y-5">
        {[...limits].sort((a, b) => b.tax_year - a.tax_year).map((limit) => {
          const sourceUrl = safeSourceUrl(limit.source_url);
          const base = Number(limit.elective_deferral_limit);
          return <article key={limit.id} className="rounded-lg border border-neutral-200 p-4">
            <div className="flex items-center justify-between gap-3">
              <h3 className="text-lg font-semibold text-neutral-950">{limit.tax_year} employee contribution ceilings</h3>
              {canManage && <Button variant="ghost" size="sm" disabled={!!editor} onClick={() => startEditor(limit)} aria-label={`Edit ${limit.tax_year} retirement limits`}>
                <Pencil aria-hidden="true" className="mr-1 h-4 w-4" />Edit
              </Button>}
            </div>
            <dl className="mt-4 grid gap-4 sm:grid-cols-3">
              {[
                { label: 'Under age 50', total: base, catchUp: 0 },
                { label: 'Ages 50–59 and 64+', total: base + Number(limit.catch_up_limit), catchUp: Number(limit.catch_up_limit) },
                { label: 'Ages 60–63', total: base + Number(limit.enhanced_catch_up_limit), catchUp: Number(limit.enhanced_catch_up_limit) },
              ].map((tier) => <div key={tier.label} className="border-l-2 border-primary-200 pl-3">
                <dt className="text-sm text-neutral-600">{tier.label}</dt>
                <dd className="text-xl font-semibold tabular-nums text-neutral-950">{currency(tier.total)}</dd>
                <dd className="mt-1 text-xs text-neutral-600">{tier.catchUp ? `${currency(base)} regular + ${currency(tier.catchUp)} catch-up` : 'Regular employee deferrals'}</dd>
              </div>)}
            </dl>
            <p className="mt-3 text-xs text-neutral-600">Age reached by December 31. Traditional and Roth employee deferrals share these ceilings. Lower plan limits may apply.</p>
            <details className="mt-4 border-t border-neutral-100 pt-3">
              <summary className="cursor-pointer text-sm font-medium text-primary-800">Other IRS limits and Roth catch-up rule</summary>
              <dl className="mt-3 grid gap-4 text-sm sm:grid-cols-3">
                <div><dt className="text-neutral-600">Roth catch-up wage threshold</dt><dd className="font-semibold">{currency(limit.roth_catch_up_wage_threshold)}</dd><dd className="mt-1 text-xs text-neutral-600">Covered {limit.tax_year - 1} employer wages must exceed this amount.</dd></div>
                <div><dt className="text-neutral-600">Combined annual additions</dt><dd className="font-semibold">{currency(limit.annual_additions_limit)}</dd><dd className="mt-1 text-xs text-neutral-600">Employee and employer additions, excluding permitted catch-up; also limited by compensation.</dd></div>
                <div><dt className="text-neutral-600">Employer contribution compensation</dt><dd className="font-semibold">{currency(limit.compensation_limit)}</dd><dd className="mt-1 text-xs text-neutral-600">Compensation used for employer contributions. Employee deferrals can continue after this ceiling.</dd></div>
              </dl>
            </details>
            <p className="mt-4 break-words text-sm text-neutral-600">Source: {sourceUrl ? <a href={sourceUrl} target="_blank" rel="noopener noreferrer" className="font-medium text-primary-800 underline underline-offset-2">{limit.source_name}<ExternalLink aria-hidden="true" className="ml-1 inline h-3 w-3" /><span className="sr-only"> (opens in a new tab)</span></a> : limit.source_name || 'Source not recorded'}</p>
          </article>;
        })}
      </div>}
      {!canManage && <p className="mt-4 text-xs text-neutral-500">A super administrator maintains global annual limits outside test workspaces.</p>}
      {editor && canManage && <form onSubmit={(event) => void save(event)} className="mt-6 border-t border-neutral-200 pt-5" aria-labelledby="retirement-limit-editor-title">
        <h3 ref={editorHeading} tabIndex={-1} id="retirement-limit-editor-title" className="text-lg font-semibold text-neutral-950">{editor.id === null ? 'Add verified retirement year' : `Edit ${editor.draft.tax_year} retirement limits`}</h3>
        <p className="mt-1 text-sm text-neutral-600">Use the IRS publication for this year. These values apply to every company.</p>
        {saveError && <p role="alert" className="mt-3 rounded-lg bg-danger-50 p-3 text-sm text-danger-800">{saveError}</p>}
        <fieldset disabled={saving} className="mt-4 grid min-w-0 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div>
            <label htmlFor="retirement-limit-year" className="text-sm font-medium text-neutral-800">Tax year</label>
            <NumericInput ref={firstInput} id="retirement-limit-year" value={editor.draft.tax_year} onValueChange={(value) => updateDraft('tax_year', value)} emptyValue={null} notifyEmptyOnChange required inputMode="numeric" disabled={editor.id !== null} className="mt-1" />
          </div>
          {amountFields.map(({ key, label, help }) => <div key={key}>
            <label htmlFor={`retirement-limit-${key}`} className="text-sm font-medium text-neutral-800">{label}</label>
            <NumericInput id={`retirement-limit-${key}`} value={editor.draft[key]} onValueChange={(value) => updateDraft(key, value)} emptyValue={null} notifyEmptyOnChange min={0} required aria-describedby={`retirement-limit-${key}-help`} className="mt-1" />
            <p id={`retirement-limit-${key}-help`} className="mt-1 text-xs text-neutral-600">{help}</p>
          </div>)}
          <div className="sm:col-span-2 lg:col-span-3 grid gap-4 sm:grid-cols-2">
            <label className="text-sm font-medium text-neutral-800">Source name<input value={editor.draft.source_name} onChange={(event) => updateDraft('source_name', event.target.value)} required className="mt-1 block w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 font-normal focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300" placeholder="IRS announcement or notice" /></label>
            <label className="text-sm font-medium text-neutral-800">Source URL<input type="url" value={editor.draft.source_url} onChange={(event) => updateDraft('source_url', event.target.value)} required className="mt-1 block w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 font-normal focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300" placeholder="https://www.irs.gov/…" /></label>
            <label className="text-sm font-medium text-neutral-800 sm:col-span-2">Reason for change<textarea value={editor.draft.reason} onChange={(event) => updateDraft('reason', event.target.value)} required rows={2} className="mt-1 block w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 font-normal focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300" placeholder="Verified annual limits against the linked IRS publication" /></label>
          </div>
        </fieldset>
        <div className="mt-5 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
          <Button type="button" variant="outline" disabled={saving} onClick={closeEditor}>Cancel</Button>
          <Button type="submit" loading={saving} loadingLabel="Saving retirement limits…">Save retirement limits</Button>
        </div>
      </form>}
    </section>
  );
}
