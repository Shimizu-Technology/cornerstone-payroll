import { useRef, useState } from 'react';
import { companiesApi } from '@/services/api';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';

const kinds: Record<string, string> = {
  N: 'None apply',
  F: 'Federal government',
  S: 'State/local non-501c',
  T: '501c non-government',
  Y: 'State/local 501c',
};
const codes: Record<string, string> = {
  R: 'Regular — Form 941',
  A: 'Agriculture — Form 943',
  M: 'Military',
  F: 'Regular — Form 944',
};
export function EmployerFilingSettings({
  companyId,
  initialKind = 'N',
  onSaved,
}: {
  companyId: number;
  initialKind?: string;
  onSaved: (message: string) => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState(initialKind);
  const [code, setCode] = useState('R');
  const [establishment, setEstablishment] = useState('');
  const [contact, setContact] = useState({
    filing_contact_name: '',
    phone: '',
    email: '',
  });
  const [editable, setEditable] = useState<string[]>([]);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const savingRef = useRef(false);
  // One lookup at a time, and none while the form is open, so a late
  // response can never replace something the user already typed.
  const [loading, setLoading] = useState(false);
  const loadingRef = useRef(false);
  async function edit() {
    if (loadingRef.current || open) return;
    loadingRef.current = true;
    setLoading(true);
    setError('');
    try {
      const r = await companiesApi.get(companyId, companyId);
      const c = r.company as typeof r.company & {
        kind_of_employer: string;
        employment_code: string;
        establishment_number: string;
      };
      setEditable(c.editable_fields ?? []);
      setContact({
        filing_contact_name:
          (c as typeof c & { filing_contact_name: string })
            .filing_contact_name ?? '',
        phone: c.phone ?? '',
        email: c.email ?? '',
      });
      setKind(c.kind_of_employer);
      setCode(c.employment_code);
      setEstablishment(c.establishment_number ?? '');
      setOpen(true);
    } catch {
      setError('Could not load filing settings.');
    } finally {
      loadingRef.current = false;
      setLoading(false);
    }
  }
  async function save() {
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    setError('');
    try {
      await companiesApi.update(
        companyId,
        Object.fromEntries(
          Object.entries({
            ...contact,
            kind_of_employer: kind,
            employment_code: code,
            establishment_number: establishment,
          }).filter(([field]) => editable.includes(field)),
        ),
        companyId,
      );
      await onSaved('Filing settings saved.');
      setOpen(false);
    } catch (e) {
      setError(
        e instanceof Error ? e.message : 'Could not save filing settings.',
      );
    } finally {
      savingRef.current = false;
      setSaving(false);
    }
  }
  return (
    <div className="mt-4 space-y-3 border-t border-neutral-200 pt-3">
      <p className="text-sm">
        Kind of employer: {kinds[kind]}{' '}
        <Button variant="ghost" size="sm" disabled={saving || loading || open} onClick={() => void edit()}>
          {loading ? 'Loading…' : 'Change'}
        </Button>
      </p>
      {open && (
        <form
          className="space-y-3"
          onChange={() => setError('')}
          onSubmit={(e) => {
            e.preventDefault();
            void save();
          }}
        >
          <Select
            label="Kind of employer"
            disabled={saving || !editable.includes('kind_of_employer')}
            value={kind}
            onChange={(e) => setKind(e.target.value)}
          >
            {Object.entries(kinds).map(([v, label]) => (
              <option key={v} value={v}>
                {label}
              </option>
            ))}
          </Select>
          <p className="text-xs text-neutral-600">Most private businesses: None apply.</p>
          <Select
            label="Employment code"
            disabled={saving || !editable.includes('employment_code')}
            value={code}
            onChange={(e) => setCode(e.target.value)}
          >
            {Object.entries(codes).map(([v, label]) => (
              <option key={v} value={v}>
                {label}
              </option>
            ))}
          </Select>
          <p className="text-xs text-neutral-600">Most Guam businesses: Regular (Form 941).</p>
          <Input
            label="Establishment number (optional)"
            disabled={saving || !editable.includes('establishment_number')}
            maxLength={4}
            value={establishment}
            onChange={(e) => setEstablishment(e.target.value)}
          />
          <p className="text-xs text-neutral-600">Leave blank unless separate locations file under this EIN.</p>
          {Object.entries({
            filing_contact_name: 'Employer filing contact name',
            phone: 'Employer contact phone',
            email: 'Employer contact email',
          }).map(([key, label]) => (
            <Input
              key={key}
              label={label}
              disabled={saving || !editable.includes(key)}
              value={contact[key as keyof typeof contact]}
              onChange={(e) =>
                setContact({ ...contact, [key]: e.target.value })
              }
            />
          ))}
          <Button type="submit" disabled={saving || editable.length === 0}>
            {saving ? 'Saving…' : 'Save filing settings'}
          </Button>
        </form>
      )}
      {error && (
        <p role="alert" className="text-danger-700">
          {error}
        </p>
      )}
    </div>
  );
}
