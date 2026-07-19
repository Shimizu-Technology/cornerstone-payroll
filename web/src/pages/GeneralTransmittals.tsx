import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowDown,
  ArrowUp,
  CalendarRange,
  CheckSquare,
  Download,
  Eye,
  FileCheck2,
  FileClock,
  FileText,
  Plus,
  RefreshCw,
  Save,
  Sparkles,
  Trash2,
} from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import {
  generalTransmittalsApi,
  nonEmployeeChecksApi,
  payPeriodsApi,
  type BlobDownload,
  type GeneralTransmittal,
  type GeneralTransmittalArtifact,
  type GeneralTransmittalItem,
  type GeneralTransmittalPayload,
} from '@/services/api';
import { useCompany } from '@/contexts/CompanyContext';
import type { NonEmployeeCheck, PayPeriod } from '@/types';

type DraftItem = GeneralTransmittalItem & {
  local_id: string;
  details_text: string;
  _destroy?: boolean;
};

interface FormState {
  id?: number;
  source_kind: GeneralTransmittal['source_kind'];
  pay_period?: GeneralTransmittal['pay_period'];
  title: string;
  transmittal_date: string;
  preparer_name: string;
  recipient_name: string;
  notes_text: string;
  status: GeneralTransmittal['status'];
  generated_at?: string | null;
  artifacts: GeneralTransmittalArtifact[];
  items: DraftItem[];
}

const localToday = () => {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
};

const emptyForm = (): FormState => ({
  source_kind: 'standalone',
  title: '',
  transmittal_date: localToday(),
  preparer_name: '',
  recipient_name: '',
  notes_text: '',
  status: 'draft',
  artifacts: [],
  items: [],
});

const currency = (value?: number | null) => new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
}).format(Number(value || 0));

const dateOnly = (value?: string | null) => {
  if (!value) return 'Not set';
  const [year, month, day] = value.slice(0, 10).split('-').map(Number);
  return new Date(year, month - 1, day).toLocaleDateString();
};

const formatBytes = (value: number) => value > 1024 * 1024
  ? `${(value / (1024 * 1024)).toFixed(1)} MB`
  : `${Math.max(1, Math.round(value / 1024))} KB`;

const itemTone: Record<string, string> = {
  check: 'border-blue-200 bg-blue-50/50',
  report: 'border-violet-200 bg-violet-50/45',
  document: 'border-violet-200 bg-violet-50/45',
  tax_obligation: 'border-amber-200 bg-amber-50/55',
  manual: 'border-neutral-200 bg-white',
};

function downloadBlob(blobData: BlobDownload, fallbackName: string) {
  const url = URL.createObjectURL(blobData.blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = blobData.filename || fallbackName;
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function toDraft(transmittal: GeneralTransmittal): FormState {
  return {
    id: transmittal.id,
    source_kind: transmittal.source_kind,
    pay_period: transmittal.pay_period,
    title: transmittal.title,
    transmittal_date: transmittal.transmittal_date,
    preparer_name: transmittal.preparer_name || '',
    recipient_name: transmittal.recipient_name || '',
    notes_text: (transmittal.notes || []).join('\n'),
    status: transmittal.status,
    generated_at: transmittal.generated_at,
    artifacts: transmittal.artifacts || [],
    items: (transmittal.items || []).map((item) => ({
      ...item,
      local_id: `item-${item.id || crypto.randomUUID()}`,
      details_text: (item.details || []).join('\n'),
    })),
  };
}

export function GeneralTransmittals() {
  const { activeCompanyId } = useCompany();
  const [transmittals, setTransmittals] = useState<GeneralTransmittal[]>([]);
  const [payPeriods, setPayPeriods] = useState<PayPeriod[]>([]);
  const [standaloneChecks, setStandaloneChecks] = useState<NonEmployeeCheck[]>([]);
  const [selectedPayPeriodId, setSelectedPayPeriodId] = useState('');
  const [selectedCheckId, setSelectedCheckId] = useState('');
  const [form, setForm] = useState<FormState>(emptyForm);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const autoOpenedRef = useRef<string | null>(null);

  const loadLists = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [transmittalResult, checkResult, payPeriodResult] = await Promise.all([
        generalTransmittalsApi.list(),
        nonEmployeeChecksApi.list({ standalone: 'true', active: 'true' }),
        payPeriodsApi.list(),
      ]);
      setTransmittals(transmittalResult.general_transmittals);
      setStandaloneChecks(checkResult.non_employee_checks);
      setPayPeriods(payPeriodResult.pay_periods);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to load the transmittal builder');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    setForm(emptyForm());
    setSelectedPayPeriodId('');
    autoOpenedRef.current = null;
    loadLists();
  }, [activeCompanyId, loadLists]);

  useEffect(() => () => {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
  }, [previewUrl]);

  const loadTransmittal = useCallback(async (id: number) => {
    setBusy(true);
    setError(null);
    try {
      const response = await generalTransmittalsApi.get(id);
      setForm(toDraft(response.general_transmittal));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to load the transmittal');
    } finally {
      setBusy(false);
    }
  }, []);

  const startFromPayPeriod = useCallback(async (payPeriodId: number) => {
    setBusy(true);
    setError(null);
    try {
      const response = await generalTransmittalsApi.fromPayPeriod(payPeriodId);
      setForm(toDraft(response.general_transmittal));
      setSelectedPayPeriodId(String(payPeriodId));
      await loadLists();
      setSuccess('Pay-period checks, reports, and calculated obligations are ready to customize.');
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to start from the pay period');
    } finally {
      setBusy(false);
    }
  }, [loadLists]);

  useEffect(() => {
    if (loading) return;
    const queryId = new URLSearchParams(window.location.search).get('pay_period_id');
    if (!queryId || autoOpenedRef.current === `${activeCompanyId}:${queryId}`) return;
    autoOpenedRef.current = `${activeCompanyId}:${queryId}`;
    startFromPayPeriod(Number(queryId));
  }, [activeCompanyId, loading, startFromPayPeriod]);

  const visibleItems = useMemo(() => form.items.filter((item) => !item._destroy), [form.items]);
  const includedItems = useMemo(() => visibleItems.filter((item) => item.included), [visibleItems]);
  const totalAmount = useMemo(
    () => includedItems.reduce((sum, item) => sum + Number(item.amount || 0), 0),
    [includedItems],
  );

  const buildPayload = (): GeneralTransmittalPayload => ({
    title: form.title.trim(),
    transmittal_date: form.transmittal_date,
    preparer_name: form.preparer_name.trim() || null,
    recipient_name: form.recipient_name.trim() || null,
    notes: form.notes_text.split('\n').map((note) => note.trim()).filter(Boolean),
    items: form.items.map((item, index) => ({
      id: item.id,
      source_type: item.source_type || null,
      source_id: item.source_id || null,
      item_type: item.item_type,
      title: item.title.trim(),
      payable_to: item.payable_to?.trim() || null,
      check_number: item.check_number?.trim() || null,
      amount: item.amount === null || item.amount === undefined ? null : Number(item.amount),
      details: item.details_text.split('\n').map((detail) => detail.trim()).filter(Boolean),
      position: index,
      included: item.included,
      _destroy: item._destroy,
    })),
  });

  const save = async (quiet = false) => {
    if (!form.title.trim()) {
      setError('Give the transmittal a title before saving.');
      return null;
    }
    setBusy(true);
    setError(null);
    try {
      const response = form.id
        ? await generalTransmittalsApi.update(form.id, buildPayload(), form.status === 'generated')
        : await generalTransmittalsApi.create(buildPayload());
      setForm(toDraft(response.general_transmittal));
      await loadLists();
      if (!quiet) setSuccess('Draft saved. Generated versions remain preserved.');
      return response.general_transmittal.id;
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to save the transmittal');
      return null;
    } finally {
      setBusy(false);
    }
  };

  const previewCurrent = async () => {
    if (!includedItems.length) {
      setError('Include at least one item before previewing.');
      return;
    }
    const id = await save(true);
    if (!id) return;
    setBusy(true);
    try {
      const blobData = await generalTransmittalsApi.previewPdf(id);
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      setPreviewUrl(URL.createObjectURL(blobData.blob));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to preview the PDF');
    } finally {
      setBusy(false);
    }
  };

  const generate = async () => {
    if (!includedItems.length) {
      setError('Include at least one item before generating.');
      return;
    }
    const id = await save(true);
    if (!id) return;
    setBusy(true);
    try {
      const blobData = await generalTransmittalsApi.generatePdf(id);
      downloadBlob(blobData, 'transmittal.pdf');
      await loadTransmittal(id);
      await loadLists();
      setSuccess('A new immutable transmittal version was generated and preserved.');
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to generate the PDF');
    } finally {
      setBusy(false);
    }
  };

  const refreshSources = async () => {
    if (!form.id) return;
    setBusy(true);
    setError(null);
    try {
      const response = await generalTransmittalsApi.refreshFromPayPeriod(form.id);
      setForm(toDraft(response.general_transmittal));
      setSuccess('New pay-period source records were added; your existing edits were preserved.');
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to refresh pay-period items');
    } finally {
      setBusy(false);
    }
  };

  const previewArtifact = async (artifact: GeneralTransmittalArtifact) => {
    if (!form.id) return;
    setBusy(true);
    try {
      const blobData = await generalTransmittalsApi.artifactPdf(form.id, artifact.id);
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      setPreviewUrl(URL.createObjectURL(blobData.blob));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to open the generated version');
    } finally {
      setBusy(false);
    }
  };

  const downloadArtifact = async (artifact: GeneralTransmittalArtifact) => {
    if (!form.id) return;
    setBusy(true);
    try {
      const blobData = await generalTransmittalsApi.artifactPdf(form.id, artifact.id, true);
      downloadBlob(blobData, artifact.filename);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to download the generated version');
    } finally {
      setBusy(false);
    }
  };

  const updateItem = (localId: string, patch: Partial<DraftItem>) => {
    setForm((current) => ({
      ...current,
      items: current.items.map((item) => item.local_id === localId ? { ...item, ...patch } : item),
    }));
  };

  const moveItem = (localId: string, direction: -1 | 1) => {
    setForm((current) => {
      const active = current.items.filter((item) => !item._destroy);
      const index = active.findIndex((item) => item.local_id === localId);
      const nextIndex = index + direction;
      if (index < 0 || nextIndex < 0 || nextIndex >= active.length) return current;
      [active[index], active[nextIndex]] = [active[nextIndex], active[index]];
      const destroyed = current.items.filter((item) => item._destroy);
      return { ...current, items: [...active, ...destroyed].map((item, position) => ({ ...item, position })) };
    });
  };

  const addManualItem = () => setForm((current) => ({
    ...current,
    items: [...current.items, {
      local_id: `manual-${crypto.randomUUID()}`,
      item_type: 'manual',
      title: 'Custom item',
      payable_to: '',
      check_number: '',
      amount: null,
      details: [],
      details_text: '',
      position: current.items.length,
      included: true,
      metadata: {},
    }],
  }));

  const addStandaloneCheck = () => {
    const check = standaloneChecks.find((candidate) => String(candidate.id) === selectedCheckId);
    if (!check) return;
    if (visibleItems.some((item) => item.source_type === 'NonEmployeeCheck' && item.source_id === check.id)) {
      setError('That check is already in this transmittal.');
      return;
    }
    setForm((current) => ({
      ...current,
      items: [...current.items, {
        local_id: `check-${check.id}`,
        source_type: 'NonEmployeeCheck',
        source_id: check.id,
        item_type: 'check',
        title: `Standalone check — ${check.payable_to}`,
        payable_to: check.payable_to,
        check_number: check.check_number || '',
        amount: Number(check.amount),
        details: [],
        details_text: check.memo || check.description || '',
        position: current.items.length,
        included: true,
        metadata: {},
      }],
    }));
    setSelectedCheckId('');
  };

  const removeItem = (localId: string) => updateItem(localId, { _destroy: true, included: false });

  const deleteDraft = async () => {
    if (!form.id || form.artifacts.length || !window.confirm('Delete this draft transmittal?')) return;
    setBusy(true);
    try {
      await generalTransmittalsApi.delete(form.id);
      setForm(emptyForm());
      await loadLists();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to delete the draft');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div>
      <Header
        title="Transmittal Builder"
        description="Start with a payroll period or a blank packet, customize every item, and preserve each generated version."
      />

      <main className="space-y-6 p-6 lg:p-8">
        <section className="overflow-hidden rounded-2xl border border-primary-200 bg-gradient-to-br from-primary-950 via-primary-900 to-primary-800 text-white shadow-sm">
          <div className="grid gap-6 p-6 lg:grid-cols-[1.3fr_1fr] lg:p-8">
            <div className="max-w-2xl">
              <div className="mb-4 flex h-11 w-11 items-center justify-center rounded-xl bg-white/10 ring-1 ring-white/15">
                <FileCheck2 className="h-5 w-5" />
              </div>
              <p className="text-xs font-semibold uppercase tracking-[0.18em] text-primary-200">One authoritative workflow</p>
              <h2 className="mt-2 text-2xl font-semibold tracking-tight">Build the delivery record from the work already completed.</h2>
              <p className="mt-3 max-w-xl text-sm leading-6 text-primary-100">
                Payroll checks, non-employee checks, reports, and calculated obligations arrive as a starting point. You decide what the client receives.
              </p>
            </div>
            <div className="rounded-2xl bg-white/10 p-4 ring-1 ring-white/15 backdrop-blur-sm">
              <label className="text-xs font-semibold uppercase tracking-[0.12em] text-primary-100">Start from pay period</label>
              <select
                value={selectedPayPeriodId}
                onChange={(event) => setSelectedPayPeriodId(event.target.value)}
                className="mt-2 h-11 w-full rounded-xl border border-white/20 bg-white px-3 text-sm text-neutral-900 outline-none ring-primary-300 focus:ring-2"
              >
                <option value="">Choose a pay period…</option>
                {payPeriods.map((period) => (
                  <option key={period.id} value={period.id}>
                    {dateOnly(period.start_date)} – {dateOnly(period.end_date)} · {period.status}
                  </option>
                ))}
              </select>
              <div className="mt-3 flex gap-2">
                <Button
                  type="button"
                  variant="secondary"
                  className="flex-1"
                  disabled={!selectedPayPeriodId || busy}
                  onClick={() => startFromPayPeriod(Number(selectedPayPeriodId))}
                >
                  <Sparkles className="mr-2 h-4 w-4" />
                  Build from payroll
                </Button>
                <Button type="button" variant="outline" className="border-white/25 bg-transparent text-white hover:bg-white/10 hover:text-white" onClick={() => setForm(emptyForm())}>
                  Blank
                </Button>
              </div>
            </div>
          </div>
        </section>

        {(error || success) && (
          <div className={`rounded-xl border px-4 py-3 text-sm ${error ? 'border-red-200 bg-red-50 text-red-700' : 'border-emerald-200 bg-emerald-50 text-emerald-800'}`}>
            {error || success}
          </div>
        )}

        <div className="grid gap-6 xl:grid-cols-[320px_minmax(0,1fr)]">
          <div className="space-y-6">
            <Card>
              <CardContent className="space-y-4">
                <div className="flex items-center justify-between">
                  <div>
                    <h2 className="font-semibold text-neutral-900">Transmittal history</h2>
                    <p className="text-xs text-neutral-500">Drafts and generated packets</p>
                  </div>
                  <Button size="sm" variant="outline" onClick={() => setForm(emptyForm())}><Plus className="h-4 w-4" /></Button>
                </div>
                {loading ? <p className="text-sm text-neutral-500">Loading…</p> : transmittals.length === 0 ? (
                  <div className="rounded-xl border border-dashed p-4 text-sm text-neutral-500">No transmittals yet.</div>
                ) : (
                  <div className="space-y-2">
                    {transmittals.map((transmittal) => (
                      <button
                        type="button"
                        key={transmittal.id}
                        onClick={() => loadTransmittal(transmittal.id)}
                        className={`w-full rounded-xl border p-3 text-left transition ${form.id === transmittal.id ? 'border-primary-300 bg-primary-50' : 'border-neutral-200 hover:border-primary-200 hover:bg-neutral-50'}`}
                      >
                        <div className="flex items-start justify-between gap-2">
                          <p className="line-clamp-2 text-sm font-semibold text-neutral-900">{transmittal.title}</p>
                          <Badge className={transmittal.source_kind === 'pay_period' ? 'bg-blue-100 text-blue-700' : 'bg-neutral-100 text-neutral-700'}>
                            {transmittal.source_kind === 'pay_period' ? 'Payroll' : 'Standalone'}
                          </Badge>
                        </div>
                        <div className="mt-2 flex justify-between text-xs text-neutral-500">
                          <span>{transmittal.item_count} included</span>
                          <span>{transmittal.artifact_count} versions</span>
                        </div>
                      </button>
                    ))}
                  </div>
                )}
              </CardContent>
            </Card>

            {form.artifacts.length > 0 && (
              <Card>
                <CardContent className="space-y-3">
                  <div>
                    <h2 className="font-semibold text-neutral-900">Generated versions</h2>
                    <p className="text-xs text-neutral-500">Immutable evidence of exactly what was produced</p>
                  </div>
                  {form.artifacts.map((artifact) => (
                    <div key={artifact.id} className="rounded-xl border border-neutral-200 p-3">
                      <div className="flex items-center justify-between gap-2">
                        <div>
                          <p className="text-sm font-semibold text-neutral-900">Version {artifact.version_number}</p>
                          <p className="text-xs text-neutral-500">{new Date(artifact.created_at).toLocaleString()} · {formatBytes(artifact.byte_size)}</p>
                        </div>
                        <FileClock className="h-4 w-4 text-primary-600" />
                      </div>
                      <p className="mt-2 truncate font-mono text-[10px] text-neutral-400" title={artifact.sha256}>SHA-256 {artifact.sha256}</p>
                      <div className="mt-3 flex gap-2">
                        <Button size="sm" variant="outline" className="flex-1" onClick={() => previewArtifact(artifact)}><Eye className="mr-1.5 h-3.5 w-3.5" />View</Button>
                        <Button size="sm" variant="outline" className="flex-1" onClick={() => downloadArtifact(artifact)}><Download className="mr-1.5 h-3.5 w-3.5" />Download</Button>
                      </div>
                    </div>
                  ))}
                </CardContent>
              </Card>
            )}
          </div>

          <div className="space-y-6">
            <Card>
              <CardContent className="space-y-6">
                <div className="flex flex-col gap-3 border-b border-neutral-200 pb-5 sm:flex-row sm:items-start sm:justify-between">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="text-xl font-semibold text-neutral-950">{form.id ? 'Customize transmittal' : 'New standalone transmittal'}</h2>
                      <Badge className={form.status === 'generated' ? 'bg-emerald-100 text-emerald-700' : 'bg-neutral-100 text-neutral-700'}>{form.status}</Badge>
                    </div>
                    {form.pay_period && (
                      <p className="mt-1 flex items-center gap-1.5 text-sm text-neutral-500">
                        <CalendarRange className="h-4 w-4" />
                        {dateOnly(form.pay_period.start_date)} – {dateOnly(form.pay_period.end_date)} · Pay date {dateOnly(form.pay_period.pay_date)}
                      </p>
                    )}
                  </div>
                  {form.source_kind === 'pay_period' && form.id && (
                    <Button variant="outline" onClick={refreshSources} disabled={busy}><RefreshCw className="mr-2 h-4 w-4" />Refresh sources</Button>
                  )}
                </div>

                <div className="grid gap-4 md:grid-cols-2">
                  <label className="space-y-1.5 md:col-span-2"><span className="text-sm font-medium">Title</span><Input value={form.title} onChange={(event) => setForm((current) => ({ ...current, title: event.target.value }))} placeholder="Client delivery packet" /></label>
                  <label className="space-y-1.5"><span className="text-sm font-medium">Transmittal date</span><Input type="date" value={form.transmittal_date} onChange={(event) => setForm((current) => ({ ...current, transmittal_date: event.target.value }))} /></label>
                  <label className="space-y-1.5"><span className="text-sm font-medium">Recipient</span><Input value={form.recipient_name} onChange={(event) => setForm((current) => ({ ...current, recipient_name: event.target.value }))} placeholder="Client or receiving party" /></label>
                  <label className="space-y-1.5 md:col-span-2"><span className="text-sm font-medium">Prepared by</span><Input value={form.preparer_name} onChange={(event) => setForm((current) => ({ ...current, preparer_name: event.target.value }))} placeholder="Cornerstone Tax Services" /></label>
                </div>

                <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                  <div className="flex flex-col gap-3 md:flex-row md:items-end">
                    <label className="flex-1 space-y-1.5">
                      <span className="text-sm font-medium">Add standalone check</span>
                      <select value={selectedCheckId} onChange={(event) => setSelectedCheckId(event.target.value)} className="h-10 w-full rounded-xl border border-neutral-300 bg-white px-3 text-sm">
                        <option value="">Choose a check…</option>
                        {standaloneChecks.map((check) => <option key={check.id} value={check.id}>{check.payable_to} · {currency(check.amount)}</option>)}
                      </select>
                    </label>
                    <Button variant="secondary" disabled={!selectedCheckId} onClick={addStandaloneCheck}><CheckSquare className="mr-2 h-4 w-4" />Add check</Button>
                    <Button variant="outline" onClick={addManualItem}><Plus className="mr-2 h-4 w-4" />Custom item</Button>
                  </div>
                </div>

                <div className="flex flex-wrap items-end justify-between gap-3">
                  <div>
                    <h3 className="font-semibold text-neutral-900">Packet contents</h3>
                    <p className="text-sm text-neutral-500">Include, exclude, relabel, annotate, and reorder before generation.</p>
                  </div>
                  <div className="text-right"><p className="text-xs uppercase tracking-[0.1em] text-neutral-400">Included total</p><p className="text-lg font-semibold">{currency(totalAmount)}</p></div>
                </div>

                {visibleItems.length === 0 ? (
                  <div className="rounded-xl border border-dashed border-neutral-300 p-8 text-center text-sm text-neutral-500">Start from a pay period or add a custom item.</div>
                ) : (
                  <div className="space-y-3">
                    {visibleItems.map((item, index) => (
                      <div key={item.local_id} className={`rounded-xl border p-4 transition-opacity ${itemTone[item.item_type] || itemTone.manual} ${item.included ? '' : 'opacity-55'}`}>
                        <div className="flex flex-col gap-3 lg:flex-row lg:items-start">
                          <label className="flex items-center gap-2 pt-2 text-sm font-medium text-neutral-800">
                            <input type="checkbox" checked={item.included} onChange={(event) => updateItem(item.local_id, { included: event.target.checked })} className="h-4 w-4 rounded border-neutral-300 text-primary-600" />
                            Include
                          </label>
                          <div className="grid min-w-0 flex-1 gap-3 md:grid-cols-2">
                            <label className="space-y-1 md:col-span-2"><span className="text-xs font-semibold uppercase tracking-[0.08em] text-neutral-500">Label</span><Input value={item.title} onChange={(event) => updateItem(item.local_id, { title: event.target.value })} /></label>
                            <label className="space-y-1"><span className="text-xs font-semibold uppercase tracking-[0.08em] text-neutral-500">Payable to</span><Input value={item.payable_to || ''} onChange={(event) => updateItem(item.local_id, { payable_to: event.target.value })} placeholder="Optional" /></label>
                            <label className="space-y-1"><span className="text-xs font-semibold uppercase tracking-[0.08em] text-neutral-500">Amount</span><Input type="number" step="0.01" min="0" value={item.amount ?? ''} onChange={(event) => updateItem(item.local_id, { amount: event.target.value === '' ? null : Number(event.target.value) })} /></label>
                            <label className="space-y-1 md:col-span-2"><span className="text-xs font-semibold uppercase tracking-[0.08em] text-neutral-500">Details / annotation</span><Textarea rows={2} value={item.details_text} onChange={(event) => updateItem(item.local_id, { details_text: event.target.value })} placeholder="One line per detail" /></label>
                            {item.item_type === 'tax_obligation' && <p className="md:col-span-2 text-xs font-medium text-amber-700">Calculated obligation only. This does not indicate that a payment was made.</p>}
                          </div>
                          <div className="flex gap-1 lg:flex-col">
                            <Button size="sm" variant="ghost" disabled={index === 0} onClick={() => moveItem(item.local_id, -1)} aria-label="Move item up"><ArrowUp className="h-4 w-4" /></Button>
                            <Button size="sm" variant="ghost" disabled={index === visibleItems.length - 1} onClick={() => moveItem(item.local_id, 1)} aria-label="Move item down"><ArrowDown className="h-4 w-4" /></Button>
                            <Button size="sm" variant="ghost" className="text-red-600" onClick={() => removeItem(item.local_id)} aria-label="Remove item"><Trash2 className="h-4 w-4" /></Button>
                          </div>
                        </div>
                      </div>
                    ))}
                  </div>
                )}

                <label className="space-y-1.5"><span className="text-sm font-medium">Packet notes</span><Textarea rows={3} value={form.notes_text} onChange={(event) => setForm((current) => ({ ...current, notes_text: event.target.value }))} placeholder="One note per line" /></label>

                <div className="flex flex-col gap-3 border-t border-neutral-200 pt-5 sm:flex-row sm:items-center sm:justify-between">
                  <div>{form.id && !form.artifacts.length && <Button variant="ghost" className="text-red-600" onClick={deleteDraft}><Trash2 className="mr-2 h-4 w-4" />Delete draft</Button>}</div>
                  <div className="flex flex-col gap-2 sm:flex-row">
                    <Button variant="outline" disabled={busy} onClick={() => save()}><Save className="mr-2 h-4 w-4" />Save draft</Button>
                    <Button variant="secondary" disabled={busy} onClick={previewCurrent}><Eye className="mr-2 h-4 w-4" />Preview</Button>
                    <Button disabled={busy} onClick={generate}><Download className="mr-2 h-4 w-4" />Generate version</Button>
                  </div>
                </div>
              </CardContent>
            </Card>
          </div>
        </div>
      </main>

      {previewUrl && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-neutral-950/70 p-4 backdrop-blur-sm">
          <div className="flex h-[92vh] w-full max-w-6xl flex-col overflow-hidden rounded-2xl bg-white shadow-2xl">
            <div className="flex items-center justify-between border-b px-5 py-4"><div className="flex items-center gap-2"><FileText className="h-5 w-5 text-primary-600" /><h3 className="font-semibold">Transmittal preview</h3></div><Button variant="outline" onClick={() => { URL.revokeObjectURL(previewUrl); setPreviewUrl(null); }}>Close</Button></div>
            <iframe title="Transmittal PDF preview" src={previewUrl} className="h-full w-full bg-neutral-100" />
          </div>
        </div>
      )}
    </div>
  );
}
