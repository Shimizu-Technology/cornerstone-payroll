import { useCallback, useEffect, useRef, useState } from 'react';
import { Link2, Plus, RefreshCw, Save, ShieldCheck, Trash2, X } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { timeTrackingSourcesApi } from '@/services/api';
import type { TimeTrackingSource, TimeTrackingSourceCreatePayload, TimeTrackingSourceType, TimeTrackingSourceUpdatePayload } from '@/services/api';

const SOURCE_TYPE_OPTIONS: Array<{ value: TimeTrackingSourceType; label: string; hint: string }> = [
  { value: 'aire_services', label: 'AIRE Services', hint: 'Uses /api/v1/payroll/time_summary from AIRE' },
  { value: 'cornerstone_tax', label: 'Cornerstone Tax', hint: 'Uses /api/v1/payroll/time_summary from Cornerstone Tax' },
  { value: 'custom', label: 'Custom', hint: 'Any compatible Shimizu time tracking export' },
];

interface FormState {
  id?: number;
  name: string;
  source_type: TimeTrackingSourceType;
  base_url: string;
  shared_secret: string;
  active: boolean;
}

const blankForm: FormState = {
  name: '',
  source_type: 'aire_services',
  base_url: '',
  shared_secret: '',
  active: true,
};

function sourceTypeLabel(type: TimeTrackingSourceType) {
  return SOURCE_TYPE_OPTIONS.find((option) => option.value === type)?.label || type;
}

function normalizeForm(source?: TimeTrackingSource): FormState {
  if (!source) return { ...blankForm };

  return {
    id: source.id,
    name: source.name,
    source_type: source.source_type,
    base_url: source.base_url,
    shared_secret: '',
    active: source.active,
  };
}

export function TimeTrackingSources() {
  const [sources, setSources] = useState<TimeTrackingSource[]>([]);
  const [form, setForm] = useState<FormState>(() => normalizeForm());
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const successTimerRef = useRef<number | null>(null);

  const loadSources = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await timeTrackingSourcesApi.list();
      setSources(res.time_tracking_sources);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load time tracking sources');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadSources();
  }, [loadSources]);

  useEffect(() => {
    return () => {
      if (successTimerRef.current) window.clearTimeout(successTimerRef.current);
    };
  }, []);

  const editing = form.id != null;

  const showSuccess = (message: string) => {
    if (successTimerRef.current) window.clearTimeout(successTimerRef.current);
    setSuccess(message);
    successTimerRef.current = window.setTimeout(() => {
      setSuccess(null);
      successTimerRef.current = null;
    }, 4000);
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
    if (!editing && !form.shared_secret.trim()) return 'Shared secret is required when creating a source.';
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

      const successMessage = editing && form.id
        ? 'Time tracking source updated.'
        : 'Time tracking source created.';

      if (editing && form.id) {
        const payload: TimeTrackingSourceUpdatePayload = { ...basePayload };
        if (form.shared_secret.trim()) payload.shared_secret = form.shared_secret.trim();
        await timeTrackingSourcesApi.update(form.id, payload);
      } else {
        const payload: TimeTrackingSourceCreatePayload = {
          ...basePayload,
          source_type: form.source_type,
          shared_secret: form.shared_secret.trim(),
        };
        await timeTrackingSourcesApi.create(payload);
      }

      resetForm();
      await loadSources();
      showSuccess(successMessage);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save time tracking source');
    } finally {
      setSaving(false);
    }
  };

  const deactivateSource = async (source: TimeTrackingSource) => {
    if (!window.confirm(`Deactivate ${source.name}? Payroll will stop offering it in the import modal.`)) return;

    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      await timeTrackingSourcesApi.deactivate(source.id);
      if (form.id === source.id) resetForm();
      await loadSources();
      showSuccess('Time tracking source deactivated.');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to deactivate source');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div>
      <Header
        title="Time Tracking Sources"
        description="Connect this client to AIRE, Cornerstone Tax, or another compatible time tracking export."
      />

      <div className="p-4 space-y-6 sm:p-6 lg:p-8">
        {error && <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error}</div>}
        {success && <div className="rounded-lg border border-green-200 bg-green-50 p-4 text-sm text-green-700">{success}</div>}

        <Card>
          <CardContent className="p-5">
            <div className="mb-4 flex items-start justify-between gap-3">
              <div>
                <h2 className="text-lg font-semibold text-gray-900">{editing ? 'Edit source' : 'Add source'}</h2>
                <p className="mt-1 text-sm text-gray-500">
                  The shared secret is stored encrypted and never shown again. Use the same value as <code className="rounded bg-gray-100 px-1 py-0.5">PAYROLL_SHARED_SECRET</code> on the source app.
                </p>
              </div>
              {editing && (
                <Button variant="outline" onClick={resetForm} disabled={saving}>
                  <X className="mr-2 h-4 w-4" /> Cancel edit
                </Button>
              )}
            </div>

            <div className="grid gap-4 lg:grid-cols-2">
              <label className="block text-sm font-medium text-gray-700">
                Source name
                <input
                  value={form.name}
                  onChange={(e) => setForm((prev) => ({ ...prev, name: e.target.value }))}
                  placeholder="AIRE Services"
                  className="mt-1 w-full rounded-md border px-3 py-2 text-sm"
                />
              </label>

              <label className="block text-sm font-medium text-gray-700">
                Source type
                <select
                  value={form.source_type}
                  onChange={(e) => setForm((prev) => ({ ...prev, source_type: e.target.value as TimeTrackingSourceType }))}
                  disabled={editing}
                  className="mt-1 w-full rounded-md border px-3 py-2 text-sm disabled:bg-gray-100 disabled:text-gray-500"
                >
                  {SOURCE_TYPE_OPTIONS.map((option) => (
                    <option key={option.value} value={option.value}>{option.label}</option>
                  ))}
                </select>
                <span className="mt-1 block text-xs text-gray-500">
                  {editing ? 'Source type cannot be changed after creation.' : SOURCE_TYPE_OPTIONS.find((option) => option.value === form.source_type)?.hint}
                </span>
              </label>

              <label className="block text-sm font-medium text-gray-700 lg:col-span-2">
                Backend base URL
                <input
                  value={form.base_url}
                  onChange={(e) => setForm((prev) => ({ ...prev, base_url: e.target.value }))}
                  placeholder="https://aire-api.example.com"
                  className="mt-1 w-full rounded-md border px-3 py-2 text-sm"
                />
                <span className="mt-1 block text-xs text-gray-500">
                  Use the Rails/API host. Payroll appends <code>/api/v1/payroll/time_summary</code> automatically.
                </span>
              </label>

              <label className="block text-sm font-medium text-gray-700">
                Shared secret {editing && <span className="font-normal text-gray-500">(leave blank to keep current)</span>}
                <input
                  type="password"
                  value={form.shared_secret}
                  onChange={(e) => setForm((prev) => ({ ...prev, shared_secret: e.target.value }))}
                  placeholder={editing ? 'Keep existing secret' : 'Paste PAYROLL_SHARED_SECRET'}
                  className="mt-1 w-full rounded-md border px-3 py-2 text-sm"
                  autoComplete="new-password"
                />
              </label>

              <label className="flex items-center gap-2 self-end text-sm font-medium text-gray-700">
                <input
                  type="checkbox"
                  checked={form.active}
                  onChange={(e) => setForm((prev) => ({ ...prev, active: e.target.checked }))}
                  className="rounded border-gray-300"
                />
                Active / visible in import modal
              </label>
            </div>

            <div className="mt-5 flex justify-end">
              <Button onClick={saveSource} disabled={saving}>
                {editing ? <Save className="mr-2 h-4 w-4" /> : <Plus className="mr-2 h-4 w-4" />}
                {saving ? 'Saving...' : editing ? 'Save source' : 'Create source'}
              </Button>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardContent className="p-5">
            <div className="mb-4 flex items-center justify-between gap-3">
              <div>
                <h2 className="text-lg font-semibold text-gray-900">Configured sources</h2>
                <p className="mt-1 text-sm text-gray-500">These are scoped to the currently selected client.</p>
              </div>
              <Button variant="outline" onClick={loadSources} disabled={loading}>
                <RefreshCw className="mr-2 h-4 w-4" /> Refresh
              </Button>
            </div>

            {loading ? (
              <div className="py-8 text-center text-sm text-gray-500">Loading sources...</div>
            ) : sources.length === 0 ? (
              <div className="rounded-lg border border-dashed p-8 text-center">
                <Link2 className="mx-auto h-8 w-8 text-gray-400" />
                <h3 className="mt-3 font-medium text-gray-900">No time tracking sources yet</h3>
                <p className="mt-1 text-sm text-gray-500">Add AIRE or Cornerstone Tax above, then use Import Time Tracking from a draft pay period.</p>
              </div>
            ) : (
              <div className="overflow-hidden rounded-lg border">
                <table className="min-w-full divide-y divide-gray-200 text-sm">
                  <thead className="bg-gray-50">
                    <tr>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">Name</th>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">Type</th>
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
                        <td className="px-4 py-3 text-gray-700">{sourceTypeLabel(source.source_type)}</td>
                        <td className="max-w-md truncate px-4 py-3 text-gray-600">{source.base_url}</td>
                        <td className="px-4 py-3">
                          <Badge variant={source.active ? 'success' : 'default'}>{source.active ? 'Active' : 'Inactive'}</Badge>
                        </td>
                        <td className="px-4 py-3 text-gray-600">{source.last_synced_at ? new Date(source.last_synced_at).toLocaleString() : 'Never'}</td>
                        <td className="px-4 py-3 text-right">
                          <div className="flex justify-end gap-2">
                            <Button variant="outline" size="sm" onClick={() => editSource(source)} disabled={saving}>Edit</Button>
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

        <div className="rounded-lg border border-blue-200 bg-blue-50 p-4 text-sm text-blue-800">
          <div className="flex gap-2">
            <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0" />
            <div>
              <p className="font-medium">Security note</p>
              <p className="mt-1">Payroll sends the shared secret as a service header. Source apps compare it to their <code className="rounded bg-blue-100 px-1 py-0.5">PAYROLL_SHARED_SECRET</code> env var before returning time data.</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
