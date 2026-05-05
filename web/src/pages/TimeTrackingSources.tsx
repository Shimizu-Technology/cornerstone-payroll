import { useCallback, useEffect, useRef, useState } from 'react';
import { Link2, RefreshCw, Save, ShieldCheck, Trash2, X, Zap } from 'lucide-react';
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
  base_url: string;
  shared_secret: string;
  active: boolean;
}

const blankForm: FormState = {
  name: '',
  base_url: '',
  shared_secret: '',
  active: true,
};

function normalizeForm(source?: TimeTrackingSource): FormState {
  if (!source) return { ...blankForm };

  return {
    id: source.id,
    name: source.name,
    base_url: source.base_url,
    shared_secret: '',
    active: source.active,
  };
}

function summarizeTestResult(result: TimeTrackingSourceTestResponse) {
  const count = result.employee_count ?? 0;
  const source = result.source ? ` Source responded as ${result.source}.` : '';
  return `${result.message || 'Connection succeeded.'} Found ${count} employee${count === 1 ? '' : 's'} for today.${source}`;
}

export function TimeTrackingSources() {
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
        active: editing ? form.active : true,
      };

      if (editing && form.id) {
        const payload: TimeTrackingSourceUpdatePayload = { ...basePayload };
        if (form.shared_secret.trim()) payload.shared_secret = form.shared_secret.trim();
        await timeTrackingSourcesApi.update(form.id, payload);
        showSuccess('Time tracking source updated for this client.');
      } else {
        const payload: TimeTrackingSourceCreatePayload = {
          ...basePayload,
          source_type: 'custom',
          shared_secret: form.shared_secret.trim(),
        };
        await timeTrackingSourcesApi.create(payload);
        showSuccess('Time tracking source created for this client.');
      }

      await loadSources();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save time tracking source');
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
      if (!source.shared_secret_configured) {
        setError('Shared secret is not configured in Payroll. Paste the source app PAYROLL_SHARED_SECRET, save, then test again.');
        return;
      }

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
              <p className="mt-1">Payroll uses one active time tracking source per client. The import modal will use this client’s active source automatically.</p>
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

              <div className="flex items-end justify-end">
                <Button onClick={saveSource} disabled={saving || !activeCompanyId}>
                  <Save className="mr-2 h-4 w-4" />
                  {saving ? 'Saving...' : editing ? 'Save source' : 'Create active source'}
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
                        <td className="max-w-md truncate px-4 py-3 text-gray-600">{source.base_url}</td>
                        <td className="px-4 py-3">
                          <div className="flex flex-col gap-1">
                            <Badge variant={source.active ? 'success' : 'default'}>{source.active ? 'Active' : 'Inactive'}</Badge>
                            {!source.shared_secret_configured && <Badge variant="warning">Missing secret</Badge>}
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
