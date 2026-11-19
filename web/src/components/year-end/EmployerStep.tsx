import { EmployerFilingSettings } from './EmployerFilingSettings';
import { useEffect, useState, type ReactElement } from 'react';
import { Link } from 'react-router';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { companiesApi } from '@/services/api';
import { IssueList } from '@/components/year-end/StepCard';
import type { YearEndChecklist, ActiveYearEndStep } from '@/lib/year-end';
import { useStillMounted } from './useStillMounted';

type EmployerStepData = ActiveYearEndStep<'employer'>;
type Field = 'filing_contact_name' | 'ein' | 'address_line1' | 'address_line2' | 'city' | 'state' | 'zip' | 'phone' | 'email';

const LABELS: Record<Field, string> = {
  filing_contact_name: 'Employer filing contact name',
  ein: 'EIN',
  address_line1: 'Street address',
  address_line2: 'Suite or unit (optional)',
  city: 'City',
  state: 'State',
  zip: 'ZIP',
  phone: 'Phone',
  email: 'Email',
};

/** Shows only the missing groups as inputs; saving uses the client's own edit permissions. */
export function EmployerStep({ checklist, step, onSaved }: {
  checklist: YearEndChecklist;
  step: EmployerStepData;
  onSaved: (message: string) => Promise<void>;
}): ReactElement {
  const missing = new Set(step.issues.map((issue) => issue.field));
  const fields: Field[] = [
    ...(missing.has('filing_contact_name') ? ['filing_contact_name' as const] : []),
    ...(missing.has('ein') ? ['ein' as const] : []),
    ...(missing.has('address') ? ['address_line1' as const, 'address_line2' as const, 'city' as const, 'state' as const, 'zip' as const] : []),
    ...(missing.has('phone') ? ['phone' as const] : []),
    ...(missing.has('email') ? ['email' as const] : []),
  ];
  const [editable, setEditable] = useState<string[] | null>(null);
  // A failed lookup is not "read-only": say so and let the user try again.
  const [permissionError, setPermissionError] = useState(false);
  const [lookupAttempt, setLookupAttempt] = useState(0);
  const [values, setValues] = useState<Record<Field, string>>(() => ({
    filing_contact_name: step.data.filing_contact_name ?? '',
    ein: step.data.ein ?? '',
    address_line1: step.data.address_line1 ?? '',
    address_line2: step.data.address_line2 ?? '',
    city: step.data.city ?? '',
    state: step.data.state ?? '',
    zip: step.data.zip ?? '',
    phone: step.data.phone ?? '',
    email: step.data.email ?? '',
  }));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const stillMounted = useStillMounted();

  useEffect(() => {
    if (fields.length === 0) return;
    let active = true;
    setPermissionError(false);
    void companiesApi.get(checklist.company.id, checklist.company.id)
      .then((response) => { if (active) setEditable(response.company.editable_fields ?? []); })
      .catch(() => { if (active) setPermissionError(true); });
    return () => { active = false; };
  }, [checklist.company.id, fields.length, lookupAttempt]);

  const address = [step.data.address_line1, step.data.address_line2, [step.data.city, step.data.state, step.data.zip].filter(Boolean).join(' ')].filter(Boolean).join(', ');
  const summary = (
    <dl className="grid gap-3 text-sm sm:grid-cols-2">
      <div><dt className="text-xs font-semibold text-neutral-600">Employer</dt><dd className="text-neutral-950 [overflow-wrap:anywhere]">{step.data.name}</dd></div>
      <div><dt className="text-xs font-semibold text-neutral-600">EIN</dt><dd className="text-neutral-950">{step.data.ein || 'Missing'}</dd></div>
      <div><dt className="text-xs font-semibold text-neutral-600">Address</dt><dd className="text-neutral-950 [overflow-wrap:anywhere]">{address || 'Missing'}</dd></div>
      <div><dt className="text-xs font-semibold text-neutral-600">Contact</dt><dd className="text-neutral-950 [overflow-wrap:anywhere]">{[step.data.phone, step.data.email].filter(Boolean).join(' · ') || 'Missing'}</dd></div>
    </dl>
  );
  if (fields.length === 0) return <>{summary}<EmployerFilingSettings initialKind={step.data.kind_of_employer} companyId={checklist.company.id} onSaved={onSaved} /></>;

  const editableFields = fields.filter((field) => editable?.includes(field));
  const lockedFields = editable ? fields.filter((field) => !editable.includes(field)) : [];

  async function save() {
    setSaving(true);
    setError(null);
    try {
      const changes = Object.fromEntries(editableFields.map((field) => [field, values[field].trim()]));
      await companiesApi.update(checklist.company.id, changes, checklist.company.id);
      if (!stillMounted()) return;
      await onSaved('Saved the employer details.');
    } catch (err) {
      if (stillMounted()) setError(err instanceof Error ? err.message : 'Could not save the employer details.');
    } finally {
      if (stillMounted()) setSaving(false);
    }
  }

  return (
    <div className="space-y-4">
      <IssueList issues={step.issues} />
      <EmployerFilingSettings initialKind={step.data.kind_of_employer} companyId={checklist.company.id} onSaved={onSaved} />
      {permissionError ? (
        <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50/40 p-3">
          <p className="text-sm text-danger-800">Could not check which employer details you can edit. Check your connection and try again.</p>
          <Button size="sm" variant="outline" className="mt-2" onClick={() => setLookupAttempt((attempt) => attempt + 1)}>Try again</Button>
        </div>
      ) : editable === null ? (
        <p className="text-sm text-neutral-600" role="status">Checking what you can edit…</p>
      ) : (
        <>
          {editableFields.length > 0 && (
            <form
              className="space-y-4"
              onSubmit={(event) => { event.preventDefault(); void save(); }}
            >
              <div className="grid gap-3 sm:grid-cols-2">
                {editableFields.map((field) => (
                  <Input
                    key={field}
                    label={LABELS[field]}
                    value={values[field]}
                    onChange={(event) => setValues((current) => ({ ...current, [field]: event.target.value }))}
                    required={field !== 'address_line2'}
                    type={field === 'email' ? 'email' : field === 'phone' ? 'tel' : 'text'}
                    inputMode={field === 'ein' || field === 'zip' ? 'numeric' : undefined}
                    placeholder={field === 'ein' ? '12-3456789' : field === 'state' ? 'GU' : undefined}
                    autoComplete="off"
                    disabled={saving}
                  />
                ))}
              </div>
              {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
              <Button type="submit" loading={saving} loadingLabel="Saving…">Save employer details</Button>
            </form>
          )}
          {lockedFields.length > 0 && (
            <p className="text-sm text-neutral-700">
              {lockedFields.includes('ein') ? 'A manager or admin adds the EIN' : 'A manager or admin updates these details'} in{' '}
              <Link to="/settings/clients" className="font-semibold text-primary-700 underline">Client Management</Link>.
            </p>
          )}
        </>
      )}
    </div>
  );
}
