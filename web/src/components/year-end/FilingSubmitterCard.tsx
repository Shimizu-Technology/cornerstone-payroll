import { useEffect, useState } from 'react';
import { filingSubmitterApi } from '@/services/api';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';

const fields: Record<string, string> = {
  ein: 'Submitter EIN',
  name: 'Practice name',
  address_line1: 'Street address',
  address_line2: 'Suite or unit (optional)',
  city: 'City',
  state: 'State / territory',
  zip: 'ZIP',
  contact_name: 'Contact name',
  contact_phone: 'Contact phone',
  contact_email: 'Contact email',
  bso_user_id: 'BSO User ID (8 characters)',
};
export function FilingSubmitterCard() {
  const [profile, setProfile] = useState<Record<string, string | null>>({});
  const [missing, setMissing] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [problems, setProblems] = useState<string[]>([]);
  const [canEdit, setCanEdit] = useState(false);
  const [open, setOpen] = useState(false);
  const [error, setError] = useState('');
  const [saved, setSaved] = useState(false);
  useEffect(() => {
    let active = true;
    void filingSubmitterApi
      .get()
      .then((r) => {
        if (active) {
          setLoading(false);
          setProblems(r.problems ?? []);
          setProfile(r.profile);
          setMissing(r.missing_fields);
          setCanEdit(r.can_edit);
        }
      })
      .catch(() => {
        if (active) { setLoading(false); setError('Could not load Cornerstone’s e-file details.'); }
      });
    return () => {
      active = false;
    };
  }, []);
  async function save() {
    setError('');
    setSaved(false);
    try {
      await filingSubmitterApi.update(profile);
      const r = await filingSubmitterApi.get();
      setMissing(r.missing_fields);
      setProblems(r.problems ?? []);
      setSaved(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save.');
    }
  }
  return (
    <section
      id="filing-submitter"
      className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm">
          Cornerstone's e-file details
        </p>
        <Button disabled={loading || !!error && !Object.keys(profile).length} variant="outline" onClick={() => setOpen(!open)}>
          {open ? 'Close' : 'View submitter profile'}
        </Button>
      </div>
      <p className="text-sm text-neutral-600">Used in every client's W-2 e-file. The BSO User ID is your SSA login ID, not a password.</p>
      {loading && <p role="status">Loading e-file details…</p>}
      {!loading && (missing.length > 0 || problems.length > 0) && <ul className="list-disc pl-5 text-sm">
        {missing.map((key) => <li key={key}>Add {fields[key] ?? key}.</li>)}
        {problems.filter((problem) => !problem.startsWith('Add ')).map((problem) => <li key={problem}>{problem}</li>)}
      </ul>}
      {open && (
        <form
          className="space-y-3"
          onSubmit={(e) => {
            e.preventDefault();
            void save();
          }}
        >
          <div className="grid gap-3 sm:grid-cols-2">
            {Object.entries(fields).map(([key, label]) => (
              <Input
                key={key}
                label={label}
                value={profile[key] ?? ''}
                disabled={!canEdit}
                onChange={(e) =>
                  setProfile({ ...profile, [key]: e.target.value })
                }
              />
            ))}
          </div>
          {canEdit ? (
            <Button type="submit">Save submitter profile</Button>
          ) : (
            <p className="text-sm">
              An organization admin can edit this profile.
            </p>
          )}
          {saved && <p role="status">Submitter profile saved.</p>}
        </form>
      )}
      {error && (
        <p role="alert" className="text-danger-700">
          {error}
        </p>
      )}
    </section>
  );
}
