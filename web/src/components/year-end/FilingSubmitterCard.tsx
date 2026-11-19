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
          setProfile(r.profile);
          setMissing(r.missing_fields);
          setCanEdit(r.can_edit);
        }
      })
      .catch(() => {
        if (active) setError('Could not load the submitter profile.');
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
          {missing.length
            ? 'Submitter profile incomplete — needed for EFW2 files.'
            : 'Practice submitter profile'}
        </p>
        <Button variant="outline" onClick={() => setOpen(!open)}>
          {open ? 'Close' : 'View submitter profile'}
        </Button>
      </div>
      {open && (
        <form
          className="space-y-3"
          onSubmit={(e) => {
            e.preventDefault();
            void save();
          }}
        >
          <p className="text-sm text-neutral-600">
            Used for all clients in this practice. The BSO User ID is an
            identifier. Never enter a password.
          </p>
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
