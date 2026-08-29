import { useCallback, useEffect, useState } from 'react';
import { AlertTriangle, Pencil, Plus, Printer, Save, Trash2 } from 'lucide-react';
import { SettingsSection } from '@/components/settings/SettingsSection';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { printerProfilesApi, type PrinterProfile } from '@/services/api';
import type { CheckStockType } from '@/types';

interface ProfileDraft {
  name: string;
  description: string;
  notes: string;
  check_stock_type: CheckStockType;
  check_offset_x: number;
  check_offset_y: number;
  check_layout_json: string;
  is_default: boolean;
}

const emptyDraft: ProfileDraft = {
  name: '',
  description: '',
  notes: '',
  check_stock_type: 'top_check',
  check_offset_x: 0,
  check_offset_y: 0,
  check_layout_json: '{}',
  is_default: false,
};

function draftFromProfile(profile: PrinterProfile): ProfileDraft {
  return {
    name: profile.name,
    description: profile.description || '',
    notes: profile.notes || '',
    check_stock_type: profile.check_stock_type,
    check_offset_x: Number(profile.check_offset_x),
    check_offset_y: Number(profile.check_offset_y),
    check_layout_json: JSON.stringify(profile.check_layout_config || {}, null, 2),
    is_default: profile.is_default,
  };
}

function profilePayload(draft: ProfileDraft) {
  if (!draft.name.trim()) throw new Error('Profile name is required.');
  const parsed = JSON.parse(draft.check_layout_json || '{}');
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Layout configuration must be a JSON object.');
  }
  return {
    name: draft.name.trim(),
    description: draft.description.trim() || null,
    notes: draft.notes.trim() || null,
    check_stock_type: draft.check_stock_type,
    check_offset_x: draft.check_offset_x,
    check_offset_y: draft.check_offset_y,
    check_layout_config: parsed as Record<string, unknown>,
    is_default: draft.is_default,
  };
}

export function FirmPrinterProfiles() {
  const [profiles, setProfiles] = useState<PrinterProfile[]>([]);
  const [editingId, setEditingId] = useState<number | 'new' | null>(null);
  const [draft, setDraft] = useState<ProfileDraft>(emptyDraft);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [applyingId, setApplyingId] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const response = await printerProfilesApi.list();
      setProfiles(response.printer_profiles);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load printer profiles');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const beginCreate = () => {
    setDraft(emptyDraft);
    setEditingId('new');
    setError(null);
    setSuccess(null);
  };

  const beginEdit = (profile: PrinterProfile) => {
    setDraft(draftFromProfile(profile));
    setEditingId(profile.id);
    setError(null);
    setSuccess(null);
  };

  const save = async () => {
    if (editingId == null) return;
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const payload = profilePayload(draft);
      if (editingId === 'new') {
        await printerProfilesApi.create(payload);
        setSuccess('Printer profile created for the firm.');
      } else {
        await printerProfilesApi.update(editingId, payload);
        setSuccess('Printer profile updated.');
      }
      setEditingId(null);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save printer profile');
    } finally {
      setSaving(false);
    }
  };

  const remove = async (profile: PrinterProfile) => {
    if (!window.confirm(`Delete printer profile "${profile.name}"? Clients already using it will keep their current check calibration.`)) return;
    setError(null);
    setSuccess(null);
    try {
      await printerProfilesApi.delete(profile.id);
      setSuccess('Printer profile deleted.');
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete printer profile');
    }
  };

  const applyToAll = async (profile: PrinterProfile) => {
    const confirmation = window.prompt(
      `This will replace the active check stock and calibration for every client in the firm with "${profile.name}". Type APPLY TO ALL CLIENTS to continue.`,
    );
    if (confirmation !== 'APPLY TO ALL CLIENTS') return;
    setApplyingId(profile.id);
    setError(null);
    setSuccess(null);
    try {
      const response = await printerProfilesApi.applyToAllCompanies(profile.id);
      setSuccess(`Applied "${profile.name}" to ${response.applied_count} client${response.applied_count === 1 ? '' : 's'}.`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to apply printer profile');
    } finally {
      setApplyingId(null);
    }
  };

  return (
    <SettingsSection
      eyebrow="Firm configuration"
      title="Printer profiles"
      description="Reusable office-printer calibration owned by the firm. Applying a profile to one client remains a client-settings action."
      actions={<Button onClick={beginCreate} disabled={editingId === 'new'}><Plus className="mr-2 h-4 w-4" />New profile</Button>}
    >
      {error && <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800">{error}</div>}
      {success && <div role="status" className="rounded-xl border border-success-200 bg-success-50 px-4 py-3 text-sm text-success-800">{success}</div>}

      {editingId === 'new' && (
        <ProfileEditor draft={draft} onChange={setDraft} onSave={save} onCancel={() => setEditingId(null)} saving={saving} title="Create printer profile" />
      )}

      {loading ? (
        <div className="rounded-[1.35rem] border border-neutral-200 bg-white p-10 text-center text-sm text-neutral-500">Loading printer profiles…</div>
      ) : profiles.length === 0 && editingId !== 'new' ? (
        <Card><CardContent className="py-10 text-center"><Printer className="mx-auto h-8 w-8 text-neutral-300" /><p className="mt-3 font-semibold text-neutral-900">No firm printer profiles yet</p><p className="mt-1 text-sm text-neutral-500">Create one when a physical printer needs reusable alignment across clients.</p></CardContent></Card>
      ) : (
        <div className="space-y-3">
          {profiles.map((profile) => editingId === profile.id ? (
            <ProfileEditor key={profile.id} draft={draft} onChange={setDraft} onSave={save} onCancel={() => setEditingId(null)} saving={saving} title={`Edit ${profile.name}`} />
          ) : (
            <Card key={profile.id}>
              <CardContent className="flex flex-col gap-5 py-5 lg:flex-row lg:items-start lg:justify-between">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-semibold text-neutral-950">{profile.name}</h3>
                    {profile.is_default && <span className="rounded-full bg-primary-50 px-2.5 py-1 text-[11px] font-bold uppercase tracking-[0.1em] text-primary-700">Firm default</span>}
                  </div>
                  {profile.description && <p className="mt-1 text-sm text-neutral-600">{profile.description}</p>}
                  <p className="mt-2 font-mono text-xs text-neutral-500">{profile.check_stock_type.replaceAll('_', ' ')} · X {Number(profile.check_offset_x).toFixed(3)} · Y {Number(profile.check_offset_y).toFixed(3)}</p>
                  {profile.notes && <p className="mt-3 whitespace-pre-wrap rounded-xl border border-warning-100 bg-warning-50/60 px-3 py-2 text-xs leading-5 text-warning-900">{profile.notes}</p>}
                </div>
                <div className="flex shrink-0 flex-wrap gap-2">
                  <Button variant="outline" size="sm" onClick={() => beginEdit(profile)}><Pencil className="mr-1.5 h-4 w-4" />Edit</Button>
                  <Button variant="outline" size="sm" onClick={() => void applyToAll(profile)} disabled={applyingId === profile.id}>{applyingId === profile.id ? 'Applying…' : 'Apply to all clients'}</Button>
                  <Button variant="ghost" size="sm" className="text-danger-700 hover:text-danger-800" onClick={() => void remove(profile)}><Trash2 className="mr-1.5 h-4 w-4" />Delete</Button>
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      <div className="flex items-start gap-3 rounded-2xl border border-warning-200 bg-warning-50/55 px-4 py-3 text-sm text-warning-950">
        <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-warning-700" />
        <p><strong>Apply to all clients</strong> is intentionally a firm-admin action with typed confirmation. Routine client calibration should use Client Settings → Checks & printing.</p>
      </div>
    </SettingsSection>
  );
}

function ProfileEditor({ draft, onChange, onSave, onCancel, saving, title }: {
  draft: ProfileDraft;
  onChange: (draft: ProfileDraft) => void;
  onSave: () => void;
  onCancel: () => void;
  saving: boolean;
  title: string;
}) {
  const update = <K extends keyof ProfileDraft>(field: K, value: ProfileDraft[K]) => onChange({ ...draft, [field]: value });
  return (
    <Card className="border-primary-200">
      <CardContent className="space-y-5 py-6">
        <div><h3 className="font-semibold text-neutral-950">{title}</h3><p className="mt-1 text-sm text-neutral-500">Profiles store physical printer alignment only; client bank text and payroll automation stay client-specific.</p></div>
        <div className="grid gap-4 md:grid-cols-2">
          <Field label="Profile name" value={draft.name} onChange={(value) => update('name', value)} />
          <Field label="Description" value={draft.description} onChange={(value) => update('description', value)} />
          <label className="block text-sm font-semibold text-neutral-700">Check stock<Select className="mt-1.5" value={draft.check_stock_type} onChange={(event) => update('check_stock_type', event.target.value as CheckStockType)}><option value="top_check">Top check</option><option value="bottom_check">Bottom check</option><option value="first_hawaiian_4up">First Hawaiian 4-Up</option></Select></label>
          <label className="flex items-center gap-3 self-end rounded-xl border border-neutral-200 px-3 py-2.5 text-sm font-semibold text-neutral-700"><input type="checkbox" checked={draft.is_default} onChange={(event) => update('is_default', event.target.checked)} />Use as the firm default</label>
          <label className="block text-sm font-semibold text-neutral-700">X offset (inches)<NumericInput className="mt-1.5 font-mono" value={draft.check_offset_x} onValueChange={(value) => update('check_offset_x', value || 0)} fixedDecimalsOnBlur={3} /></label>
          <label className="block text-sm font-semibold text-neutral-700">Y offset (inches)<NumericInput className="mt-1.5 font-mono" value={draft.check_offset_y} onValueChange={(value) => update('check_offset_y', value || 0)} fixedDecimalsOnBlur={3} /></label>
        </div>
        <label className="block text-sm font-semibold text-neutral-700">Print instructions<Textarea className="mt-1.5 min-h-20" value={draft.notes} onChange={(event) => update('notes', event.target.value)} /></label>
        <details className="rounded-xl border border-neutral-200 bg-neutral-50 px-4 py-3"><summary className="cursor-pointer text-sm font-semibold text-neutral-800">Advanced layout JSON</summary><Textarea className="mt-3 min-h-52 font-mono text-xs" value={draft.check_layout_json} onChange={(event) => update('check_layout_json', event.target.value)} spellCheck={false} /></details>
        <div className="flex justify-end gap-2"><Button variant="outline" onClick={onCancel}>Cancel</Button><Button onClick={onSave} disabled={saving}><Save className="mr-2 h-4 w-4" />{saving ? 'Saving…' : 'Save profile'}</Button></div>
      </CardContent>
    </Card>
  );
}

function Field({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return <label className="block text-sm font-semibold text-neutral-700">{label}<Input className="mt-1.5" value={value} onChange={(event) => onChange(event.target.value)} /></label>;
}
