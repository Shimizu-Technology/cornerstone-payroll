import { useState } from 'react';
import { companiesApi } from '@/services/api';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';

const kinds: Record<string, string> = {
  N: 'None apply (most private businesses)',
  F: 'Federal government',
  S: 'State/local non-501c',
  T: '501c non-government',
  Y: 'State/local 501c',
};
const codes: Record<string, string> = {
  R: 'Regular — Form 941',
  A: 'Agriculture — Form 943',
  H: 'Household',
  M: 'Military',
  Q: 'Medicare qualified government',
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
  async function edit() {
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
    }
  }
  async function save() {
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
    }
  }
  return (
    <div className="mt-4 space-y-3 border-t border-neutral-200 pt-3">
      <p className="text-sm">
        Kind of employer: {kinds[kind]}{' '}
        <Button variant="ghost" size="sm" onClick={() => void edit()}>
          Change
        </Button>
      </p>
      {open && (
        <form
          className="space-y-3"
          onSubmit={(e) => {
            e.preventDefault();
            void save();
          }}
        >
          <Select
            label="Kind of employer"
            disabled={!editable.includes('kind_of_employer')}
            value={kind}
            onChange={(e) => setKind(e.target.value)}
          >
            {Object.entries(kinds).map(([v, label]) => (
              <option key={v} value={v}>
                {label}
              </option>
            ))}
          </Select>
          <Select
            label="Employment code"
            disabled={!editable.includes('employment_code')}
            value={code}
            onChange={(e) => setCode(e.target.value)}
          >
            {Object.entries(codes).map(([v, label]) => (
              <option key={v} value={v}>
                {label}
              </option>
            ))}
          </Select>
          <Input
            label="Establishment number (optional)"
            disabled={!editable.includes('establishment_number')}
            maxLength={4}
            value={establishment}
            onChange={(e) => setEstablishment(e.target.value)}
          />
          {Object.entries({
            filing_contact_name: 'Employer filing contact name',
            phone: 'Employer contact phone',
            email: 'Employer contact email',
          }).map(([key, label]) => (
            <Input
              key={key}
              label={label}
              disabled={!editable.includes(key)}
              value={contact[key as keyof typeof contact]}
              onChange={(e) =>
                setContact({ ...contact, [key]: e.target.value })
              }
            />
          ))}
          <Button type="submit" disabled={editable.length === 0}>
            Save filing settings
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
