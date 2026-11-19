import { useState, type ReactElement } from 'react';
import { Link, useLocation } from 'react-router';
import { ArrowRight } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { employeesApi } from '@/services/api';
import { employeeEditPath } from '@/lib/routes';
import type { YearEndChecklist, YearEndPerson, YearEndStep } from '@/lib/year-end';

type PeopleStepData = Extract<YearEndStep, { key: 'people' }>;
const PAGE_SIZE = 20;

function missingLabel(person: YearEndPerson): string {
  const ids = person.kind === 'contractor' ? 'TIN' : 'SSN';
  return person.missing_fields.map((field) => (field === 'ssn' ? ids : 'address')).join(' and ');
}

function AddressForm({ person, companyId, onSaved, onCancel }: {
  person: YearEndPerson;
  companyId: number;
  onSaved: (message: string) => Promise<void>;
  onCancel: () => void;
}): ReactElement {
  const [values, setValues] = useState({
    address_line1: person.address_line1 ?? '',
    address_line2: person.address_line2 ?? '',
    city: person.city ?? '',
    state: person.state ?? 'GU',
    zip: person.zip ?? '',
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const field = (key: keyof typeof values, label: string, extra: Partial<Parameters<typeof Input>[0]> = {}) => (
    <Input
      label={label}
      value={values[key]}
      onChange={(event) => setValues((current) => ({ ...current, [key]: event.target.value }))}
      disabled={saving}
      required={key !== 'address_line2'}
      autoComplete="off"
      {...extra}
    />
  );

  return (
    <form
      className="mt-3 space-y-3 rounded-xl border border-neutral-200 bg-neutral-50/70 p-3"
      onSubmit={async (event) => {
        event.preventDefault();
        setSaving(true);
        setError(null);
        try {
          const trimmed = Object.fromEntries(Object.entries(values).map(([key, value]) => [key, value.trim()]));
          await employeesApi.update(person.employee_id, trimmed, companyId);
          await onSaved(`Saved ${person.name}'s address.`);
        } catch (err) {
          setError(err instanceof Error ? err.message : 'Could not save the address.');
          setSaving(false);
        }
      }}
    >
      <div className="grid gap-3 sm:grid-cols-2">
        {field('address_line1', 'Street address')}
        {field('address_line2', 'Unit (optional)')}
        {field('city', 'City')}
        <div className="grid grid-cols-2 gap-3">
          {field('state', 'State')}
          {field('zip', 'ZIP', { inputMode: 'numeric' })}
        </div>
      </div>
      {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
      <div className="flex flex-col gap-2 sm:flex-row">
        <Button type="submit" size="sm" loading={saving} loadingLabel="Saving…">Save address</Button>
        <Button type="button" size="sm" variant="ghost" onClick={onCancel} disabled={saving}>Cancel</Button>
      </div>
    </form>
  );
}

function PersonRow({ person, companyId, canEditInline, returnTo, onSaved }: {
  person: YearEndPerson;
  companyId: number;
  canEditInline: boolean;
  returnTo: string;
  onSaved: (message: string) => Promise<void>;
}): ReactElement {
  const [editing, setEditing] = useState(false);
  // Every employee save re-checks the SSN, so only an address-only gap can be fixed here.
  const addressOnly = canEditInline && person.missing_fields.length === 1 && person.missing_fields[0] === 'address';

  return (
    <li className="py-3">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0">
          <p className="font-medium text-neutral-950 [overflow-wrap:anywhere]">{person.name}</p>
          <Badge variant="warning" className="mt-1">Missing {missingLabel(person)}</Badge>
        </div>
        <div className="flex flex-col gap-2 sm:flex-row sm:shrink-0">
          {addressOnly && !editing && (
            <Button size="sm" onClick={() => setEditing(true)} aria-label={`Add address for ${person.name}`}>Add address</Button>
          )}
          <Link
            to={employeeEditPath(companyId, person.employee_id, { returnTo })}
            aria-label={`Open ${person.name}`}
            className="inline-flex min-h-11 items-center justify-center gap-1 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-800 hover:border-primary-300 hover:text-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 sm:min-h-9"
          >
            Open employee<ArrowRight className="h-4 w-4" aria-hidden="true" />
          </Link>
        </div>
      </div>
      {editing && <AddressForm person={person} companyId={companyId} onSaved={onSaved} onCancel={() => setEditing(false)} />}
    </li>
  );
}

function PeopleList({ title, people, companyId, canEditInline, returnTo, onSaved }: {
  title: string;
  people: YearEndPerson[];
  companyId: number;
  canEditInline: boolean;
  returnTo: string;
  onSaved: (message: string) => Promise<void>;
}): ReactElement | null {
  const [shown, setShown] = useState(PAGE_SIZE);
  if (people.length === 0) return null;
  return (
    <div>
      <h3 className="text-sm font-semibold text-neutral-900">{title} ({people.length})</h3>
      <ul className="divide-y divide-neutral-200">
        {people.slice(0, shown).map((person) => (
          <PersonRow key={`${person.kind}-${person.employee_id}`} person={person} companyId={companyId} canEditInline={canEditInline} returnTo={returnTo} onSaved={onSaved} />
        ))}
      </ul>
      {people.length > shown && (
        <Button size="sm" variant="outline" className="mt-2" onClick={() => setShown(people.length)}>Show all {people.length}</Button>
      )}
    </div>
  );
}

export function PeopleStep({ checklist, step, onSaved }: {
  checklist: YearEndChecklist;
  step: PeopleStepData;
  onSaved: (message: string) => Promise<void>;
}): ReactElement {
  const location = useLocation();
  const returnTo = `${location.pathname}${location.search}#step-people`;
  const employees = step.data.employees ?? [];
  const contractors = step.data.contractors ?? [];
  const canEditInline = !checklist.company.test_workspace;

  if (employees.length === 0 && contractors.length === 0) {
    return (
      <p className="text-sm text-neutral-700">
        {step.data.contractor_error ?? `All ${step.data.w2_employee_count ?? 0} W-2 employees${checklist.files_1099 ? ` and ${step.data.contractor_count ?? 0} 1099 payees` : ''} have what the forms need.`}
      </p>
    );
  }

  return (
    <div className="space-y-5">
      <PeopleList title="Employees" people={employees} companyId={checklist.company.id} canEditInline={canEditInline} returnTo={returnTo} onSaved={onSaved} />
      <PeopleList title="1099 payees" people={contractors} companyId={checklist.company.id} canEditInline={canEditInline} returnTo={returnTo} onSaved={onSaved} />
      {step.data.contractor_error && <p className="text-sm text-danger-700">{step.data.contractor_error}</p>}
    </div>
  );
}
