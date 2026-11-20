import { useEffect, useRef, useState } from 'react';
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
  tcc: 'Transmitter control code (TCC, 5 characters, optional)',
  bso_user_id: 'BSO User ID (8 characters)',
};
export function FilingSubmitterCard() {
  const [attempt, setAttempt] = useState(0);
  const [exists, setExists] = useState(true);
  const [restricted, setRestricted] = useState(false);
  const [loadFailed, setLoadFailed] = useState(false);
  const [profile, setProfile] = useState<Record<string, string | null>>({});
  const [missing, setMissing] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [problems, setProblems] = useState<string[]>([]);
  const [canEdit, setCanEdit] = useState(false);
  const [open, setOpen] = useState(false);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const savingRef = useRef(false);
  const [saved, setSaved] = useState(false);
  useEffect(() => {
    let active = true;
    setLoading(true);
    setError('');
    setLoadFailed(false);
    setRestricted(false);
    void filingSubmitterApi
      .get()
      .then((r) => {
        if (active) {
          setLoading(false);
          setExists(r.exists !== false);
          setProblems(r.problems ?? []);
          setProfile(r.profile);
          setMissing(r.missing_fields);
          setCanEdit(r.can_edit);
        }
      })
      .catch((failure: unknown) => {
        if (active) {
          setLoading(false);
          if (failure && typeof failure === 'object' && 'status' in failure && failure.status === 403) {
            setRestricted(true);
          } else {
            setLoadFailed(true);
            setError('Could not load Cornerstone’s e-file details.');
          }
        }
      });
    return () => {
      active = false;
    };
  }, [attempt]);
  async function save() {
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    setError('');
    setSaved(false);
    try {
      await filingSubmitterApi.update(profile);
      const r = await filingSubmitterApi.get();
      setExists(r.exists !== false);
      setMissing(r.missing_fields);
      setProblems(r.problems ?? []);
      setSaved(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save.');
    } finally {
      savingRef.current = false;
      setSaving(false);
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
        <Button disabled={saving || loading || restricted || loadFailed} variant="outline" onClick={() => setOpen(!open)}>
          {open ? 'Close' : 'View submitter profile'}
        </Button>
      </div>
      <p className="text-sm text-neutral-600">Used in every client's W-2 and 1099 e-files. The BSO User ID is your SSA login ID, not a password.</p>
      {!loading && !restricted && !loadFailed && !profile.tcc && <p className="text-sm text-neutral-600">Add the transmitter control code (TCC) DRT gave Cornerstone, or confirm with DRT that none is needed</p>}
      {loading && <p role="status">Loading e-file details…</p>}
      {!loading && restricted && <p className="text-sm text-neutral-600">Ask an admin to complete Cornerstone's e-file details.</p>}
      {!loading && !restricted && !loadFailed && !exists && <p className="text-sm text-neutral-600">Not set up yet — add Cornerstone's e-file details</p>}
      {!loading && !restricted && !loadFailed && exists && missing.length === 0 && problems.length === 0 && <p className="text-sm text-neutral-600">E-file details complete.</p>}
      {!loading && !restricted && !loadFailed && exists && (missing.length > 0 || problems.length > 0) && <ul className="list-disc pl-5 text-sm">
        {missing.map((key) => <li key={key}>Add {fields[key] ?? key}.</li>)}
        {problems.filter((problem) => !problem.startsWith('Add ')).map((problem) => <li key={problem}>{problem}</li>)}
      </ul>}
      {open && !restricted && !loadFailed && (
        <form
          className="space-y-3"
          onChange={() => { setSaved(false); setError(''); }}
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
                disabled={saving || !canEdit}
                onChange={(e) =>
                  setProfile({ ...profile, [key]: e.target.value })
                }
              />
            ))}
          </div>
          {canEdit ? (
            <Button type="submit" disabled={saving}>{saving ? 'Saving…' : 'Save submitter profile'}</Button>
          ) : (
            <p className="text-sm">
              An organization admin can edit this profile.
            </p>
          )}
          {saved && <p role="status">Submitter profile saved.</p>}
        </form>
      )}
      {loadFailed && <Button variant="outline" onClick={() => setAttempt((value) => value + 1)}>Try again</Button>}
      {error && (
        <p role="alert" className="text-danger-700">
          {error}
        </p>
      )}
    </section>
  );
}
