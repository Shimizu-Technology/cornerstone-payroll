import { useState, type ReactElement } from 'react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { reportsApi } from '@/services/api';
import { cn } from '@/lib/utils';
import type { YearEndChecklist, YearEndParty, YearEndStep } from '@/lib/year-end';
import { useStillMounted } from './useStillMounted';

type DecisionStep = Extract<YearEndStep, { key: 'filing_decision' }>;
type W2Choice = YearEndParty | 'cornerstone_after_prior_provider';

interface Option<T extends string> {
  value: T;
  label: string;
  hint: string;
}

function w2Options(year: number): Option<W2Choice>[] {
  return [
    { value: 'cornerstone', label: 'Cornerstone files', hint: `For all ${year} wages, including any opening balances.` },
    { value: 'cornerstone_after_prior_provider', label: 'Cornerstone files, after a prior provider', hint: 'A prior provider files W-2s for the first part of the year.' },
    { value: 'client', label: 'The client files', hint: 'Cornerstone prepares nothing to file.' },
    { value: 'external_provider', label: 'Another payroll provider files', hint: 'For the whole year.' },
    { value: 'no_filing', label: `No W-2s for ${year}`, hint: 'For example an inactive or duplicate record.' },
  ];
}

function form1099Options(year: number): Option<YearEndParty>[] {
  return [
    { value: 'cornerstone', label: 'Cornerstone files', hint: '1099-NECs for contractors paid here.' },
    { value: 'client', label: 'The client files', hint: 'Cornerstone prepares nothing to file.' },
    { value: 'external_provider', label: 'Another provider files', hint: 'For the whole year.' },
    { value: 'no_filing', label: `No 1099s for ${year}`, hint: 'No contractor payments to report.' },
  ];
}

function ChoiceGroup<T extends string>({ legend, name, options, value, onChange, disabled }: {
  legend: string;
  name: string;
  options: Option<T>[];
  value: T | null;
  onChange: (value: T) => void;
  disabled: boolean;
}): ReactElement {
  return (
    <fieldset className="min-w-0">
      <legend className="mb-2 text-sm font-semibold text-neutral-900">{legend}</legend>
      <div className="grid gap-2 lg:grid-cols-2">
        {options.map((option) => (
          <label
            key={option.value}
            className={cn(
              'flex min-h-11 cursor-pointer gap-3 rounded-xl border bg-white p-3 transition',
              value === option.value ? 'border-primary-400 bg-primary-50/60 ring-1 ring-primary-200' : 'border-neutral-200 hover:border-primary-200',
              disabled && 'cursor-not-allowed opacity-70',
            )}
          >
            <input
              type="radio"
              name={name}
              value={option.value}
              checked={value === option.value}
              onChange={() => onChange(option.value)}
              disabled={disabled}
              className="mt-1 h-4 w-4 shrink-0 accent-primary-700"
            />
            <span className="min-w-0">
              <span className="block text-sm font-semibold text-neutral-950">{option.label}</span>
              <span className="block text-xs leading-5 text-neutral-600">{option.hint}</span>
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

function initialW2Choice(step: DecisionStep): W2Choice | null {
  const decision = step.data.w2;
  if (!decision) return (step.data.w2_employee_count ?? 0) > 0 ? null : 'no_filing';
  return decision.responsible_party === 'cornerstone' && decision.prior_provider_through ? 'cornerstone_after_prior_provider' : decision.responsible_party;
}

function initial1099Choice(step: DecisionStep): YearEndParty | null {
  if (step.data.form_1099) return step.data.form_1099.responsible_party;
  return (step.data.contractor_count ?? 0) > 0 ? null : 'no_filing';
}

export function FilingDecisionStep({ checklist, step, onSaved }: {
  checklist: YearEndChecklist;
  step: DecisionStep;
  onSaved: (message: string) => Promise<void>;
}): ReactElement {
  const year = checklist.tax_year;
  // Saves always name this checklist's client, never the app's current one.
  const companyId = checklist.company.id;
  const stillMounted = useStillMounted();
  const canRecord = checklist.permissions.can_record_decision;
  const [w2, setW2] = useState<W2Choice | null>(() => initialW2Choice(step));
  const [form1099, setForm1099] = useState<YearEndParty | null>(() => initial1099Choice(step));
  const [priorThrough, setPriorThrough] = useState(step.data.w2?.prior_provider_through ?? '');
  const [notes, setNotes] = useState(step.data.w2?.notes ?? '');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const needsDate = w2 === 'cornerstone_after_prior_provider';
  const dateValid = !needsDate || /^\d{4}-\d{2}-\d{2}$/.test(priorThrough) && priorThrough.startsWith(`${year}-`);
  const canSave = canRecord && w2 !== null && form1099 !== null && dateValid && !saving;

  async function save(choices: { w2: W2Choice; form1099: YearEndParty }) {
    setSaving(true);
    setError(null);
    const w2Party: YearEndParty = choices.w2 === 'cornerstone_after_prior_provider' ? 'cornerstone' : choices.w2;
    const through = choices.w2 === 'cornerstone_after_prior_provider' ? priorThrough : null;
    const common = { tax_year: year, imported_payroll_inclusion: 'included' as const, notes: notes.trim() || undefined };
    try {
      if (w2Party === choices.form1099 && !through) {
        await reportsApi.updatePayrollFilingResponsibility({ ...common, filing_types: ['w2_gu', 'form_1099'], responsible_party: w2Party, prior_provider_through: null }, companyId);
      } else {
        await reportsApi.updatePayrollFilingResponsibility({ ...common, filing_types: ['w2_gu'], responsible_party: w2Party, prior_provider_through: through }, companyId);
        // The user left this client while the first save was in flight.
        if (!stillMounted()) return;
        await reportsApi.updatePayrollFilingResponsibility({ ...common, filing_types: ['form_1099'], responsible_party: choices.form1099, prior_provider_through: null }, companyId);
      }
      if (!stillMounted()) return;
      await onSaved(choices.w2 === 'no_filing' && choices.form1099 === 'no_filing'
        ? `${checklist.company.name} files no ${year} year-end forms. It is off the to-do list; nothing was deleted.`
        : 'Saved who files.');
    } catch (err) {
      if (stillMounted()) setError(err instanceof Error ? err.message : 'Could not save who files.');
    } finally {
      if (stillMounted()) setSaving(false);
    }
  }

  if (!canRecord) {
    return (
      <p className="text-sm text-neutral-700">
        {step.data.w2 && step.data.form_1099
          ? `W-2s: ${step.data.w2.label}. 1099s: ${step.data.form_1099.label}.`
          : 'A filing reviewer records who files. Ask an accountant, manager or admin to answer this step.'}
      </p>
    );
  }

  return (
    <form
      className="space-y-5"
      onSubmit={(event) => {
        event.preventDefault();
        if (canSave && w2 && form1099) void save({ w2, form1099 });
      }}
    >
      <ChoiceGroup legend={`Who files ${year} W-2s?`} name="w2-party" options={w2Options(year)} value={w2} onChange={setW2} disabled={saving} />
      {needsDate && (
        <div className="max-w-xs">
          <Input
            type="date"
            label="The prior provider files wages paid through"
            value={priorThrough}
            min={`${year}-01-01`}
            max={`${year}-12-31`}
            onChange={(event) => setPriorThrough(event.target.value)}
            error={priorThrough && !dateValid ? `Choose a date in ${year}.` : undefined}
            required
          />
        </div>
      )}
      <ChoiceGroup legend={`Who files ${year} 1099s?`} name="form-1099-party" options={form1099Options(year)} value={form1099} onChange={setForm1099} disabled={saving} />
      <p className="text-xs text-neutral-600">
        {(step.data.contractor_count ?? 0) > 0
          ? `${step.data.contractor_count} contractor${step.data.contractor_count === 1 ? ' was' : 's were'} paid here in ${year}.`
          : `No contractor payments were made here in ${year}.`}
      </p>
      <div className="max-w-xl">
        <label htmlFor="year-end-decision-notes" className="mb-1.5 block text-xs font-medium text-neutral-600">Notes (optional)</label>
        <Textarea id="year-end-decision-notes" value={notes} onChange={(event) => setNotes(event.target.value)} rows={2} maxLength={2000} disabled={saving} />
      </div>
      {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
      <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap">
        <Button type="submit" disabled={!canSave} loading={saving} loadingLabel="Saving…">Save who files</Button>
        {!(step.data.w2?.responsible_party === 'no_filing' && step.data.form_1099?.responsible_party === 'no_filing') && (
          <Button type="button" variant="outline" disabled={saving} onClick={() => { setW2('no_filing'); setForm1099('no_filing'); void save({ w2: 'no_filing', form1099: 'no_filing' }); }}>
            This record files no {year} forms
          </Button>
        )}
      </div>
    </form>
  );
}
