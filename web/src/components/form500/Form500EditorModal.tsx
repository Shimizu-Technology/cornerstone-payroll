import { useCallback, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { Download, Eye, Loader2, Save } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { form500Api } from '@/services/api';
import type { BlobDownload, Form500Fields } from '@/services/api';

interface Form500EditorModalProps {
  open: boolean;
  onClose: () => void;
  payPeriodId: number;
}

const quarterOptions = [
  { value: 1, label: '1st Quarter' },
  { value: 2, label: '2nd Quarter' },
  { value: 3, label: '3rd Quarter' },
  { value: 4, label: '4th Quarter' },
];

export function Form500EditorModal({ open, onClose, payPeriodId }: Form500EditorModalProps) {
  const [form, setForm] = useState<Form500Fields | null>(null);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<string | null>(null);
  const [previewState, setPreviewState] = useState<{
    open: boolean;
    blobData: BlobDownload | null;
    pdfUrl: string | null;
    title: string;
  }>({ open: false, blobData: null, pdfUrl: null, title: 'Form 500 Preview' });

  const payPeriodLabel = useMemo(() => form?.period_label || '', [form]);

  const cleanupPreview = useCallback(() => {
    setPreviewState((prev) => {
      if (prev.pdfUrl) URL.revokeObjectURL(prev.pdfUrl);
      return { open: false, blobData: null, pdfUrl: null, title: 'Form 500 Preview' };
    });
  }, []);

  const loadForm = useCallback(async () => {
    if (!open) return;

    try {
      setLoading(true);
      setError(null);
      const response = await form500Api.defaults(payPeriodId);
      setForm(response.data);
      setSavedAt(response.saved_at || null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load Form 500');
    } finally {
      setLoading(false);
    }
  }, [open, payPeriodId]);

  useEffect(() => {
    if (!open) {
      cleanupPreview();
      return;
    }

    void loadForm();
  }, [cleanupPreview, loadForm, open]);

  useEffect(() => {
    if (!open) return;

    const handleEsc = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !previewState.open) onClose();
    };
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [onClose, open, previewState.open]);

  const updateField = <K extends keyof Form500Fields>(field: K, value: Form500Fields[K]) => {
    setForm((prev) => (prev ? { ...prev, [field]: value } : prev));
  };

  const saveForm = async () => {
    if (!form) return;

    try {
      setSaving(true);
      setError(null);
      const response = await form500Api.save({ ...form, pay_period_id: payPeriodId });
      setForm(response.data);
      setSavedAt(response.saved_at || null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save Form 500');
    } finally {
      setSaving(false);
    }
  };

  const openPdfPreview = async () => {
    if (!form) return;

    try {
      setSaving(true);
      setError(null);
      const file = await form500Api.preview({ ...form, pay_period_id: payPeriodId });
      if (previewState.pdfUrl) URL.revokeObjectURL(previewState.pdfUrl);
      const url = URL.createObjectURL(file.blob);
      setPreviewState({
        open: true,
        blobData: file,
        pdfUrl: url,
        title: payPeriodLabel ? `Form 500 · ${payPeriodLabel}` : 'Form 500 Preview',
      });
      await loadForm();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to preview Form 500');
    } finally {
      setSaving(false);
    }
  };

  const downloadPdf = async () => {
    if (!form) return;

    try {
      setSaving(true);
      setError(null);
      const file = await form500Api.download({ ...form, pay_period_id: payPeriodId });
      downloadBlob(file.blob, file.filename || buildForm500Filename(form));
      await loadForm();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to download Form 500');
    } finally {
      setSaving(false);
    }
  };

  const handlePreviewDownload = () => {
    if (!previewState.blobData) return;
    downloadBlob(previewState.blobData.blob, previewState.blobData.filename || (form ? buildForm500Filename(form) : 'form500.pdf'));
  };

  const handlePreviewPrint = () => {
    if (!previewState.pdfUrl) return;
    const printWindow = window.open(previewState.pdfUrl, '_blank');
    if (printWindow) {
      printWindow.addEventListener('load', () => {
        printWindow.print();
      });
    }
  };

  if (!open) return null;

  return createPortal(
    <>
      <div className="fixed inset-0 z-[60] bg-black/55" onClick={onClose} />
      <div className="fixed inset-0 z-[61] flex items-center justify-center p-4">
        <div className="flex max-h-[92vh] w-full max-w-6xl flex-col overflow-hidden rounded-2xl bg-white shadow-2xl">
          <div className="flex items-start justify-between border-b px-6 py-5">
            <div>
              <h2 className="text-2xl font-semibold text-gray-900">Form 500</h2>
              <p className="mt-1 text-sm text-gray-500">
                Save the official Guam deposit form to this pay period, preview it in-app, and reprint it later.
              </p>
              {payPeriodLabel ? <p className="mt-2 text-sm font-medium text-primary-700">{payPeriodLabel}</p> : null}
            </div>
            <div className="flex items-center gap-3">
              {savedAt ? (
                <span className="rounded-full bg-green-50 px-3 py-1 text-xs font-medium text-green-700">
                  Saved {new Date(savedAt).toLocaleString()}
                </span>
              ) : (
                <span className="rounded-full bg-amber-50 px-3 py-1 text-xs font-medium text-amber-700">Not saved yet</span>
              )}
              <Button variant="outline" onClick={onClose}>
                Close
              </Button>
            </div>
          </div>

          <div className="flex-1 overflow-y-auto bg-gray-50 px-6 py-6">
            {error ? (
              <div className="mb-4 rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">
                {error}
              </div>
            ) : null}

            {loading || !form ? (
              <div className="flex min-h-[360px] items-center justify-center rounded-2xl border border-neutral-200 bg-white">
                <div className="text-center">
                  <Loader2 className="mx-auto h-7 w-7 animate-spin text-primary-600" />
                  <p className="mt-3 text-sm text-neutral-500">Loading Form 500…</p>
                </div>
              </div>
            ) : (
              <div className="space-y-5">
                <div className="rounded-2xl border border-primary-200 bg-primary-50 px-4 py-3 text-sm text-primary-800">
                  This saved Form 500 stays attached to the pay period and renders onto the official Guam DRT Form 500 layout so payroll can preview, print, and reprint it without re-entering the filing details.
                </div>

                <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm">
                  <div className="grid gap-4 lg:grid-cols-2">
                    <Field label="Company Name">
                      <Input value={form.company_name} onChange={(event) => updateField('company_name', event.target.value)} />
                    </Field>
                    <Field label="Employer Identification Number">
                      <Input
                        value={form.employer_identification_number}
                        onChange={(event) => updateField('employer_identification_number', event.target.value)}
                      />
                    </Field>
                    <Field label="Address Line 1">
                      <Input value={form.company_address_line1} onChange={(event) => updateField('company_address_line1', event.target.value)} />
                    </Field>
                    <Field label="Address Line 2">
                      <Input value={form.company_address_line2} onChange={(event) => updateField('company_address_line2', event.target.value)} />
                    </Field>
                    <Field label="City">
                      <Input value={form.company_city} onChange={(event) => updateField('company_city', event.target.value)} />
                    </Field>
                    <Field label="State">
                      <Input value={form.company_state} onChange={(event) => updateField('company_state', event.target.value)} />
                    </Field>
                    <Field label="ZIP">
                      <Input value={form.company_zip} onChange={(event) => updateField('company_zip', event.target.value)} />
                    </Field>
                  </div>
                </section>

                <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm">
                  <div className="grid gap-4 lg:grid-cols-4">
                    <Field label="Tax Year">
                      <Input value={form.tax_year} onChange={(event) => updateField('tax_year', event.target.value)} />
                    </Field>
                    <Field label="Quarter">
                      <Select value={String(form.tax_period_quarter)} onChange={(event) => updateField('tax_period_quarter', Number(event.target.value))}>
                        {quarterOptions.map((option) => (
                          <option key={option.value} value={option.value}>
                            {option.label}
                          </option>
                        ))}
                      </Select>
                    </Field>
                    <Field label="Total Taxes Dollars">
                      <Input value={form.total_taxes_dollars} onChange={(event) => updateField('total_taxes_dollars', event.target.value)} />
                    </Field>
                    <Field label="Total Taxes Cents">
                      <Input value={form.total_taxes_cents} onChange={(event) => updateField('total_taxes_cents', event.target.value)} />
                    </Field>
                  </div>
                </section>

                <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm">
                  <p className="text-sm font-semibold text-gray-900">Tax Type</p>
                  <p className="mt-1 text-sm text-gray-500">Choose the filing type that matches this deposit.</p>
                  <div className="mt-4 grid gap-3 md:grid-cols-2">
                    <CheckboxField
                      label="Income tax withholding on wages"
                      checked={form.income_tax_withholding_on_wages}
                      onChange={(checked) => updateField('income_tax_withholding_on_wages', checked)}
                    />
                    <CheckboxField
                      label="30% tax withholding on certain persons"
                      checked={form.tax_withholding_30_percent}
                      onChange={(checked) => updateField('tax_withholding_30_percent', checked)}
                    />
                    <CheckboxField
                      label="Corporate estimated tax"
                      checked={form.corporate_estimated_tax}
                      onChange={(checked) => updateField('corporate_estimated_tax', checked)}
                    />
                    <CheckboxField
                      label="Income tax withholding on Form 1099s"
                      checked={form.income_tax_withholding_1099}
                      onChange={(checked) => updateField('income_tax_withholding_1099', checked)}
                    />
                  </div>
                </section>

                <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm">
                  <Field label="Notes">
                    <Textarea value={form.notes || ''} onChange={(event) => updateField('notes', event.target.value)} rows={4} />
                  </Field>
                </section>
              </div>
            )}
          </div>

          <div className="flex items-center justify-between gap-4 border-t bg-white px-6 py-4">
            <p className="text-sm text-neutral-500">Preview uses the same saved PDF payroll will print and reprint later.</p>
            <div className="flex flex-wrap items-center gap-3">
              <Button variant="outline" onClick={downloadPdf} disabled={loading || saving || !form}>
                <Download className="mr-2 h-4 w-4" />
                Download PDF
              </Button>
              <Button variant="outline" onClick={openPdfPreview} disabled={loading || saving || !form}>
                <Eye className="mr-2 h-4 w-4" />
                Preview PDF
              </Button>
              <Button onClick={saveForm} disabled={loading || saving || !form}>
                <Save className="mr-2 h-4 w-4" />
                {saving ? 'Working…' : 'Save Form 500'}
              </Button>
            </div>
          </div>
        </div>
      </div>

      <PdfPreviewOverlay
        open={previewState.open}
        title={previewState.title}
        pdfUrl={previewState.pdfUrl}
        onClose={cleanupPreview}
        onDownload={handlePreviewDownload}
        onPrint={handlePreviewPrint}
      />
    </>,
    document.body
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-medium text-gray-700">{label}</span>
      {children}
    </label>
  );
}

function CheckboxField({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label className="flex items-start gap-3 rounded-xl border border-neutral-200 px-4 py-3 text-sm text-gray-700">
      <input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} className="mt-1 h-4 w-4 shrink-0" />
      <span>{label}</span>
    </label>
  );
}

function PdfPreviewOverlay({
  open,
  title,
  pdfUrl,
  onClose,
  onDownload,
  onPrint,
}: {
  open: boolean;
  title: string;
  pdfUrl: string | null;
  onClose: () => void;
  onDownload: () => void;
  onPrint: () => void;
}) {
  useEffect(() => {
    if (!open) return;
    const handleEsc = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [onClose, open]);

  if (!open) return null;

  return createPortal(
    <div className="fixed inset-0 z-[70] flex flex-col">
      <div className="fixed inset-0 bg-black/70" onClick={onClose} />
      <div className="relative z-[71] m-3 flex h-full flex-col sm:m-6">
        <div className="flex items-center justify-between rounded-t-lg bg-gray-900 px-4 py-3 text-white">
          <h3 className="mr-4 truncate text-sm font-semibold sm:text-base">{title}</h3>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={onPrint}
              className="rounded bg-white/10 px-3 py-1.5 text-xs font-medium transition-colors hover:bg-white/20"
            >
              Print
            </button>
            <button
              type="button"
              onClick={onDownload}
              className="rounded bg-white/10 px-3 py-1.5 text-xs font-medium transition-colors hover:bg-white/20"
            >
              Download PDF
            </button>
            <button
              type="button"
              onClick={onClose}
              className="rounded bg-white/10 px-3 py-1.5 text-xs font-medium transition-colors hover:bg-white/20"
            >
              Close
            </button>
          </div>
        </div>

        <div className="min-h-0 flex-1 overflow-hidden rounded-b-lg bg-gray-200">
          {pdfUrl ? (
            <iframe src={pdfUrl} title={title} className="h-full w-full border-0 bg-white" />
          ) : (
            <div className="flex h-full items-center justify-center">
              <div className="text-center text-gray-500">
                <Loader2 className="mx-auto h-7 w-7 animate-spin" />
                <p className="mt-3 text-sm font-medium">Generating Form 500 PDF…</p>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>,
    document.body
  );
}

function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const link = window.document.createElement('a');
  link.href = url;
  link.download = filename;
  window.document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function buildForm500Filename(form: Form500Fields) {
  return `form500_${form.tax_year}_q${form.tax_period_quarter}.pdf`;
}
