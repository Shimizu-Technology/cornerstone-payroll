import { useCallback, useEffect, useMemo, useState } from 'react';
import { CheckSquare, Download, Eye, FileText, Plus, Save, Trash2, X } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { generalTransmittalsApi, nonEmployeeChecksApi, type BlobDownload, type GeneralTransmittal, type GeneralTransmittalItem } from '@/services/api';
import { useCompany } from '@/contexts/CompanyContext';
import type { NonEmployeeCheck } from '@/types';

type DraftItem = Omit<GeneralTransmittalItem, 'details'> & {
  local_id: string;
  details_text: string;
  _destroy?: boolean;
};

interface FormState {
  id?: number;
  title: string;
  transmittal_date: string;
  preparer_name: string;
  recipient_name: string;
  notes_text: string;
  status?: GeneralTransmittal['status'];
  generated_at?: string | null;
  items: DraftItem[];
}

const today = () => new Date().toISOString().slice(0, 10);

const emptyForm = (): FormState => ({
  title: '',
  transmittal_date: today(),
  preparer_name: '',
  recipient_name: '',
  notes_text: '',
  items: [],
});

const statusColors: Record<string, string> = {
  draft: 'bg-gray-100 text-gray-700',
  generated: 'bg-green-100 text-green-700',
};

function currency(value?: number | null) {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(Number(value || 0));
}

function downloadBlob(blobData: BlobDownload, fallbackName: string) {
  const url = URL.createObjectURL(blobData.blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = blobData.filename || fallbackName;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

function previewBlob(blobData: BlobDownload) {
  return URL.createObjectURL(blobData.blob);
}

function detailsFromCheck(check: NonEmployeeCheck) {
  return [
    check.memo ? `For: ${check.memo}` : '',
    check.description ? `Description: ${check.description}` : '',
    check.reference_number ? `Reference: ${check.reference_number}` : '',
    check.confirmation_number ? `Confirmation: ${check.confirmation_number}` : '',
    check.payment_date ? `Payment date: ${new Date(check.payment_date).toLocaleDateString()}` : '',
  ].filter(Boolean).join('\n');
}

function checkTitle(check: NonEmployeeCheck) {
  const type = check.check_type.replace(/_/g, ' ').replace(/\b\w/g, (char) => char.toUpperCase());
  return `Check for ${check.payable_to} (${type})`;
}

export function GeneralTransmittals() {
  const { activeCompanyId } = useCompany();
  const [transmittals, setTransmittals] = useState<GeneralTransmittal[]>([]);
  const [standaloneChecks, setStandaloneChecks] = useState<NonEmployeeCheck[]>([]);
  const [form, setForm] = useState<FormState>(emptyForm);
  const [selectedCheckId, setSelectedCheckId] = useState('');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [pdfBusy, setPdfBusy] = useState(false);
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);

  const loadData = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [transmittalResponse, checksResponse] = await Promise.all([
        generalTransmittalsApi.list(),
        nonEmployeeChecksApi.list({ standalone: 'true', active: 'true' }),
      ]);
      setTransmittals(transmittalResponse.general_transmittals);
      setStandaloneChecks(checksResponse.non_employee_checks);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load general transmittals');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadData();
  }, [loadData, activeCompanyId]);

  useEffect(() => {
    return () => {
      if (previewUrl) URL.revokeObjectURL(previewUrl);
    };
  }, [previewUrl]);

  const activeItems = useMemo(() => form.items.filter((item) => !item._destroy), [form.items]);
  const totalAmount = useMemo(() => activeItems.reduce((sum, item) => sum + Number(item.amount || 0), 0), [activeItems]);

  const resetForm = () => {
    setForm(emptyForm());
    setSelectedCheckId('');
    setError(null);
    setSuccess(null);
  };

  const loadTransmittal = async (id: number) => {
    setError(null);
    try {
      const response = await generalTransmittalsApi.get(id);
      const transmittal = response.general_transmittal;
      setForm({
        id: transmittal.id,
        title: transmittal.title,
        transmittal_date: transmittal.transmittal_date,
        preparer_name: transmittal.preparer_name || '',
        recipient_name: transmittal.recipient_name || '',
        notes_text: (transmittal.notes || []).join('\n'),
        status: transmittal.status,
        generated_at: transmittal.generated_at,
        items: (transmittal.items || []).map((item) => ({
          ...item,
          local_id: `existing-${item.id}`,
          details_text: (item.details || []).join('\n'),
        })),
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load transmittal');
    }
  };

  const addStandaloneCheck = () => {
    const check = standaloneChecks.find((candidate) => String(candidate.id) === selectedCheckId);
    if (!check) return;
    if (activeItems.some((item) => item.source_type === 'NonEmployeeCheck' && item.source_id === check.id)) {
      setError('That standalone check is already included.');
      return;
    }

    setForm((current) => ({
      ...current,
      items: [
        ...current.items,
        {
          local_id: `check-${check.id}-${Date.now()}`,
          source_type: 'NonEmployeeCheck',
          source_id: check.id,
          item_type: 'check',
          title: checkTitle(check),
          payable_to: check.payable_to,
          check_number: check.check_number || '',
          amount: Number(check.amount),
          details_text: detailsFromCheck(check),
          position: current.items.length,
        },
      ],
    }));
    setSelectedCheckId('');
    setError(null);
  };

  const addManualItem = () => {
    setForm((current) => ({
      ...current,
      items: [
        ...current.items,
        {
          local_id: `manual-${Date.now()}`,
          item_type: 'manual',
          title: '',
          payable_to: '',
          check_number: '',
          amount: null,
          details_text: '',
          position: current.items.length,
        },
      ],
    }));
  };

  const updateItem = (localId: string, patch: Partial<DraftItem>) => {
    setForm((current) => ({
      ...current,
      items: current.items.map((item) => item.local_id === localId ? { ...item, ...patch } : item),
    }));
  };

  const removeItem = (localId: string) => {
    setForm((current) => ({
      ...current,
      items: current.items
        .map((item) => item.local_id === localId ? { ...item, _destroy: true } : item)
        .map((item, index) => ({ ...item, position: index })),
    }));
  };

  const buildPayload = () => ({
    title: form.title.trim(),
    transmittal_date: form.transmittal_date,
    preparer_name: form.preparer_name.trim() || null,
    recipient_name: form.recipient_name.trim() || null,
    notes: form.notes_text.split('\n').map((note) => note.trim()).filter(Boolean),
    items: form.items.map((item, index) => ({
      id: item.id,
      source_type: item.source_type || null,
      source_id: item.source_id || null,
      item_type: item.item_type || 'manual',
      title: item.title.trim(),
      payable_to: item.payable_to?.trim() || null,
      check_number: item.check_number?.trim() || null,
      amount: item.amount === null || item.amount === undefined ? null : Number(item.amount),
      details: item.details_text.split('\n').map((detail) => detail.trim()).filter(Boolean),
      position: index,
      _destroy: item._destroy,
    })),
  });

  const saveTransmittal = async () => {
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const payload = buildPayload();
      if (!payload.title) throw new Error('Title is required');
      if (!payload.transmittal_date) throw new Error('Date is required');
      if (activeItems.length === 0) throw new Error('Add at least one check or manual item');

      const response = form.id
        ? await generalTransmittalsApi.update(form.id, payload, form.status === 'generated')
        : await generalTransmittalsApi.create(payload);
      await loadData();
      await loadTransmittal(response.general_transmittal.id);
      setSuccess('General transmittal saved.');
      window.setTimeout(() => setSuccess(null), 3500);
      return response.general_transmittal.id;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save transmittal');
      return null;
    } finally {
      setSaving(false);
    }
  };

  const handlePreview = async () => {
    const id = form.id || await saveTransmittal();
    if (!id) return;
    setPdfBusy(true);
    setError(null);
    try {
      const blob = await generalTransmittalsApi.previewPdf(id);
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      setPreviewUrl(previewBlob(blob));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to preview PDF');
    } finally {
      setPdfBusy(false);
    }
  };

  const handleGenerate = async () => {
    const id = form.id || await saveTransmittal();
    if (!id) return;
    setPdfBusy(true);
    setError(null);
    try {
      const blob = await generalTransmittalsApi.generatePdf(id);
      downloadBlob(blob, 'general_transmittal.pdf');
      await loadData();
      await loadTransmittal(id);
      setSuccess('General transmittal generated.');
      window.setTimeout(() => setSuccess(null), 3500);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to generate PDF');
    } finally {
      setPdfBusy(false);
    }
  };

  const handleDelete = async (id: number) => {
    if (!confirm('Delete this general transmittal?')) return;
    setDeletingId(id);
    setError(null);
    try {
      await generalTransmittalsApi.delete(id);
      if (form.id === id) resetForm();
      await loadData();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete transmittal');
    } finally {
      setDeletingId(null);
    }
  };

  return (
    <div>
      <Header
        title="General Transmittals"
        description="Create standalone delivery transmittals for one-off checks, quarterly payments, returns, and other client packets."
      />

      <div className="grid gap-6 p-6 lg:grid-cols-[360px_minmax(0,1fr)] lg:p-8">
        <Card className="self-start">
          <CardContent className="space-y-4">
            <div className="flex items-center justify-between gap-3">
              <div>
                <h2 className="text-base font-semibold text-neutral-900">History</h2>
                <p className="text-sm text-neutral-500">Saved standalone transmittals</p>
              </div>
              <Button size="sm" variant="outline" onClick={resetForm}>
                <Plus className="mr-1.5 h-4 w-4" />
                New
              </Button>
            </div>

            {loading ? (
              <p className="text-sm text-neutral-500">Loading...</p>
            ) : transmittals.length === 0 ? (
              <div className="rounded-lg border border-dashed border-neutral-300 p-4 text-sm text-neutral-500">
                No general transmittals yet.
              </div>
            ) : (
              <div className="space-y-2">
                {transmittals.map((transmittal) => (
                  <button
                    key={transmittal.id}
                    type="button"
                    onClick={() => loadTransmittal(transmittal.id)}
                    className={`w-full rounded-lg border p-3 text-left transition-colors hover:border-primary-300 hover:bg-primary-50/40 ${
                      form.id === transmittal.id ? 'border-primary-300 bg-primary-50' : 'border-neutral-200 bg-white'
                    }`}
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <p className="truncate text-sm font-semibold text-neutral-900">{transmittal.title}</p>
                        <p className="text-xs text-neutral-500">
                          {new Date(transmittal.transmittal_date).toLocaleDateString()} · {transmittal.item_count} items
                        </p>
                      </div>
                      <Badge className={statusColors[transmittal.status] || 'bg-gray-100 text-gray-700'}>
                        {transmittal.status}
                      </Badge>
                    </div>
                    <div className="mt-2 flex items-center justify-between text-xs text-neutral-500">
                      <span>{currency(transmittal.total_amount)}</span>
                      <span>{transmittal.generated_at ? 'Generated' : 'Draft'}</span>
                    </div>
                  </button>
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        <div className="space-y-6">
          {(error || success) && (
            <div className={`rounded-xl border px-4 py-3 text-sm ${
              error ? 'border-red-200 bg-red-50 text-red-700' : 'border-green-200 bg-green-50 text-green-700'
            }`}>
              {error || success}
            </div>
          )}

          <Card>
            <CardContent className="space-y-6">
              <div className="flex flex-col gap-3 border-b border-neutral-200 pb-5 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <h2 className="text-lg font-semibold text-neutral-900">
                    {form.id ? 'Edit General Transmittal' : 'New General Transmittal'}
                  </h2>
                  <p className="text-sm text-neutral-500">
                    {activeItems.length} items · {currency(totalAmount)}
                    {form.generated_at && ` · Last generated ${new Date(form.generated_at).toLocaleDateString()}`}
                  </p>
                </div>
                {form.id && (
                  <Button
                    variant="outline"
                    size="sm"
                    className="text-red-600 hover:text-red-700"
                    onClick={() => handleDelete(form.id!)}
                    disabled={deletingId === form.id}
                  >
                    <Trash2 className="mr-1.5 h-4 w-4" />
                    Delete
                  </Button>
                )}
              </div>

              <div className="grid gap-4 md:grid-cols-2">
                <label className="space-y-1.5">
                  <span className="text-sm font-medium text-neutral-700">Title</span>
                  <Input value={form.title} onChange={(event) => setForm((current) => ({ ...current, title: event.target.value }))} placeholder="e.g. Q2 return checks" />
                </label>
                <label className="space-y-1.5">
                  <span className="text-sm font-medium text-neutral-700">Date</span>
                  <Input type="date" value={form.transmittal_date} onChange={(event) => setForm((current) => ({ ...current, transmittal_date: event.target.value }))} />
                </label>
                <label className="space-y-1.5">
                  <span className="text-sm font-medium text-neutral-700">Preparer</span>
                  <Input value={form.preparer_name} onChange={(event) => setForm((current) => ({ ...current, preparer_name: event.target.value }))} placeholder="Cornerstone Tax Services" />
                </label>
                <label className="space-y-1.5">
                  <span className="text-sm font-medium text-neutral-700">Recipient</span>
                  <Input value={form.recipient_name} onChange={(event) => setForm((current) => ({ ...current, recipient_name: event.target.value }))} placeholder="Optional recipient name" />
                </label>
              </div>

              <div className="rounded-xl border border-neutral-200 bg-neutral-50/70 p-4">
                <div className="flex flex-col gap-3 md:flex-row md:items-end">
                  <label className="flex-1 space-y-1.5">
                    <span className="text-sm font-medium text-neutral-700">Add Standalone Check</span>
                    <select
                      className="h-10 w-full rounded-xl border border-neutral-300 bg-white px-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary-300"
                      value={selectedCheckId}
                      onChange={(event) => setSelectedCheckId(event.target.value)}
                    >
                      <option value="">Select a standalone check...</option>
                      {standaloneChecks.map((check) => (
                        <option key={check.id} value={check.id}>
                          {check.payable_to} · {currency(check.amount)}{check.check_number ? ` · #${check.check_number}` : ''}
                        </option>
                      ))}
                    </select>
                  </label>
                  <Button type="button" variant="secondary" onClick={addStandaloneCheck} disabled={!selectedCheckId}>
                    <CheckSquare className="mr-1.5 h-4 w-4" />
                    Add Check
                  </Button>
                  <Button type="button" variant="outline" onClick={addManualItem}>
                    <Plus className="mr-1.5 h-4 w-4" />
                    Manual Item
                  </Button>
                </div>
              </div>

              <div className="space-y-3">
                <div className="flex items-center justify-between">
                  <h3 className="text-sm font-semibold uppercase tracking-[0.08em] text-neutral-500">Items</h3>
                  <span className="text-sm font-medium text-neutral-700">{currency(totalAmount)}</span>
                </div>

                {activeItems.length === 0 ? (
                  <div className="rounded-xl border border-dashed border-neutral-300 p-6 text-center text-sm text-neutral-500">
                    Add standalone checks or manual rows to build the transmittal.
                  </div>
                ) : (
                  <div className="space-y-3">
                    {activeItems.map((item, index) => (
                      <div key={item.local_id} className="rounded-xl border border-neutral-200 bg-white p-4">
                        <div className="mb-3 flex items-center justify-between gap-3">
                          <span className="text-xs font-semibold uppercase tracking-[0.08em] text-neutral-400">Item {index + 1}</span>
                          <button
                            type="button"
                            onClick={() => removeItem(item.local_id)}
                            className="rounded-lg p-1 text-neutral-400 hover:bg-red-50 hover:text-red-600"
                            aria-label="Remove item"
                          >
                            <X className="h-4 w-4" />
                          </button>
                        </div>
                        <div className="grid gap-3 md:grid-cols-2">
                          <label className="space-y-1.5 md:col-span-2">
                            <span className="text-sm font-medium text-neutral-700">Title</span>
                            <Input value={item.title} onChange={(event) => updateItem(item.local_id, { title: event.target.value })} placeholder="Item title" />
                          </label>
                          <label className="space-y-1.5">
                            <span className="text-sm font-medium text-neutral-700">Payable to</span>
                            <Input value={item.payable_to || ''} onChange={(event) => updateItem(item.local_id, { payable_to: event.target.value })} placeholder="Optional" />
                          </label>
                          <label className="space-y-1.5">
                            <span className="text-sm font-medium text-neutral-700">Check #</span>
                            <Input value={item.check_number || ''} onChange={(event) => updateItem(item.local_id, { check_number: event.target.value })} placeholder="Optional" />
                          </label>
                          <label className="space-y-1.5">
                            <span className="text-sm font-medium text-neutral-700">Amount</span>
                            <Input
                              type="number"
                              step="0.01"
                              min="0"
                              value={item.amount ?? ''}
                              onChange={(event) => updateItem(item.local_id, { amount: event.target.value ? Number(event.target.value) : null })}
                              placeholder="0.00"
                            />
                          </label>
                          <label className="space-y-1.5 md:col-span-2">
                            <span className="text-sm font-medium text-neutral-700">Details</span>
                            <Textarea
                              value={item.details_text}
                              onChange={(event) => updateItem(item.local_id, { details_text: event.target.value })}
                              placeholder="One detail per line"
                              rows={3}
                            />
                          </label>
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>

              <label className="space-y-1.5">
                <span className="text-sm font-medium text-neutral-700">Notes</span>
                <Textarea
                  value={form.notes_text}
                  onChange={(event) => setForm((current) => ({ ...current, notes_text: event.target.value }))}
                  placeholder="One note per line"
                  rows={3}
                />
              </label>

              <div className="flex flex-col-reverse gap-3 border-t border-neutral-200 pt-5 sm:flex-row sm:justify-end">
                <Button type="button" variant="outline" onClick={saveTransmittal} disabled={saving}>
                  <Save className="mr-1.5 h-4 w-4" />
                  {saving ? 'Saving...' : 'Save Draft'}
                </Button>
                <Button type="button" variant="secondary" onClick={handlePreview} disabled={saving || pdfBusy}>
                  <Eye className="mr-1.5 h-4 w-4" />
                  Preview PDF
                </Button>
                <Button type="button" onClick={handleGenerate} disabled={saving || pdfBusy}>
                  <Download className="mr-1.5 h-4 w-4" />
                  Generate PDF
                </Button>
              </div>
            </CardContent>
          </Card>
        </div>
      </div>

      {previewUrl && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="flex h-[88vh] w-full max-w-5xl flex-col overflow-hidden rounded-xl bg-white shadow-2xl">
            <div className="flex items-center justify-between border-b px-4 py-3">
              <div className="flex items-center gap-2">
                <FileText className="h-5 w-5 text-primary-600" />
                <h3 className="font-semibold text-neutral-900">General Transmittal Preview</h3>
              </div>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => {
                  URL.revokeObjectURL(previewUrl);
                  setPreviewUrl(null);
                }}
              >
                Close
              </Button>
            </div>
            <iframe title="General transmittal preview" src={previewUrl} className="h-full w-full" />
          </div>
        </div>
      )}
    </div>
  );
}
