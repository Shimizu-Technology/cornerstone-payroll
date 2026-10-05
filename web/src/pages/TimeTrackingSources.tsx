import { supportsSourceOperation } from '@/lib/time-tracking';
import { useCallback, useEffect, useRef, useState } from 'react';
import { CheckCircle2, Link2, RefreshCw, Save, ShieldCheck, Trash2, Unplug, X, Zap } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { useCompany } from '@/contexts/CompanyContext';
import { timeTrackingSourcesApi } from '@/services/api';
import type { AireAccountLink, TimeTrackingSource, TimeTrackingSourceCreatePayload, TimeTrackingSourceTestResponse, TimeTrackingSourceUpdatePayload } from '@/services/api';

interface FormState {
  id?: number;
  name: string;
  source_type: TimeTrackingSource['source_type'];
  base_url: string;
  authorization_origin: string;
  shared_secret: string;
  active: boolean;
}

const blankForm: FormState = {
  name: '',
  source_type: 'aire_services',
  base_url: '',
  authorization_origin: '',
  shared_secret: '',
  active: false,
};

const sourceTypeOptions: Array<{ value: TimeTrackingSource['source_type']; label: string; hint: string }> = [
  { value: 'aire_services', label: 'AIRE Services Guam', hint: 'Use for the AIRE time clock.' },
  { value: 'cornerstone_tax', label: 'Cornerstone Tax', hint: 'Use for Cornerstone Tax staff time.' },
  { value: 'custom', label: 'Custom compatible source', hint: 'Use only for another app that implements the shared time and payroll protocol. Test connection to discover its supported operations.' },
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
    authorization_origin: source.authorization_origin || '',
    shared_secret: '',
    active: source.active,
  };
}

function summarizeTestResult(result: TimeTrackingSourceTestResponse) {
  const count = result.employee_count ?? 0;
  const source = result.source ? ` Source responded as ${result.source}.` : '';
  const cockpit = result.cockpit_ready === true
    ? ' The source payroll workspace is available.'
    : result.cockpit_ready === false ? ' The source payroll workspace is unavailable.' : '';
  const identity = result.identity_verified
    ? ' The source installation identity is verified.'
    : ' This source uses the legacy contract without an installation identity.';
  return `${result.message || 'Connection succeeded.'} Found ${count} employee${count === 1 ? '' : 's'} for today.${source}${identity}${cockpit}`;
}

type TimeTrackingSourcesProps = {
  navigateToAuthorization?: (url: string) => void;
};

const defaultAuthorizationNavigation = (url: string) => window.location.assign(url);

export function TimeTrackingSources({
  navigateToAuthorization = defaultAuthorizationNavigation,
}: TimeTrackingSourcesProps = {}) {
  const { activeCompanyId } = useCompany();
  return <ClientTimeTrackingSources key={activeCompanyId} navigateToAuthorization={navigateToAuthorization} />;
}

function ClientTimeTrackingSources({ navigateToAuthorization }: Required<TimeTrackingSourcesProps>) {
  const { activeCompany, activeCompanyId } = useCompany();
  const [sources, setSources] = useState<TimeTrackingSource[]>([]);
  const [form, setForm] = useState<FormState>(() => normalizeForm());
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [testingId, setTestingId] = useState<number | null>(null);
  const [accountLink, setAccountLink] = useState<AireAccountLink | null>(null);
  const [accountLinkLoading, setAccountLinkLoading] = useState(false);
  const [accountLinkBusy, setAccountLinkBusy] = useState(false);
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
      const requestedSourceId = Number(new URLSearchParams(window.location.search).get('source_id'));
      setSources(loadedSources);
      setForm(normalizeForm(
        loadedSources.find((source) => source.id === requestedSourceId) ||
        loadedSources.find((source) => source.active) ||
        loadedSources[0]
      ));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load time tracking source');
    } finally {
      setLoading(false);
    }
  }, [activeCompanyId]);

  useEffect(() => {
    loadSources();
  }, [loadSources]);

  const accountLinkSupported = supportsSourceOperation(sources.find((source) => source.id === form.id), 'account_linking');

  useEffect(() => {
    if (!form.id || !accountLinkSupported) {
      setAccountLink(null);
      setAccountLinkLoading(false);
      return;
    }

    let active = true;
    setAccountLinkLoading(true);
    timeTrackingSourcesApi.getAireAccountLink(form.id)
      .then((response) => {
        if (active) setAccountLink(response.account_link);
      })
      .catch((err) => {
        if (active) {
          setAccountLink(null);
          setError(err instanceof Error ? err.message : 'Could not check your time tracking account connection.');
        }
      })
      .finally(() => {
        if (active) setAccountLinkLoading(false);
      });

    return () => { active = false; };
  }, [form.id, accountLinkSupported]);

  useEffect(() => {
    if (loading) return;

    const url = new URL(window.location.href);
    const result = url.searchParams.get('aire_link');
    if (!result) return;

    if (result === 'connected') showSuccess('Your time tracking administrator account is connected. You can now manage source payroll work here.');
    if (result === 'cancelled') setError('Time tracking account connection was cancelled. Nothing was changed.');
    url.searchParams.delete('aire_link');
    window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
  }, [loading]);

  useEffect(() => {
    return () => {
      if (successTimerRef.current) window.clearTimeout(successTimerRef.current);
    };
  }, []);

  const editing = form.id != null;
  const activeSource = sources.find((source) => source.active) || null;
  const selectedSource = sources.find((source) => source.id === form.id) || null;

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
    setAccountLink(null);
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
        authorization_origin: form.authorization_origin.trim(),
        active: form.active,
      };

      if (editing && form.id) {
        const payload: TimeTrackingSourceUpdatePayload = { ...basePayload };
        if (form.shared_secret.trim()) payload.shared_secret = form.shared_secret.trim();
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

  const connectAireAccount = async () => {
    if (!form.id) {
      setError('Save the time tracking source before connecting your account.');
      return;
    }

    setAccountLinkBusy(true);
    setError(null);
    setSuccess(null);
    try {
      const response = await timeTrackingSourcesApi.createAireAccountLink(form.id);
      navigateToAuthorization(response.authorization_url);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not start the time tracking account connection.');
      setAccountLinkBusy(false);
    }
  };

  const disconnectAireAccount = async () => {
    if (!form.id || !window.confirm('Disconnect your time tracking administrator account? Read-only source details will remain available.')) return;

    setAccountLinkBusy(true);
    setError(null);
    setSuccess(null);
    try {
      const response = await timeTrackingSourcesApi.disconnectAireAccountLink(form.id);
      setAccountLink(response.account_link);
      setSources((previous) => previous.map((source) => (
        source.id === form.id ? { ...source, delegation_token_configured: false } : source
      )));
      showSuccess('Your time tracking administrator account was disconnected.');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not disconnect your time tracking account.');
    } finally {
      setAccountLinkBusy(false);
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
      setSources((previous) => previous.map((item) => item.id === source.id ? {
        ...item,
        identity_verified: Boolean(result.identity_verified),
        connection_uuid: result.connection_uuid || item.connection_uuid,
        source_instance_id: result.source_instance_id,
        source_protocol: result.source_protocol,
        source_protocol_version: result.source_protocol_version,
        source_capabilities: result.source_capabilities || [],
        supported_operations: result.supported_operations || item.supported_operations,
        identity_verified_at: result.identity_verified_at || item.identity_verified_at,
      } : item));
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
              <p className="mt-1">Enable a source only for clients that use it. An enabled time tracking source shows time tracking import and linking actions on that client’s payroll. With no enabled source, new import and linking actions are hidden. Previously linked records remain available for review.</p>
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

              {editing && selectedSource && (
                  <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 lg:col-span-2">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="text-sm font-semibold text-neutral-950">Source installation identity</p>
                      <Badge variant={selectedSource.identity_verified ? 'success' : 'warning'}>
                        {selectedSource.identity_verified ? 'Verified' : 'Test required'}
                      </Badge>
                    </div>
                    <p className="mt-2 text-sm leading-6 text-neutral-600">
                      {selectedSource.identity_verified
                        ? 'Payroll is locked to this source installation. If the backend URL starts responding as a different installation, imports stop for review.'
                        : 'Select Test connection after saving. Payroll will verify and remember the exact source installation automatically.'}
                    </p>
                    {selectedSource.identity_verified && selectedSource.source_capabilities?.length > 0 && (
                      <p className="mt-2 text-xs leading-5 text-neutral-500">
                        Verified contract {selectedSource.source_protocol_version}: {selectedSource.source_capabilities.length} supported feature{selectedSource.source_capabilities.length === 1 ? '' : 's'}.
                      </p>
                    )}
                  </div>
              )}

              <label className="block text-sm font-medium text-gray-700">
                Source system
                <select
                  value={form.source_type}
                  onChange={(e) => setForm((prev) => ({
                    ...prev,
                    source_type: e.target.value as TimeTrackingSource['source_type'],
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

              {form.source_type === 'custom' && (
                <label className="block text-sm font-medium text-gray-700">
                  Account sign-in site
                  <input value={form.authorization_origin}
                    onChange={(event) => setForm((previous) => ({ ...previous, authorization_origin: event.target.value }))}
                    placeholder="https://time.example.com"
                    className="mt-1 w-full rounded-md border px-3 py-2 text-sm" />
                  <span className="mt-1 block text-xs text-gray-500">Approved website origin for connecting your account. Leave blank for a summary-only source.</span>
                </label>
              )}

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

              {supportsSourceOperation(selectedSource, 'account_linking') && (
                <div className="rounded-xl border border-primary-200 bg-primary-50/60 p-4 lg:col-span-2">
                  <div className="flex items-start gap-3">
                    {accountLink?.connected
                      ? <CheckCircle2 className="mt-2 h-5 w-5 shrink-0 text-emerald-700" aria-hidden="true" />
                      : <Link2 className="mt-2 h-5 w-5 shrink-0 text-primary-700" aria-hidden="true" />}
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <p className="text-sm font-semibold text-neutral-950">Your time tracking payroll access</p>
                        {editing && (
                          <Badge variant={accountLink?.connected ? 'success' : 'warning'}>
                            {accountLinkLoading ? 'Checking…' : accountLink?.connected ? 'Connected' : 'Connection needed'}
                          </Badge>
                        )}
                      </div>
                      <div className="mt-2 rounded-lg border border-primary-100 bg-white/80 px-4 py-2 text-xs leading-5 text-neutral-700">
                        {accountLink?.connected ? (
                          <>
                            <p className="font-semibold text-neutral-900">Connected as {accountLink.source_user_name || accountLink.aire_user_name || accountLink.source_user_email || accountLink.aire_user_email || 'your time tracking administrator account'}</p>
                            {accountLink.aire_user_email && <p className="mt-1 text-neutral-600">{accountLink.aire_user_email}</p>}
                            <p className="mt-2 text-neutral-600">This connection does not expire on a timer. It stops if you disconnect it or your time tracking administrator access is disabled.</p>
                          </>
                        ) : (
                          <>
                            <p className="font-semibold text-neutral-900">Connect once—no token copying or routine renewal</p>
                            <p className="mt-1 text-neutral-600">Cornerstone will take you to your time tracking system to sign in and confirm the connection, then bring you straight back. After that, approvals, corrections, and payroll cutoff work stay in Cornerstone.</p>
                            {sources.find((source) => source.id === form.id)?.delegation_token_configured && (
                              <p className="mt-2 font-medium text-amber-800">Your legacy 90-day access still works. Connect now to replace it with the permanent account link.</p>
                            )}
                          </>
                        )}
                      </div>
                      <div className="mt-4 flex flex-wrap gap-2">
                        {!editing && <p className="text-xs text-neutral-600">Save this source first, then connect your time tracking administrator account.</p>}
                        {editing && !accountLink?.connected && (
                          <Button type="button" onClick={() => void connectAireAccount()} disabled={saving || accountLinkBusy || accountLinkLoading}>
                            <Link2 className="mr-2 h-4 w-4" />
                            {accountLinkBusy ? 'Opening time tracking…' : 'Connect my time tracking account'}
                          </Button>
                        )}
                        {editing && accountLink?.connected && (
                          <Button type="button" variant="outline" onClick={() => void disconnectAireAccount()} disabled={saving || accountLinkBusy}>
                            <Unplug className="mr-2 h-4 w-4" />
                            {accountLinkBusy ? 'Disconnecting…' : 'Disconnect'}
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
              <>
              <div className="space-y-3 sm:hidden">
                {sources.map((source) => (
                  <div key={source.id} data-testid="mobile-source-card" className="min-w-0 rounded-xl border border-neutral-200 bg-white p-4">
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <p className="break-words font-semibold text-neutral-950">{source.name}</p>
                        <p className="mt-1 text-sm text-neutral-600">{sourceTypeOptions.find((option) => option.value === source.source_type)?.label || source.source_type}</p>
                      </div>
                      <Badge variant={source.active ? 'success' : 'default'}>{source.active ? 'Active' : 'Inactive'}</Badge>
                    </div>
                    <p className="mt-3 break-all text-xs text-neutral-600">{source.base_url}</p>
                    <p className="mt-2 text-xs text-neutral-500">Last sync: {source.last_synced_at ? new Date(source.last_synced_at).toLocaleString() : 'Never'}</p>
                    <div className="mt-3 flex flex-wrap gap-2">
                      {!source.shared_secret_configured && <Badge variant="warning">Missing secret</Badge>}
                      <Badge variant={source.identity_verified ? 'success' : 'warning'}>{source.identity_verified ? 'Source verified' : 'Test source'}</Badge>
                      {supportsSourceOperation(source, 'account_linking') && (
                        <Badge variant={source.id === form.id && accountLink?.connected ? 'success' : 'warning'}>
                          {source.id === form.id && accountLink?.connected ? 'My time tracking account connected' : source.delegation_token_configured ? 'Legacy access active' : 'Open to connect'}
                        </Badge>
                      )}
                    </div>
                    <div className="mt-4 grid gap-2 [&>button]:w-full">
                      <Button variant="outline" size="sm" onClick={() => editSource(source)} disabled={saving}>Edit</Button>
                      {source.active && <Button variant="outline" size="sm" onClick={() => testConnection(source)} disabled={testingId === source.id}><Zap className="mr-1 h-3.5 w-3.5" />{testingId === source.id ? 'Testing' : 'Test connection'}</Button>}
                      {source.active && <Button variant="outline" size="sm" onClick={() => deactivateSource(source)} disabled={saving}><Trash2 className="mr-1 h-3.5 w-3.5" />Deactivate</Button>}
                    </div>
                  </div>
                ))}
              </div>
              <div className="hidden overflow-x-auto rounded-lg border sm:block">
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
                            <Badge variant={source.identity_verified ? 'success' : 'warning'}>{source.identity_verified ? 'Source verified' : 'Test source'}</Badge>
                            {supportsSourceOperation(source, 'account_linking') && (
                              <Badge variant={source.id === form.id && accountLink?.connected ? 'success' : 'warning'}>
                                {source.id === form.id && accountLink?.connected
                                  ? 'My time tracking account connected'
                                  : source.delegation_token_configured ? 'Legacy access active' : 'Open to connect'}
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
              </>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
