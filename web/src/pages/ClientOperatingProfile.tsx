import { formatDate, formatDateRange } from '@/lib/display-date';
import { useEffect, useId, useState, type FormEvent } from 'react';
import { Info, LockKeyhole } from 'lucide-react';
import { useParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { Alert } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { ApiError } from '@/services/api';
import {
  operatingProfileApi, type CatalogEntry, type OperatingProfileResponse, type SettingValue, type Settings,
} from '@/services/operating-profile';

const sectionLabels: Record<string, string> = {
  core: 'Payroll setup',
  intake: 'Payroll intake',
  client_portal: 'Client portal',
  year_end: 'Year-end filing',
  employee_portal: 'Employee portal',
  platform: 'Platform features',
};

const settingValueLabels: Record<string, Record<string, string>> = {
  'client_portal.employee_lifecycle_mode': {
    approval_first: 'Cornerstone approves first',
    client_managed: 'Client manages, Cornerstone verifies',
  },
};

function settingLabel(value: string, fieldId?: string) {
  const fieldLabel = fieldId ? settingValueLabels[fieldId]?.[value] : undefined;
  if (fieldLabel) return fieldLabel;
  if (value === 'intake_adapter') return 'Upload payroll files';
  return value.replaceAll('_', ' ').replace(/^./, (letter) => letter.toUpperCase());
}

function draftFor(data: OperatingProfileResponse): Settings {
  const version = data.history[0] ?? data.effective;
  return Object.fromEntries(data.catalog.map((field) => {
    const value: unknown = field.storage === 'column'
      ? version[field.id as keyof typeof version]
      : field.id.split('.').reduce<unknown>((node, key) => (node as Record<string, unknown> | null)?.[key], version.options);
    return [field.id, (value === undefined ? field.default : value) as SettingValue];
  }));
}

function readValue(field: CatalogEntry, draft: SettingValue): SettingValue {
  if (typeof draft !== 'string') return draft;
  if (field.type === 'nullable_string_array') return commaSeparatedItems(draft);
  if (field.type === 'uploaders' && draft !== 'all_client_users') {
    const items = commaSeparatedItems(draft);
    return items.length ? items.map(Number) : 'all_client_users';
  }
  return draft;
}

function commaSeparatedItems(value: string) {
  return value.split(',').map((item) => item.trim()).filter(Boolean);
}

function Help({ field }: { field: CatalogEntry }) {
  const id = useId();
  return (
    <>
      <button
        type="button"
        aria-label={`Help for ${field.label}`}
        popoverTarget={id}
        className="inline-flex size-11 shrink-0 items-center justify-center rounded-full text-neutral-600 hover:bg-neutral-100 focus-visible:ring-2 focus-visible:ring-primary-500"
      >
        <Info aria-hidden="true" size={17} />
      </button>
      <div
        id={id}
        popover="auto"
        role="dialog"
        aria-labelledby={`${id}-heading`}
        className="fixed inset-0 m-auto h-fit max-h-[80dvh] w-[calc(100%-2rem)] max-w-sm overflow-y-auto rounded-2xl border border-neutral-200 bg-white p-5 text-neutral-800 shadow-xl backdrop:bg-neutral-950/20"
      >
        <h3 id={`${id}-heading`} className="font-semibold text-neutral-950">{field.label}</h3>
        <p className="mt-2 text-sm">{field.what}</p>
        <p className="mt-2 text-sm">{field.effect}</p>
        <p className="mt-2 text-sm text-neutral-600"><strong>Example</strong> {field.example}</p>
        <Button type="button" variant="outline" className="mt-4" popoverTarget={id} popoverTargetAction="hide">Close help</Button>
      </div>
    </>
  );
}

function SettingControl({ field, value, editable, locked, onChange }: {
  field: CatalogEntry;
  value: SettingValue;
  editable: boolean;
  locked: boolean;
  onChange: (value: SettingValue) => void;
}) {
  const id = useId();
  const props = { id, className: 'min-h-11 text-base sm:text-sm', disabled: !editable };
  const text = Array.isArray(value) ? value.join(', ') : field.type === 'uploaders' && value === 'all_client_users' ? '' : String(value ?? '');
  const allowed = field.allowed;
  const sourceMode = value === null ? 'inherit' : Array.isArray(value) && !value.length ? 'single' : 'list';

  return (
    <div className="min-w-0">
      <div className="flex items-center justify-between">
        <Label htmlFor={locked ? undefined : id}>{field.id === 'intake_adapter' ? 'Payroll file format' : field.label}{field.id === 'offering' ? ' preset' : ''}</Label>
        <Help field={field} />
      </div>
      {locked ? (
        <div className="flex min-h-11 items-center gap-2 text-sm text-neutral-600">
          <LockKeyhole className="size-4 shrink-0" aria-hidden="true" />
          <span>{field.type === 'boolean' ? 'Off' : field.type === 'enum' ? settingLabel(text, field.id) : text} · Available in Milestone {field.locked_until_milestone}</span>
        </div>
      ) : field.type === 'nullable_string_array' ? (
        <div className="space-y-2">
          <Select {...props} value={sourceMode} onChange={(event) => {
            const mode = event.target.value;
            onChange(mode === 'inherit' ? null : mode === 'single' ? [] : '');
          }}>
            <option value="inherit">Use defaults for this file format</option>
            <option value="single">Allow a single file</option>
            <option value="list">Require specific source roles</option>
          </Select>
          {sourceMode === 'list' && (
            <Input label="Source roles" className={props.className} disabled={!editable} value={text} required
              pattern={String.raw`.*[^,\s].*`} helperText="Separate source roles with commas."
              onChange={(event) => onChange(event.target.value)} />
          )}
        </div>
      ) : field.type === 'boolean' ? (
        <Select {...props} value={value ? 'on' : 'off'} onChange={(event) => onChange(event.target.value === 'on')}>
          <option value="off">Off</option>
          <option value="on">On</option>
        </Select>
      ) : (field.type === 'enum' || field.type === 'nullable_enum') && Array.isArray(allowed) ? (
        <Select {...props} value={text} onChange={(event) => onChange(event.target.value || null)}>
          {field.type === 'nullable_enum' && <option value="">None</option>}
          {allowed.map((option) => <option key={String(option)} value={String(option)}>{settingLabel(String(option), field.id)}</option>)}
        </Select>
      ) : (
        <Input {...props} value={text} type={field.type === 'integer' ? 'number' : 'text'}
          min={allowed && 'min' in allowed ? allowed.min : undefined}
          max={allowed && 'max' in allowed ? allowed.max : undefined}
          required={field.type === 'integer'}
          pattern={field.type === 'uploaders' ? '([ ]*([1-9][0-9]*)?[ ]*,)*[ ]*([1-9][0-9]*)?[ ]*' : undefined}
          helperText={field.type === 'uploaders' ? 'Comma-separated user IDs. Blank allows all client users.' : undefined}
          onChange={(event) => {
            const input = event.target.value;
            onChange(field.type === 'integer' && input ? event.target.valueAsNumber : (field.type === 'uploaders' || field.type === 'integer') ? input : input || null);
          }}
        />
      )}
    </div>
  );
}

function readinessWarnings(values: Settings, connectedSourceActive: boolean) {
  const warnings: string[] = [];
  if (values.offering === 'workforce_suite' && values.hours_source !== 'connected_app') {
    warnings.push('Workforce suite expects a connected app as the hours source.');
  }
  if ((values.offering === 'workforce_suite' || values.hours_source === 'connected_app') && !connectedSourceActive) {
    warnings.push('This client has no active connected time source.');
  }
  if (values.offering === 'payroll_portals' && !values.client_portal_enabled) {
    warnings.push('Payroll portals is selected with the client portal off.');
  }
  if (values.hours_source === 'intake_adapter' && !values.intake_adapter) {
    warnings.push('Choose a payroll file format for this hours source.');
  }
  return warnings;
}

function ProfileForm({ data, companyId, reload }: { data: OperatingProfileResponse; companyId: number; reload: () => void }) {
  const [profile, setProfile] = useState(data);
  const baseline = draftFor(profile);
  const [draft, setDraft] = useState(() => draftFor(data));
  const [effectiveOn, setEffectiveOn] = useState('');
  const [reason, setReason] = useState('');
  const reasonId = useId();
  const dateHelpId = useId();
  const [presetNote, setPresetNote] = useState('');
  const [saved, setSaved] = useState('');
  const [error, setError] = useState<{ message: string; stale: boolean } | null>(null);
  const [saving, setSaving] = useState(false);
  const editable = (id: string) => profile.editable_keys.includes(id) && !profile.locked_keys.includes(id);
  const changes: Settings = {};
  for (const field of profile.catalog) {
    const value = readValue(field, draft[field.id]);
    if (editable(field.id) && JSON.stringify(value) !== JSON.stringify(baseline[field.id])) changes[field.id] = value;
  }
  const warnings = readinessWarnings(draft, profile.connected_source_active);
  const sectionOrder = [...new Set([...Object.keys(sectionLabels), ...profile.catalog.map((field) => field.section)])];
  const sections = sectionOrder.map((section) => ({
    id: section,
    fields: profile.catalog.filter((field) => field.section === section),
  })).filter((section) => section.fields.length > 0);
  const hasEdits = profile.catalog.some((field) => editable(field.id));
  const earliestDate = profile.available_effective_dates[0];
  const latest = profile.history[0];
  const correctionDate = latest?.version > 1 && latest.effective_on > profile.as_of ? latest.effective_on : null;

  function changeSetting(field: CatalogEntry, value: SettingValue) {
    setSaved('');
    if (field.id !== 'offering' || typeof value !== 'string') {
      const next = { ...draft, [field.id]: value };
      if (field.id === 'hours_source' && value !== 'intake_adapter' && editable('intake_adapter')) next.intake_adapter = null;
      if (next.intake_adapter !== draft.intake_adapter && editable('intake.required_sources')) next['intake.required_sources'] = null;
      setDraft(next);
      return;
    }

    const preset = profile.offering_presets[value] ?? {};
    const next: Settings = { ...draft, offering: value };
    const skipped: string[] = [];
    for (const [key, presetValue] of Object.entries(preset)) {
      if (editable(key)) next[key] = presetValue;
      else if (draft[key] !== presetValue) skipped.push(profile.catalog.find((item) => item.id === key)?.label ?? key);
    }
    if (next.intake_adapter !== draft.intake_adapter && editable('intake.required_sources')) next['intake.required_sources'] = null;
    setDraft(next);
    setPresetNote(skipped.length ? `Preset applied. Kept ${skipped.join(', ')} because your access does not allow those changes.` : 'Preset applied to your draft.');
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving || error?.stale || !profile.available_effective_dates.includes(effectiveOn) || !Object.keys(changes).length) return;
    setSaving(true);
    setError(null);
    try {
      const response = await operatingProfileApi.update(companyId, {
        effective_on: effectiveOn, reason: reason.trim(), lock_version: profile.lock_version, changes,
      });
      setProfile(response);
      setDraft(draftFor(response));
      setSaved(`Version ${response.saved.version} ${effectiveOn === correctionDate ? 'corrected' : 'saved'}, effective ${formatDate(response.saved.effective_on)}.`);
      setEffectiveOn('');
      setReason('');
      setPresetNote('');
    } catch (problem) {
      setError({ message: problem instanceof Error ? problem.message : 'The operating profile could not be saved.', stale: problem instanceof ApiError && problem.status === 409 });
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <Header title="How this client runs" mobileSticky={false}
        description="Configure this client’s payroll workflow, portal access, and filing defaults." />
      <div className="mx-auto max-w-5xl space-y-5 p-4 sm:p-6 lg:p-8">
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant="info">{profile.effective.persisted ? `Active version ${profile.effective.version}` : 'Default payroll settings'}</Badge>
          {(profile.history[0]?.effective_on ?? '') > profile.as_of && <Badge variant="outline">Editing scheduled version {profile.history[0].version}</Badge>}
        </div>
        {!hasEdits && <Alert tone="info">You have read-only access to this operating profile.</Alert>}
        <Card>
          <CardHeader><CardTitle>Readiness</CardTitle></CardHeader>
          <CardContent aria-live="polite">
            {warnings.length > 0
              ? <ul className="list-disc space-y-1 pl-5 text-sm text-neutral-700">{warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul>
              : <p className="text-sm text-neutral-600">No configuration gaps detected.</p>}
          </CardContent>
        </Card>
        <form className="space-y-5" onSubmit={save}>
          <fieldset disabled={saving} className="min-w-0 space-y-5">
            {sections.map(({ id, fields }) => (
              <Card key={id}>
                <CardHeader><CardTitle>{sectionLabels[id] ?? settingLabel(id)}</CardTitle></CardHeader>
                <CardContent className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
                  {fields.map((field) => (
                    <div key={field.id} className="min-w-0">
                      <SettingControl field={field} value={draft[field.id]} editable={editable(field.id)}
                        locked={profile.locked_keys.includes(field.id)} onChange={(value) => changeSetting(field, value)} />
                      {field.id === 'offering' && presetNote && <p role="status" className="mt-2 text-sm text-neutral-600">{presetNote}</p>}
                    </div>
                  ))}
                </CardContent>
              </Card>
            ))}
            {hasEdits && (
              <Card>
                <CardHeader><CardTitle>Save operating profile</CardTitle></CardHeader>
                <CardContent className="space-y-4">
                  <Select label="Effective date" required value={effectiveOn} className="min-h-11 text-base sm:max-w-xs sm:text-sm"
                    disabled={!earliestDate} aria-describedby={dateHelpId}
                    placeholder="Select a draft pay period" onChange={(event) => setEffectiveOn(event.target.value)}>
                    {profile.available_effective_dates.map((date) => (
                      <option key={date} value={date}>{date}{date === correctionDate ? ' (correct scheduled version)' : ''}</option>
                    ))}
                  </Select>
                  <p id={dateHelpId} className="text-sm text-neutral-600">
                    {earliestDate ? `Earliest available draft period starts ${formatDate(earliestDate)}.` : 'No draft pay periods are available for a profile change.'}
                  </p>
                  <div className="space-y-1.5">
                    <Label htmlFor={reasonId}>Reason for change</Label>
                    <Textarea id={reasonId} required value={reason} onChange={(event) => setReason(event.target.value)} />
                  </div>
                  {error && <Alert tone="error" role="alert">{error.message}</Alert>}
                  {saved && <Alert tone="success" role="status">{saved}</Alert>}
                  {error?.stale
                    ? <Button type="button" variant="outline" onClick={reload}>Reload and discard draft</Button>
                    : <Button type="submit" className="w-full sm:w-auto" disabled={saving || !reason.trim() || !effectiveOn || !Object.keys(changes).length}>
                      {saving ? 'Saving…' : 'Save operating profile'}
                    </Button>}
                </CardContent>
              </Card>
            )}
          </fieldset>
        </form>
        {profile.history.length > 0 && (
          <Card>
            <CardHeader><CardTitle>Version history</CardTitle></CardHeader>
            <CardContent>
              <ol className="divide-y divide-neutral-200">
                {profile.history.map((version) => (
                  <li key={version.version} className="py-3 first:pt-0 last:pb-0">
                    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                      <strong className="text-sm text-neutral-950">Version {version.version}</strong>
                      <span className="text-sm text-neutral-600">{version.ends_on ? formatDateRange(version.effective_on, version.ends_on) : `${formatDate(version.effective_on)} onwards`}</span>
                    </div>
                    {version.reason && <p className="mt-1 break-words text-sm text-neutral-700">{version.reason}</p>}
                  </li>
                ))}
              </ol>
            </CardContent>
          </Card>
        )}
      </div>
    </>
  );
}

function ProfileLoader({ companyId }: { companyId: number }) {
  const [attempt, setAttempt] = useState(0);
  const [result, setResult] = useState<{ data: OperatingProfileResponse } | { error: string } | null>(null);
  function reload() {
    setResult(null);
    setAttempt((current) => current + 1);
  }

  useEffect(() => {
    const controller = new AbortController();
    operatingProfileApi.get(companyId, controller.signal).then(
      (data) => { if (!controller.signal.aborted) setResult({ data }); },
      (problem: unknown) => {
        if (!controller.signal.aborted) setResult({ error: problem instanceof Error ? problem.message : 'Unable to load the operating profile.' });
      },
    );
    return () => controller.abort();
  }, [companyId, attempt]);

  if (!result) return <WorkspaceLoader label="Loading operating profile" />;
  if ('error' in result) {
    return <div className="space-y-3 p-4"><Alert tone="error" role="alert">{result.error}</Alert><Button onClick={reload}>Try again</Button></div>;
  }
  return <ProfileForm data={result.data} companyId={companyId} reload={reload} />;
}

export function ClientOperatingProfile() {
  const { companyId } = useParams();
  return <ProfileLoader key={companyId} companyId={Number(companyId)} />;
}
