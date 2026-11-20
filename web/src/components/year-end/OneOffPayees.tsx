import { useState, type FormEvent, type ReactElement } from 'react';
import { Link } from 'react-router';
import { ArrowRight, Undo2 } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { yearEndApi, type OneOffPayeeContractorInput } from '@/services/api';
import { formatCurrency, formatDate } from '@/lib/utils';
import { cn } from '@/lib/utils';
import { oneOffPayeeAnchor, type YearEndChecklist, type YearEndLinkCandidate, type YearEndLinkedChecks, type YearEndOneOffPayee } from '@/lib/year-end';
import { useStillMounted } from './useStillMounted';
import { StaleReviewNotice } from './StaleReview';
import { isStaleReview, useStaleReview } from './useStaleReview';

type Resolution = 'link' | 'add' | 'none';

const CHOICES: Array<{ value: Resolution; title: string; detail: string }> = [
  { value: 'link', title: 'Link to a contractor', detail: 'The checks join that contractor’s one 1099.' },
  { value: 'add', title: 'Add as a new contractor', detail: 'Enter the TIN and address from their W-9.' },
  { value: 'none', title: 'No 1099 is due', detail: 'For example, a corporation, or goods rather than services.' },
];

function checkLine(checks: Array<{ check_number: string | null; payment_date: string | null; amount: number }>): string {
  return checks.map((check) => `${check.check_number ? `#${check.check_number}` : 'no number'}${check.payment_date ? ` on ${formatDate(check.payment_date)}` : ''} (${formatCurrency(check.amount)})`).join(', ');
}

function candidateLabel(candidate: YearEndLinkCandidate): string {
  const name = candidate.business_name ? `${candidate.name} (${candidate.business_name})` : candidate.name;
  const tin = candidate.tin_type ? `${candidate.tin_type} ending ${candidate.tin_last4}` : 'no TIN yet';
  return `${name}: ${tin}${candidate.status === 'active' ? '' : `, ${candidate.status}`}`;
}

/** The contractor's name or business name is this payee's name exactly (ignoring case and spacing). */
function matchesPayee(candidate: YearEndLinkCandidate, payee: YearEndOneOffPayee): boolean {
  const name = payee.name.trim().replace(/\s+/g, ' ').toLowerCase();
  return [candidate.name, candidate.business_name].some((value) => value != null && value.trim().replace(/\s+/g, ' ').toLowerCase() === name);
}

/** Splits a payee name into a first and last name to start the form with. */
function nameParts(name: string): { first: string; last: string } {
  const words = name.trim().split(/\s+/);
  if (words.length < 2) return { first: '', last: words[0] ?? '' };
  return { first: words.slice(0, -1).join(' '), last: words[words.length - 1] };
}

/** Errors other than a stale-data refusal, which the stale notice handles. */
function useSubmit(payee: YearEndOneOffPayee, onRefresh: () => Promise<void>) {
  const stillMounted = useStillMounted();
  const stale = useStaleReview(payee.digest, onRefresh);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(action: () => Promise<unknown>, onDone: () => Promise<void>, fallback: string) {
    if (!stale.canSubmit) return;
    setSaving(true);
    setError(null);
    try {
      await action();
      if (!stillMounted()) return;
      stale.clear();
      await onDone();
    } catch (err) {
      if (!stillMounted()) return;
      if (isStaleReview(err)) stale.markRefused();
      else setError(err instanceof Error && err.message ? err.message : fallback);
    } finally {
      if (stillMounted()) setSaving(false);
    }
  }

  return { stale, saving, error, submit };
}

function LinkForm({ checklist, payee, candidates, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  payee: YearEndOneOffPayee;
  candidates: YearEndLinkCandidate[];
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement {
  const suggested = candidates.filter((candidate) => matchesPayee(candidate, payee));
  const others = candidates.filter((candidate) => !matchesPayee(candidate, payee));
  const [employeeId, setEmployeeId] = useState(suggested.length === 1 ? String(suggested[0].employee_id) : '');
  const { stale, saving, error, submit } = useSubmit(payee, onRefresh);
  const idPrefix = `link-${oneOffPayeeAnchor(payee.payee_key)}`;
  const chosen = candidates.find((candidate) => String(candidate.employee_id) === employeeId);

  if (candidates.length === 0) {
    return <p className="text-sm text-neutral-700">This client has no contractor records yet. Add the payee as a new contractor instead.</p>;
  }

  return (
    <form
      className="space-y-3"
      onSubmit={(event: FormEvent) => {
        event.preventDefault();
        if (!chosen) return;
        void submit(
          () => yearEndApi.linkOneOffPayee({ tax_year: checklist.tax_year, code: payee.code, digest: payee.digest, employee_id: chosen.employee_id }, checklist.company.id),
          () => onSaved(`Linked ${payee.name}'s checks to ${chosen.name}.`),
          'Could not link the checks.',
        );
      }}
    >
      <Select id={`${idPrefix}-contractor`} label="Contractor" value={employeeId} onChange={(event) => setEmployeeId(event.target.value)} disabled={saving} required>
        <option value="" disabled>Choose a contractor</option>
        {suggested.length > 0 && (
          <optgroup label="Same name as the payee">
            {suggested.map((candidate) => <option key={candidate.employee_id} value={candidate.employee_id}>{candidateLabel(candidate)}</option>)}
          </optgroup>
        )}
        {others.length > 0 && (
          <optgroup label={suggested.length > 0 ? 'Other contractors' : 'Contractors'}>
            {others.map((candidate) => <option key={candidate.employee_id} value={candidate.employee_id}>{candidateLabel(candidate)}</option>)}
          </optgroup>
        )}
      </Select>
      {chosen && (
        <p className="text-sm text-neutral-700">
          {formatCurrency(payee.total_compensation)} goes on {chosen.name}&rsquo;s 1099 with their payroll pay.
          {chosen.year_total !== undefined && ` With the ${formatCurrency(chosen.year_total)} already paid this year, that's ${formatCurrency(chosen.year_total + payee.total_compensation)}.`}
          {!chosen.tin_type || !chosen.has_address ? ` ${chosen.name} still needs ${[!chosen.tin_type && 'a TIN', !chosen.has_address && 'an address'].filter(Boolean).join(' and ')}; the list above will show it.` : ''}
        </p>
      )}
      <StaleReviewNotice stale={stale} idPrefix={idPrefix} what="checks" />
      {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
      <Button type="submit" size="sm" className="w-full sm:w-auto" disabled={!chosen || !stale.canSubmit} loading={saving} loadingLabel="Linking…">Link checks</Button>
    </form>
  );
}

function AddContractorForm({ checklist, payee, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  payee: YearEndOneOffPayee;
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement {
  const parts = nameParts(payee.name);
  const [values, setValues] = useState({
    contractor_type: 'individual' as 'individual' | 'business',
    first_name: parts.first, middle_name: '', last_name: parts.last, business_name: payee.name, tin: '',
    address_line1: '', address_line2: '', city: '', state: 'GU', zip: '', w9_on_file: true,
  });
  const { stale, saving, error, submit } = useSubmit(payee, onRefresh);
  const idPrefix = `add-${oneOffPayeeAnchor(payee.payee_key)}`;
  const business = values.contractor_type === 'business';
  const set = (key: keyof typeof values) => (event: { target: { value: string } }) => setValues((current) => ({ ...current, [key]: event.target.value }));
  const text = (key: Exclude<keyof typeof values, 'contractor_type' | 'w9_on_file'>, label: string, extra: Record<string, unknown> = {}) => (
    <Input id={`${idPrefix}-${key}`} label={label} value={values[key]} onChange={set(key)} disabled={saving} autoComplete="off" {...extra} />
  );

  return (
    <form
      className="space-y-3"
      onSubmit={(event: FormEvent) => {
        event.preventDefault();
        const contractor: OneOffPayeeContractorInput = {
          contractor_type: values.contractor_type,
          first_name: values.first_name.trim(), middle_name: values.middle_name.trim(), last_name: values.last_name.trim(),
          business_name: business ? values.business_name.trim() : undefined, tin: values.tin.trim(),
          address_line1: values.address_line1.trim(), address_line2: values.address_line2.trim(), city: values.city.trim(),
          state: values.state.trim(), zip: values.zip.trim(), w9_on_file: values.w9_on_file,
        };
        const name = business ? contractor.business_name : `${contractor.first_name} ${contractor.last_name}`;
        void submit(
          () => yearEndApi.createOneOffPayeeContractor({ tax_year: checklist.tax_year, code: payee.code, digest: payee.digest, contractor }, checklist.company.id),
          () => onSaved(`Added ${name} as a contractor and linked the checks.`),
          'Could not add the contractor.',
        );
      }}
    >
      <fieldset>
        <legend className="mb-1.5 text-xs font-medium text-neutral-600">The W-9 is for</legend>
        <div className="grid grid-cols-2 gap-2">
          {(['individual', 'business'] as const).map((type) => (
            <label key={type} className={cn('flex min-h-11 cursor-pointer items-center gap-2 rounded-xl border px-3 text-sm', values.contractor_type === type ? 'border-primary-400 bg-primary-50' : 'border-neutral-300')}>
              <input type="radio" name={`${idPrefix}-type`} value={type} checked={values.contractor_type === type} disabled={saving}
                onChange={() => setValues((current) => ({ ...current, contractor_type: type }))} className="accent-primary-700" />
              {type === 'individual' ? 'A person (SSN)' : 'A business (EIN)'}
            </label>
          ))}
        </div>
      </fieldset>
      <div className="grid gap-3 sm:grid-cols-2">
        {business && text('business_name', 'Business name', { required: true })}
        {text('tin', business ? 'EIN' : 'SSN', { required: true, inputMode: 'numeric', placeholder: business ? '12-3456789' : '123-45-6789', maxLength: 11 })}
        {text('first_name', business ? 'Contact first name' : 'First name', { required: true })}
        {!business && text('middle_name', 'Middle name (optional)')}
        {text('last_name', business ? 'Contact last name' : 'Last name', { required: true })}
        {text('address_line1', 'Street address', { required: true })}
        {text('address_line2', 'Unit (optional)')}
        {text('city', 'City', { required: true })}
        <div className="grid grid-cols-2 gap-3">
          {text('state', 'State', { required: true, maxLength: 2 })}
          {text('zip', 'ZIP', { required: true, inputMode: 'numeric' })}
        </div>
      </div>
      <label className="flex min-h-11 items-center gap-2 text-sm text-neutral-800">
        <input type="checkbox" checked={values.w9_on_file} disabled={saving} className="h-4 w-4 accent-primary-700"
          onChange={(event) => setValues((current) => ({ ...current, w9_on_file: event.target.checked }))} />
        We have this payee&rsquo;s W-9 on file
      </label>
      <p className="text-sm text-neutral-600">The new record is kept out of payroll runs. It holds the TIN and address for the 1099.</p>
      <StaleReviewNotice stale={stale} idPrefix={idPrefix} what="checks" />
      {error && <p role="alert" className="whitespace-pre-line text-sm text-danger-700">{error}</p>}
      <Button type="submit" size="sm" className="w-full sm:w-auto" disabled={!stale.canSubmit} loading={saving} loadingLabel="Saving…">Add contractor and link checks</Button>
    </form>
  );
}

function NoForm1099Form({ checklist, payee, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  payee: YearEndOneOffPayee;
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement {
  const [note, setNote] = useState('');
  const { stale, saving, error, submit } = useSubmit(payee, onRefresh);
  const noteId = `none-${oneOffPayeeAnchor(payee.payee_key)}`;

  return (
    <form
      className="space-y-2"
      onSubmit={(event: FormEvent) => {
        event.preventDefault();
        if (!note.trim()) return;
        void submit(
          () => yearEndApi.acknowledge({ tax_year: checklist.tax_year, warning_code: payee.code, warning_digest: payee.digest, note: note.trim() }, checklist.company.id),
          () => onSaved(`Recorded that ${payee.name} gets no 1099.`),
          'Could not record this.',
        );
      }}
    >
      <label htmlFor={noteId} className="block text-xs font-medium text-neutral-700">Why is no 1099 due?</label>
      <Textarea id={noteId} value={note} onChange={(event) => setNote(event.target.value)} rows={2} maxLength={2000} required disabled={saving} />
      <StaleReviewNotice stale={stale} idPrefix={noteId} what="checks" />
      {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
      <Button type="submit" size="sm" className="w-full sm:w-auto" disabled={!note.trim() || !stale.canSubmit} loading={saving} loadingLabel="Saving…">Record: no 1099 due</Button>
    </form>
  );
}

function OneOffPayeeRow({ checklist, payee, candidates, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  payee: YearEndOneOffPayee;
  candidates: YearEndLinkCandidate[];
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement {
  const identified = payee.status === 'identified';
  const [choice, setChoice] = useState<Resolution | null>(candidates.some((candidate) => matchesPayee(candidate, payee)) ? 'link' : null);
  const anchor = oneOffPayeeAnchor(payee.payee_key);

  return (
    <li id={anchor} className="scroll-mt-28 py-3">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <p className="font-medium text-neutral-950 [overflow-wrap:anywhere]">{payee.name}</p>
          <Badge variant={identified ? 'success' : 'warning'} className="mt-1">
            {identified ? 'No 1099 due' : payee.acknowledgement_stale ? 'Resolve again' : 'Needs a decision'}
          </Badge>
          <p className="mt-1 text-sm text-neutral-700">
            {formatCurrency(payee.total_compensation)} in {payee.payment_count} one-off check{payee.payment_count === 1 ? '' : 's'}: {checkLine(payee.checks)}
          </p>
          {payee.acknowledgement_stale && (
            <p className="mt-1 text-sm text-warning-800">The checks changed, or the earlier note only said who the payee was. Choose again.</p>
          )}
          {identified && payee.acknowledgement && (
            <p className="mt-1 text-sm text-neutral-600 [overflow-wrap:anywhere]">&ldquo;{payee.acknowledgement.note}&rdquo; ({payee.acknowledgement.acknowledged_by.name})</p>
          )}
        </div>
        <Link
          to={payee.checks_path}
          aria-label={`Open checks for ${payee.name}`}
          className="inline-flex min-h-11 items-center justify-center gap-1 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-800 hover:border-primary-300 hover:text-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 sm:min-h-9 sm:shrink-0"
        >
          Open checks<ArrowRight className="h-4 w-4" aria-hidden="true" />
        </Link>
      </div>
      {!identified && (checklist.permissions.can_acknowledge ? (
        <div className="mt-3 space-y-3 rounded-xl border border-neutral-200 bg-neutral-50/70 p-3">
          <fieldset>
            <legend className="mb-2 text-sm font-semibold text-neutral-900">What should happen to these checks?</legend>
            <div className="grid gap-2 sm:grid-cols-3">
              {CHOICES.map((option) => (
                <label
                  key={option.value}
                  className={cn('flex min-h-11 cursor-pointer gap-2 rounded-xl border bg-white p-3 text-sm', choice === option.value ? 'border-primary-400 ring-2 ring-primary-100' : 'border-neutral-300')}
                >
                  <input type="radio" name={`${anchor}-choice`} value={option.value} checked={choice === option.value}
                    onChange={() => setChoice(option.value)} className="mt-0.5 accent-primary-700" />
                  <span>
                    <span className="block font-medium text-neutral-950">{option.title}</span>
                    <span className="block text-neutral-600">{option.detail}</span>
                  </span>
                </label>
              ))}
            </div>
          </fieldset>
          {choice === 'link' && <LinkForm checklist={checklist} payee={payee} candidates={candidates} onSaved={onSaved} onRefresh={onRefresh} />}
          {choice === 'add' && <AddContractorForm checklist={checklist} payee={payee} onSaved={onSaved} onRefresh={onRefresh} />}
          {choice === 'none' && <NoForm1099Form checklist={checklist} payee={payee} onSaved={onSaved} onRefresh={onRefresh} />}
        </div>
      ) : <p className="mt-2 text-sm text-neutral-600">A filing reviewer decides what happens to these checks.</p>)}
    </li>
  );
}

export function OneOffPayeeList({ checklist, payees, candidates, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  payees: YearEndOneOffPayee[];
  candidates: YearEndLinkCandidate[];
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement | null {
  if (payees.length === 0) return null;
  return (
    <div>
      <h3 className="text-sm font-semibold text-neutral-900">One-off 1099 payees ({payees.length})</h3>
      <p className="text-sm text-neutral-600">
        These were paid by contractor checks, not payroll, so there is no record with a TIN or address. If the payee is already a contractor, link the checks so they get one 1099 for everything.
      </p>
      <ul className="divide-y divide-neutral-200">
        {payees.map((payee) => <OneOffPayeeRow key={payee.code} checklist={checklist} payee={payee} candidates={candidates} onSaved={onSaved} onRefresh={onRefresh} />)}
      </ul>
    </div>
  );
}

function LinkedGroup({ checklist, group, onSaved }: {
  checklist: YearEndChecklist;
  group: YearEndLinkedChecks;
  onSaved: (message: string) => Promise<void>;
}): ReactElement {
  const stillMounted = useStillMounted();
  const [confirming, setConfirming] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const name = group.name ?? 'this contractor';

  async function unlink() {
    setSaving(true);
    setError(null);
    try {
      await yearEndApi.unlinkOneOffPayee({ tax_year: checklist.tax_year, check_ids: group.checks.map((check) => check.id) }, checklist.company.id);
      if (!stillMounted()) return;
      await onSaved(`Unlinked the checks from ${name}.`);
    } catch (err) {
      if (stillMounted()) setError(err instanceof Error && err.message ? err.message : 'Could not undo the link.');
    } finally {
      if (stillMounted()) setSaving(false);
    }
  }

  return (
    <li className="py-3">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <p className="font-medium text-neutral-950 [overflow-wrap:anywhere]">{name}</p>
          <p className="mt-1 text-sm text-neutral-700">
            {formatCurrency(group.total)} in one-off check{group.checks.length === 1 ? '' : 's'} to {[...new Set(group.checks.map((check) => check.payable_to))].join(', ')}: {checkLine(group.checks)}
          </p>
        </div>
        {checklist.permissions.can_acknowledge && !confirming && (
          <Button size="sm" variant="outline" className="w-full sm:w-auto sm:shrink-0" onClick={() => setConfirming(true)} aria-label={`Undo link to ${name}`}>
            <Undo2 className="mr-1.5 h-4 w-4" aria-hidden="true" />Undo link
          </Button>
        )}
      </div>
      {confirming && (
        <div className="mt-2 rounded-xl border border-warning-200 bg-warning-50/50 p-3 text-sm text-warning-900">
          <p>Take these checks off {name}&rsquo;s 1099? They go back to the one-off list to decide again.</p>
          {error && <p role="alert" className="mt-1 text-danger-700">{error}</p>}
          <div className="mt-2 flex flex-col gap-2 sm:flex-row">
            <Button size="sm" variant="outline" onClick={() => void unlink()} loading={saving} loadingLabel="Undoing…">Yes, undo the link</Button>
            <Button size="sm" variant="ghost" onClick={() => setConfirming(false)} disabled={saving}>Keep it</Button>
          </div>
        </div>
      )}
    </li>
  );
}

export function LinkedChecksList({ checklist, groups, onSaved }: {
  checklist: YearEndChecklist;
  groups: YearEndLinkedChecks[];
  onSaved: (message: string) => Promise<void>;
}): ReactElement | null {
  if (groups.length === 0) return null;
  return (
    <div>
      <h3 className="text-sm font-semibold text-neutral-900">One-off checks linked to contractors ({groups.length})</h3>
      <ul className="divide-y divide-neutral-200">
        {groups.map((group) => <LinkedGroup key={group.employee_id} checklist={checklist} group={group} onSaved={onSaved} />)}
      </ul>
    </div>
  );
}

function SmallerPayeeRow({ checklist, payee, candidates, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  payee: YearEndOneOffPayee;
  candidates: YearEndLinkCandidate[];
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement {
  const [linking, setLinking] = useState(false);
  const anchor = oneOffPayeeAnchor(payee.payee_key);
  const suggested = candidates.find((candidate) => matchesPayee(candidate, payee));

  return (
    <li id={anchor} className="scroll-mt-28 py-3">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <p className="font-medium text-neutral-950 [overflow-wrap:anywhere]">{payee.name}</p>
          {payee.could_reach_threshold && <Badge variant="warning" className="mt-1">Could reach the 1099 threshold with a contractor</Badge>}
          <p className="mt-1 text-sm text-neutral-700">
            {formatCurrency(payee.total_compensation)} in {payee.payment_count} one-off check{payee.payment_count === 1 ? '' : 's'}: {checkLine(payee.checks)}
          </p>
          {suggested && <p className="mt-1 text-sm text-neutral-600">Same name as contractor {suggested.name}.</p>}
        </div>
        <div className="flex flex-col gap-2 sm:flex-row sm:shrink-0">
          {checklist.permissions.can_acknowledge && candidates.length > 0 && !linking && (
            <Button size="sm" variant="outline" onClick={() => setLinking(true)} aria-label={`Link ${payee.name}'s checks to a contractor`}>Link to a contractor</Button>
          )}
          <Link
            to={payee.checks_path}
            aria-label={`Open checks for ${payee.name}`}
            className="inline-flex min-h-11 items-center justify-center gap-1 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-800 hover:border-primary-300 hover:text-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 sm:min-h-9"
          >
            Open checks<ArrowRight className="h-4 w-4" aria-hidden="true" />
          </Link>
        </div>
      </div>
      {linking && (
        <div className="mt-3 space-y-3 rounded-xl border border-neutral-200 bg-neutral-50/70 p-3">
          <LinkForm checklist={checklist} payee={payee} candidates={candidates} onSaved={onSaved} onRefresh={onRefresh} />
          <Button type="button" size="sm" variant="ghost" className="w-full sm:w-auto" onClick={() => setLinking(false)}>Cancel</Button>
        </div>
      )}
    </li>
  );
}

/**
 * Unlinked one-off payees below the 1099 threshold. None of them blocks the
 * 1099s, but a check to a contractor the client already pays belongs on that
 * contractor's 1099, so each can be linked here.
 */
export function SmallerOneOffPayeeList({ checklist, payees, candidates, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  payees: YearEndOneOffPayee[];
  candidates: YearEndLinkCandidate[];
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement | null {
  if (payees.length === 0) return null;
  return (
    <div>
      <h3 className="text-sm font-semibold text-neutral-900">Smaller one-off checks (link them if they&rsquo;re to a contractor you already pay) ({payees.length})</h3>
      <p className="text-sm text-neutral-600">
        Each is under the 1099 threshold on its own, so it doesn&rsquo;t hold anything up. If one went to a contractor, link it: it counts toward that contractor&rsquo;s 1099.
      </p>
      <ul className="divide-y divide-neutral-200">
        {payees.map((payee) => <SmallerPayeeRow key={payee.code} checklist={checklist} payee={payee} candidates={candidates} onSaved={onSaved} onRefresh={onRefresh} />)}
      </ul>
    </div>
  );
}
