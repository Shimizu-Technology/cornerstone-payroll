import { useCallback, useEffect, useRef, useState } from 'react';
import { KeyRound, Link2, RefreshCw, Save, ShieldCheck, Trash2, X, Zap } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { useCompany } from '@/contexts/CompanyContext';
import { timeTrackingSourcesApi } from '@/services/api';
import type { TimeTrackingSource, TimeTrackingSourceCreatePayload, TimeTrackingSourceTestResponse, TimeTrackingSourceUpdatePayload } from '@/services/api';

interface FormState {
  id?: number;
  name: string;
  source_type: TimeTrackingSource['source_type'];
  base_url: string;
  shared_secret: string;
  delegation_token: string;
  active: boolean;
}

const blankForm: FormState = {
  name: '',
  source_type: 'aire_services',
  base_url: '',
  shared_secret: '',
  delegation_token: '',
  active: false,
};

const sourceTypeOptions: Array<{ value: TimeTrackingSource['source_type']; label: string; hint: string }> = [
  { value: 'aire_services', label: 'AIRE Services Guam', hint: 'Use for the AIRE time clock.' },
  { value: 'cornerstone_tax', label: 'Cornerstone Tax', hint: 'Use for Cornerstone Tax staff time.' },
  { value: 'custom', label: 'Custom compatible source', hint: 'Use only for another app that implements the payroll time summary API.' },
];

function reconcileSavedSource(sources: TimeTrackingSource[], source: TimeTrackingSource) {
  const next = sources
    .filter((item) => item.id !== source.id)
    .map((item) => source.active ? { ...item, active: false } : item);
  next.push(source);
  return next.sort((a, b) => a.name.localeCompare(b.name));
}

function normalizeForm(source?: TimeTrackingSource): FormState {
  if (!source) return { ...blankForm };

  return {
    id: source.id,
    name: source.name,
    source_type: source.source_type,
    base_url: source.base_url,
    shared_secret: '',
    delegation_token: '',
    active: source.active,
  };
}

function summarizeTestResult(result: TimeTrackingSourceTestResponse) {
  const count = result.employee_count ?? 0;
  const source = result.source ? ` Source responded as ${result.source}.` : '';
  const cockpit = result.cockpit_ready === true
    ? ' The AIRE payroll workspace is available.'
    : result.cockpit_ready === false ? ' The AIRE payroll workspace is unavailable.' : '';
  return `${result.message || 'Connection succeeded.'} Found ${count} employee${count === 1 ? '' : 's'} for today.${source}${cockpit}`;
}

export function TimeTrackingSources() {
  const { activeCompanyId } = useCompany();
  return <ClientTimeTrackingSources key={activeCompanyId} />;
}

function ClientTimeTrackingSources() {
  const { activeCompany, activeCompanyId } = useCompany();
  const [sources, setSources] = useState<TimeTrackingSource[]>([]);
  const [form, setForm] = useState<FormState>(() => normalizeForm());
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [testingId, setTestingId] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const successTimerRef = useRef<number | null>(null);

  const loadSources = useCallback(async () => {
    if (!activeCompanyId) return;

    setLoading(true);
    setError(null);
    try {
      const res = await timeTrackingSourcesApi.list();
      const loadedSources = res.time_tracking_sources;
      setSources(loadedSources);
      setForm(normalizeForm(loadedSources.find((source) => source.active) || loadedSources[0]));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load time tracking source');
    } finally {
      setLoading(false);
    }
  }, [activeCompanyId]);

  useEffect(() => {
    loadSources();
  }, [loadSources]);

  useEffect(() => {
    return () => {
      if (successTimerRef.current) window.clearTimeout(successTimerRef.current);
    };
  }, []);

  const editing = form.id != null;
  const activeSource = sources.find((source) => source.active) || null;

  const showSuccess = (message: string) => {
    if (successTimerRef.current) window.clearTimeout(successTimerRef.current);
    setSuccess(message);
    successTimerRef.current = window.setTimeout(() => {
      setSuccess(null);
      successTimerRef.current = null;
    }, 5000);
  };

  const resetForm = () => {
    setForm(normalizeForm());
    setError(null);
  };

  const editSource = (source: TimeTrackingSource) => {
    setForm(normalizeForm(source));
    setError(null);
    setSuccess(null);
  };

  const validateForm = () => {
    if (!form.name.trim()) return 'Name is required.';
    if (!form.base_url.trim()) return 'Backend base URL is required.';
    const existingSource = form.id ? sources.find((source) => source.id === form.id) : null;
    if ((!editing || !existingSource?.shared_secret_configured) && !form.shared_secret.trim()) {
      return 'Shared secret is required before this source can be tested or used.';
    }
    try {
      const url = new URL(form.base_url.trim());
      if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password) {
        return 'Base URL must be an HTTP or HTTPS URL with a host and no embedded credentials.';
      }
    } catch {
      return 'Base URL must be a valid HTTP or HTTPS URL.';
    }
    return null;
  };

  const saveSource = async () => {
    const validationError = validateForm();
    if (validationError) {
      setError(validationError);
      return;
    }

    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const basePayload = {
        name: form.name.trim(),
        base_url: form.base_url.trim().replace(/\/+$/, ''),
        active: form.active,
      };

      if (editing && form.id) {
        const payload: TimeTrackingSourceUpdatePayload = { ...basePayload };
        if (form.shared_secret.trim()) payload.shared_secret = form.shared_secret.trim();
        if (form.source_type === 'aire_services' && form.delegation_token.trim()) {
          payload.delegation_token = form.delegation_token.trim();
        }
        const res = await timeTrackingSourcesApi.update(form.id, payload);
        const savedSource = res.time_tracking_source;
        setSources((prev) => reconcileSavedSource(prev, savedSource));
        setForm(normalizeForm(savedSource));
        showSuccess('Time tracking source updated for this client.');
      } else {
        const payload: TimeTrackingSourceCreatePayload = {
          ...basePayload,
          source_type: form.source_type,
          shared_secret: form.shared_secret.trim(),
          delegation_token: form.source_type === 'aire_services' ? form.delegation_token.trim() || undefined : undefined,
        };
        const res = await timeTrackingSourcesApi.create(payload);
        setSources((prev) => reconcileSavedSource(prev, res.time_tracking_source));
        setForm(normalizeForm(res.time_tracking_source));
        showSuccess('Time tracking source created for this client.');
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save time tracking source');
    } finally {
      setSaving(false);
    }
  };

  const removeDelegation = async () => {
    if (!form.id || !window.confirm('Remove your personal AIRE payroll access from Cornerstone? Read-only AIRE details will remain available.')) return;

    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const res = await timeTrackingSourcesApi.removeDelegation(form.id);
      setSources((prev) => reconcileSavedSource(prev, res.time_tracking_source));
      setForm((previous) => ({ ...previous, delegation_token: '' }));
      showSuccess('Your delegated AIRE payroll access was removed.');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to remove delegated access');
    } finally {
      setSaving(false);
    }
  };

  const saveDelegationOnly = async () => {
    if (!form.id || !form.delegation_token.trim()) {
      setError('Paste your AIRE delegation token first.');
      return;
    }

    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const res = await timeTrackingSourcesApi.saveDelegation(form.id, form.delegation_token.trim());
      setSources((prev) => reconcileSavedSource(prev, res.time_tracking_source));
      setForm((previous) => ({ ...previous, delegation_token: '' }));
      showSuccess('Your delegated AIRE payroll access is ready.');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save delegated access');
    } finally {
      setSaving(false);
    }
  };

  const deactivateSource = async (source: TimeTrackingSource) => {
    if (!window.confirm(`Deactivate ${source.name}? Payroll will stop using it for this client.`)) return;

    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      await timeTrackingSourcesApi.deactivate(source.id);
      await loadSources();
      resetForm();
      showSuccess('Time tracking source deactivated for this client.');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to deactivate source');
    } finally {
      setSaving(false);
    }
  };

  const testConnection = async (source: TimeTrackingSource) => {
    setTestingId(source.id);
    setError(null);
    setSuccess(null);
    try {
      const result = await timeTrackingSourcesApi.testConnection(source.id);
      showSuccess(summarizeTestResult(result));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Connection test failed. Check the backend URL, deploy status, and shared secret.');
    } finally {
      setTestingId(null);
    }
  };

  return (
    <div>
      <Header
        title="Time Tracking Source"
        description="Configure the time tracking system for the active client."
      />

      <div className="p-4 space-y-6 sm:p-6 lg:p-8">
        {error && <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error}</div>}
        {success && <div className="rounded-lg border border-green-200 bg-green-50 p-4 text-sm text-green-700">{success}</div>}

        <div className="rounded-lg border border-blue-200 bg-blue-50 p-4 text-sm text-blue-800">
          <div className="flex gap-2">
            <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0" />
            <div>
              <p className="font-medium">Active client: {activeCompany?.name || 'Loading client...'}</p>
              <p className="mt-1">Enable a source only for clients that use it. An enabled AIRE source shows AIRE import and linking actions on that client’s payroll. With no enabled source, new import and linking actions are hidden. Previously linked records remain available for review.</p>
            </div>
          </div>
        </div>

        <Card>
          <CardContent className="p-5">
            <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <h2 className="text-lg font-semibold text-gray-900">{editing ? 'Edit client source' : 'Add client source'}</h2>
                <p className="mt-1 text-sm text-gray-500">
                  Use the backend/API base URL for the time tracking system. Payroll will append <code className="rounded bg-gray-100 px-1 py-0.5">/api/v1/payroll/time_summary</code> automatically.
                </p>
              </div>
              <div className="flex gap-2">
                {editing && activeSource && activeSource.id === form.id && (
                  <Button variant="outline" onClick={() => testConnection(activeSource)} disabled={saving || testingId === activeSource.id}>
                    <Zap className="mr-2 h-4 w-4" /> {testingId === activeSource.id ? 'Testing...' : 'Test connection'}
                  </Button>
                )}
                {editing && (
                  <Button variant="outline" onClick={resetForm} disabled={saving}>
                    <X className="mr-2 h-4 w-4" /> Add new
                  </Button>
                )}
              </div>
            </div>

            <div className="grid gap-4 lg:grid-cols-2">
              <label className="block text-sm font-medium text-gray-700">
                Source name
                <input
                  value={form.name}
                  onChange={(e) => setForm((prev) => ({ ...prev, name: e.target.value }))}
                  placeholder="Time tracking system"
                  className="mt-1 w-full rounded-md border px-3 py-2 text-sm"
                />
              </label>

              <label className="block text-sm font-medium text-gray-700">
                Source system
                <select
                  value={form.source_type}
                  onChange={(e) => setForm((prev) => ({
                    ...prev,
                    source_type: e.target.value as TimeTrackingSource['source_type'],
                    delegation_token: '',
                  }))}
                  disabled={editing}
                  className="mt-1 w-full rounded-md border px-3 py-2 text-sm disabled:bg-gray-100 disabled:text-gray-500"
                >
                  {sourceTypeOptions.map((option) => (
                    <option key={option.value} value={option.value}>{option.label}</option>
                  ))}
                </select>
                <span className="mt-1 block text-xs text-gray-500">
                  {editing
                    ? 'Create a new source if this client needs a different source system.'
                    : sourceTypeOptions.find((option) => option.value === form.source_type)?.hint}
                </span>
              </label>

              <label className="block text-sm font-medium text-gray-700">
                Backend base URL
                <input
                  value={form.base_url}
                  onChange={(e) => setForm((prev) => ({ ...prev, base_url: e.target.value }))}
                  placeholder="https://time-tracking-api.example.com"
                  className="mt-1 w-full rounded-md border px-3 py-2 text-sm"
                />
                <span className="mt-1 block text-xs text-gray-500">
                  If Fetch Hours returns 404, this usually points at the wrong backend or an API deploy that does not include the payroll export route yet.
                </span>
              </label>

              <label className="block text-sm font-medium text-gray-700">
                Shared secret {editing && <span className="font-normal text-gray-500">({sources.find((source) => source.id === form.id)?.shared_secret_configured ? 'leave blank to keep current' : 'required — none saved yet'})</span>}
                <input
                  type="password"
                  value={form.shared_secret}
                  onChange={(e) => setForm((prev) => ({ ...prev, shared_secret: e.target.value }))}
                  placeholder={editing ? 'Keep existing secret' : 'Paste PAYROLL_SHARED_SECRET'}
                  className="mt-1 w-full rounded-md border px-3 py-2 text-sm"
                  autoComplete="new-password"
                />
                <span className="mt-1 block text-xs text-gray-500">Must match the source app’s payroll export secret.</span>
              </label>

              {form.source_type === 'aire_services' && (
                <div className="rounded-xl border border-primary-200 bg-primary-50/60 p-4 lg:col-span-2">
                  <div className="flex items-start gap-3">
                    <KeyRound className="mt-0.5 h-5 w-5 shrink-0 text-primary-700" aria-hidden="true" />
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <p className="text-sm font-semibold text-neutral-950">Your AIRE payroll access</p>
                        {editing && (
                          <Badge variant={sources.find((source) => source.id === form.id)?.delegation_token_configured ? 'success' : 'warning'}>
                            {sources.find((source) => source.id === form.id)?.delegation_token_configured ? 'Connected' : 'Needed for approvals'}
                          </Badge>
                        )}
                      </div>
                      <p className="mt-1 text-xs leading-5 text-neutral-600">
                        Paste the delegation token AIRE issued to you. It is encrypted, belongs only to your Cornerstone login, and lets AIRE record who approved time or locked a cutoff. Other payroll staff use their own token.
                      </p>
                      <div className="mt-3 flex flex-col gap-2 sm:flex-row">
                        <input
                          type="password"
                          aria-label="AIRE delegation token"
                          value={form.delegation_token}
                          onChange={(event) => setForm((current) => ({ ...current, delegation_token: event.target.value }))}
                          placeholder={editing ? 'Leave blank to keep your current access' : 'Paste your AIRE delegation token'}
                          autoComplete="new-password"
                          className="min-w-0 flex-1 rounded-md border border-primary-200 bg-white px-3 py-2 text-sm"
                        />
                        {editing && (
                          <Button type="button" onClick={() => void saveDelegationOnly()} disabled={saving || !form.delegation_token.trim()}>
                            Save my access
                          </Button>
                        )}
                        {editing && sources.find((source) => source.id === form.id)?.delegation_token_configured && (
                          <Button type="button" variant="outline" onClick={() => void removeDelegation()} disabled={saving}>
                            Remove my access
                          </Button>
                        )}
                      </div>
                    </div>
                  </div>
                </div>
              )}

              <label className="flex items-start gap-3 rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm lg:col-span-2">
                <input
                  type="checkbox"
                  role="switch"
                  checked={form.active}
                  onChange={(event) => setForm((current) => ({ ...current, active: event.target.checked }))}
                  disabled={saving || loading}
                  className="mt-1 h-4 w-4"
                />
                <span><span className="font-semibold text-neutral-900">Enable time tracking integration for this client</span><span className="mt-1 block text-neutral-600">Save the source to apply this setting. Disabling stops new imports and links; it keeps saved records and payment tracking for payroll already linked.</span></span>
              </label>
              <div className="flex justify-end lg:col-span-2">
                <Button onClick={saveSource} disabled={saving || loading || !activeCompanyId}>
                  <Save className="mr-2 h-4 w-4" />
                  {saving ? 'Saving...' : editing ? 'Save source' : 'Create source'}
                </Button>
              </div>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardContent className="p-5">
            <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <h2 className="text-lg font-semibold text-gray-900">Configured source history</h2>
                <p className="mt-1 text-sm text-gray-500">Only one source can be active for this client. Older sources can stay inactive for history.</p>
              </div>
              <Button variant="outline" onClick={loadSources} disabled={loading}>
                <RefreshCw className="mr-2 h-4 w-4" /> Refresh
              </Button>
            </div>

            {loading ? (
              <div className="py-8 text-center text-sm text-gray-500">Loading source...</div>
            ) : sources.length === 0 ? (
              <div className="rounded-lg border border-dashed p-8 text-center">
                <Link2 className="mx-auto h-8 w-8 text-gray-400" />
                <h3 className="mt-3 font-medium text-gray-900">No source configured for this client yet</h3>
                <p className="mt-1 text-sm text-gray-500">Add the backend URL and shared secret above, test the connection, then import from a draft pay period.</p>
              </div>
            ) : (
              <div className="overflow-x-auto rounded-lg border">
                <table className="min-w-[900px] divide-y divide-gray-200 text-sm">
                  <thead className="bg-gray-50">
                    <tr>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">Name</th>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">System</th>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">Backend URL</th>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">Status</th>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">Last sync</th>
                      <th className="px-4 py-2 text-right text-xs font-medium uppercase text-gray-500">Actions</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-200 bg-white">
                    {sources.map((source) => (
                      <tr key={source.id}>
                        <td className="px-4 py-3 font-medium text-gray-900">{source.name}</td>
                        <td className="px-4 py-3 text-gray-600">
                          {sourceTypeOptions.find((option) => option.value === source.source_type)?.label || source.source_type}
                        </td>
                        <td className="max-w-md truncate px-4 py-3 text-gray-600">{source.base_url}</td>
                        <td className="px-4 py-3">
                          <div className="flex flex-col gap-1">
                            <Badge variant={source.active ? 'success' : 'default'}>{source.active ? 'Active' : 'Inactive'}</Badge>
                            {!source.shared_secret_configured && <Badge variant="warning">Missing secret</Badge>}
                            {source.source_type === 'aire_services' && (
                              <Badge variant={source.delegation_token_configured ? 'success' : 'warning'}>
                                {source.delegation_token_configured ? 'My payroll access ready' : 'My payroll access needed'}
                              </Badge>
                            )}
                          </div>
                        </td>
                        <td className="px-4 py-3 text-gray-600">{source.last_synced_at ? new Date(source.last_synced_at).toLocaleString() : 'Never'}</td>
                        <td className="px-4 py-3 text-right">
                          <div className="flex justify-end gap-2">
                            <Button variant="outline" size="sm" onClick={() => editSource(source)} disabled={saving}>Edit</Button>
                            {source.active && (
                              <Button variant="outline" size="sm" onClick={() => testConnection(source)} disabled={testingId === source.id}>
                                <Zap className="mr-1 h-3.5 w-3.5" /> {testingId === source.id ? 'Testing' : 'Test'}
                              </Button>
                            )}
                            {source.active && (
                              <Button variant="outline" size="sm" onClick={() => deactivateSource(source)} disabled={saving}>
                                <Trash2 className="mr-1 h-3.5 w-3.5" /> Deactivate
                              </Button>
                            )}
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
