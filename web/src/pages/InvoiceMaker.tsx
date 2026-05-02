import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Bot, Copy, Download, Eye, FileText, ImagePlus, Mail, Plus, ReceiptText, Save, Send, Sparkles, Trash2, X } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import {
  invoiceRecipientsApi,
  invoiceChatSessionsApi,
  invoicesApi,
  type BlobDownload,
  type InvoiceAiPreview,
  type InvoiceChatSession,
  type Invoice,
  type InvoiceLineItem,
  type InvoicePayload,
  type InvoiceRecipient,
  type InvoiceRecipientPayload,
  type InvoiceStatus,
  type InvoiceTemplateType,
} from '@/services/api';
import { useCompany } from '@/contexts/CompanyContext';

type DraftLineItem = InvoiceLineItem & {
  local_id: string;
  _destroy?: boolean;
};

interface InvoiceFormState {
  id?: number;
  invoice_recipient_id: string;
  invoice_number: string;
  invoice_date: string;
  service_period_start: string;
  service_period_end: string;
  notes: string;
  payment_terms: string;
  email_subject: string;
  email_body: string;
  status?: InvoiceStatus;
  generated_at?: string | null;
  line_items: DraftLineItem[];
}

interface RecipientFormState {
  id?: number;
  name: string;
  email: string;
  address: string;
  default_rate: string;
  invoice_prefix: string;
  payment_terms: string;
  template_type: InvoiceTemplateType;
  notes: string;
  active: boolean;
}

const padDatePart = (value: number) => String(value).padStart(2, '0');

const today = () => {
  const now = new Date();
  return `${now.getFullYear()}-${padDatePart(now.getMonth() + 1)}-${padDatePart(now.getDate())}`;
};

const emptyInvoiceForm = (): InvoiceFormState => ({
  invoice_recipient_id: '',
  invoice_number: '',
  invoice_date: today(),
  service_period_start: '',
  service_period_end: '',
  notes: '',
  payment_terms: '',
  email_subject: '',
  email_body: '',
  line_items: [],
});

const emptyRecipientForm = (): RecipientFormState => ({
  name: '',
  email: '',
  address: '',
  default_rate: '',
  invoice_prefix: '',
  payment_terms: '',
  template_type: 'standard',
  notes: '',
  active: true,
});

const statusColors: Record<InvoiceStatus, string> = {
  draft: 'bg-gray-100 text-gray-700',
  generated: 'bg-blue-100 text-blue-700',
  sent: 'bg-amber-100 text-amber-700',
  paid: 'bg-green-100 text-green-700',
  voided: 'bg-red-100 text-red-700',
  archived: 'bg-neutral-200 text-neutral-700',
};

const statusActions: Partial<Record<InvoiceStatus, InvoiceStatus[]>> = {
  generated: ['sent', 'voided', 'archived'],
  sent: ['paid', 'voided', 'archived'],
  paid: ['voided', 'archived'],
  voided: ['archived'],
};

function currency(value?: number | null) {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(Number(value || 0));
}

function previewTotal(preview?: InvoiceAiPreview | Record<string, never> | null) {
  const lineItems = (preview as InvoiceAiPreview | null | undefined)?.line_items || [];
  return lineItems.reduce(
    (sum, item) => sum + Number(item.quantity || 0) * Number(item.rate || 0),
    0
  );
}

function localDateFromDateOnly(value?: string | null) {
  if (!value) return null;
  const [year, month, day] = value.slice(0, 10).split('-').map(Number);
  if (!year || !month || !day) return null;
  return new Date(year, month - 1, day);
}

function formatDateOnly(value?: string | null) {
  const date = localDateFromDateOnly(value);
  return date ? date.toLocaleDateString() : '';
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

function invoicePayloadSignature(payload: InvoicePayload) {
  return JSON.stringify(payload);
}

export function InvoiceMaker() {
  const { activeCompanyId } = useCompany();
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [recipients, setRecipients] = useState<InvoiceRecipient[]>([]);
  const [invoiceForm, setInvoiceForm] = useState<InvoiceFormState>(emptyInvoiceForm);
  const [recipientForm, setRecipientForm] = useState<RecipientFormState>(emptyRecipientForm);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [pdfBusy, setPdfBusy] = useState(false);
  const [statusBusy, setStatusBusy] = useState(false);
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const [recipientSaving, setRecipientSaving] = useState(false);
  const [showRecipientForm, setShowRecipientForm] = useState(false);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [chatSessions, setChatSessions] = useState<InvoiceChatSession[]>([]);
  const [activeChatSession, setActiveChatSession] = useState<InvoiceChatSession | null>(null);
  const [chatInput, setChatInput] = useState('');
  const [chatImages, setChatImages] = useState<File[]>([]);
  const [chatBusy, setChatBusy] = useState(false);
  const savedInvoiceSignatureRef = useRef<string | null>(null);

  const loadData = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [invoiceResponse, recipientResponse, chatResponse] = await Promise.all([
        invoicesApi.list(),
        invoiceRecipientsApi.list({ active: true }),
        invoiceChatSessionsApi.list(),
      ]);
      setInvoices(invoiceResponse.invoices);
      setRecipients(recipientResponse.invoice_recipients);
      setChatSessions(chatResponse.invoice_chat_sessions);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load invoices');
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

  const activeLineItems = useMemo(
    () => invoiceForm.line_items.filter((item) => !item._destroy),
    [invoiceForm.line_items]
  );

  const invoiceTotal = useMemo(
    () => activeLineItems.reduce((sum, item) => sum + Number(item.quantity || 0) * Number(item.rate || 0), 0),
    [activeLineItems]
  );

  const selectedRecipient = useMemo(
    () => recipients.find((recipient) => String(recipient.id) === invoiceForm.invoice_recipient_id),
    [invoiceForm.invoice_recipient_id, recipients]
  );
  const activeRecipients = useMemo(() => recipients.filter((recipient) => recipient.active), [recipients]);
  const activePreview = activeChatSession?.current_preview as InvoiceAiPreview | undefined;
  const previewLineItems = activePreview?.line_items || [];

  const buildPayloadForForm = (state: InvoiceFormState): InvoicePayload => ({
    invoice_recipient_id: Number(state.invoice_recipient_id),
    invoice_number: state.invoice_number.trim() || null,
    invoice_date: state.invoice_date,
    service_period_start: state.service_period_start || null,
    service_period_end: state.service_period_end || null,
    notes: state.notes.trim() || null,
    payment_terms: state.payment_terms.trim() || null,
    email_subject: state.email_subject.trim() || null,
    email_body: state.email_body.trim() || null,
    line_items: state.line_items.map((item, index) => ({
      id: item.id,
      description: item.description.trim(),
      quantity: Number(item.quantity || 0),
      rate: Number(item.rate || 0),
      service_date: item.service_date || null,
      position: index,
      _destroy: item._destroy,
    })),
  });

  const buildPayload = () => buildPayloadForForm(invoiceForm);

  const hasUnsavedInvoiceChanges = () => {
    const savedSignature = savedInvoiceSignatureRef.current || invoicePayloadSignature(buildPayloadForForm(emptyInvoiceForm()));
    return invoicePayloadSignature(buildPayload()) !== savedSignature;
  };

  const resetInvoiceForm = () => {
    const nextForm = emptyInvoiceForm();
    setInvoiceForm(nextForm);
    savedInvoiceSignatureRef.current = invoicePayloadSignature(buildPayloadForForm(nextForm));
    setError(null);
    setSuccess(null);
  };

  const hydrateInvoiceForm = (invoice: Invoice) => {
    if (invoice.invoice_recipient) {
      setRecipients((current) => {
        if (current.some((recipient) => recipient.id === invoice.invoice_recipient!.id)) return current;
        return [...current, invoice.invoice_recipient!].sort((a, b) => a.name.localeCompare(b.name));
      });
    }

    const nextForm: InvoiceFormState = {
      id: invoice.id,
      invoice_recipient_id: String(invoice.invoice_recipient_id),
      invoice_number: invoice.invoice_number || '',
      invoice_date: invoice.invoice_date,
      service_period_start: invoice.service_period_start || '',
      service_period_end: invoice.service_period_end || '',
      notes: invoice.notes || '',
      payment_terms: invoice.payment_terms || '',
      email_subject: invoice.email_subject || '',
      email_body: invoice.email_body || '',
      status: invoice.status,
      generated_at: invoice.generated_at,
      line_items: (invoice.line_items || []).map((item) => ({
        ...item,
        local_id: `existing-${item.id}`,
      })),
    };
    setInvoiceForm(nextForm);
    savedInvoiceSignatureRef.current = invoicePayloadSignature(buildPayloadForForm(nextForm));
  };

  const applyPreviewToForm = (preview: InvoiceAiPreview) => {
    const recipientId = preview.invoice_recipient_id ? String(preview.invoice_recipient_id) : '';
    const nextForm: InvoiceFormState = {
      invoice_recipient_id: recipientId,
      invoice_number: '',
      invoice_date: preview.invoice_date || today(),
      service_period_start: preview.service_period_start || '',
      service_period_end: preview.service_period_end || '',
      notes: preview.notes || '',
      payment_terms: preview.payment_terms || '',
      email_subject: preview.email_subject || '',
      email_body: preview.email_body || '',
      status: 'draft',
      generated_at: null,
      line_items: (preview.line_items || []).map((item, index) => ({
        local_id: `ai-${Date.now()}-${index}`,
        description: item.description,
        quantity: Number(item.quantity || 0),
        rate: Number(item.rate || 0),
        amount: Number(item.quantity || 0) * Number(item.rate || 0),
        service_date: item.service_date || '',
        position: index,
      })),
    };
    setInvoiceForm(nextForm);
    savedInvoiceSignatureRef.current = invoicePayloadSignature(buildPayloadForForm(emptyInvoiceForm()));
  };

  const loadInvoice = async (id: number) => {
    setError(null);
    try {
      const response = await invoicesApi.get(id);
      hydrateInvoiceForm(response.invoice);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load invoice');
    }
  };

  const handleSelectInvoice = (id: number) => {
    if (hasUnsavedInvoiceChanges() && !window.confirm('Discard unsaved invoice changes?')) return;
    loadInvoice(id);
  };

  const handleNewInvoice = () => {
    if (hasUnsavedInvoiceChanges() && !window.confirm('Discard unsaved invoice changes?')) return;
    resetInvoiceForm();
  };

  const applyRecipientDefaults = (recipientId: string) => {
    const recipient = recipients.find((candidate) => String(candidate.id) === recipientId);
    setInvoiceForm((current) => ({
      ...current,
      invoice_recipient_id: recipientId,
      payment_terms: recipient?.payment_terms || current.payment_terms,
      email_subject: recipient
        ? `Invoice ${current.invoice_number || ''} from Cornerstone Payroll`.trim()
        : current.email_subject,
      email_body: recipient
        ? `Hi ${recipient.name},\n\nPlease find the attached invoice for your records.\n\nThank you,`
        : current.email_body,
    }));
  };

  const addLineItem = () => {
    const defaultRate = selectedRecipient?.default_rate || 0;
    setInvoiceForm((current) => ({
      ...current,
      line_items: [
        ...current.line_items,
        {
          local_id: `line-${Date.now()}`,
          description: '',
          quantity: 1,
          rate: defaultRate,
          amount: defaultRate,
          service_date: '',
          position: current.line_items.length,
        },
      ],
    }));
  };

  const updateLineItem = (localId: string, patch: Partial<DraftLineItem>) => {
    setInvoiceForm((current) => ({
      ...current,
      line_items: current.line_items.map((item) => item.local_id === localId ? { ...item, ...patch } : item),
    }));
  };

  const removeLineItem = (localId: string) => {
    setInvoiceForm((current) => ({
      ...current,
      line_items: current.line_items
        .map((item) => item.local_id === localId ? { ...item, _destroy: true } : item)
        .map((item, index) => ({ ...item, position: index })),
    }));
  };

  const saveInvoice = async ({
    markDraft = invoiceForm.status !== 'draft' && invoiceForm.status !== undefined,
    reloadAfterSave = true,
    successMessage = 'Invoice saved.',
  } = {}) => {
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const payload = buildPayload();
      if (!payload.invoice_recipient_id) throw new Error('Bill To recipient is required');
      if (!payload.invoice_date) throw new Error('Invoice date is required');

      const response = invoiceForm.id
        ? await invoicesApi.update(invoiceForm.id, payload, markDraft)
        : await invoicesApi.create(payload);
      savedInvoiceSignatureRef.current = invoicePayloadSignature(payload);
      if (reloadAfterSave) {
        await loadData();
        await loadInvoice(response.invoice.id);
      }
      setSuccess(successMessage);
      window.setTimeout(() => setSuccess(null), 3500);
      return response.invoice.id;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save invoice');
      return null;
    } finally {
      setSaving(false);
    }
  };

  const handleSaveDraft = () => {
    if (invoiceForm.status && invoiceForm.status !== 'draft') {
      const confirmed = window.confirm(
        'This invoice has already moved beyond draft. Saving a draft will clear generated, sent, and paid timestamps. Continue?'
      );
      if (!confirmed) return;
    }

    saveInvoice();
  };

  const ensureReadyForPdf = () => {
    if (activeLineItems.length > 0) return true;
    setError('Add at least one line item before previewing or generating a PDF.');
    setSuccess(null);
    return false;
  };

  const confirmDraftResetForFinalizedEdits = (action: string) => {
    if (!invoiceForm.status || invoiceForm.status === 'draft' || !hasUnsavedInvoiceChanges()) return true;

    return window.confirm(
      `This invoice has already moved beyond draft. To ${action}, the current edits must be saved as a draft and generated/sent/paid timestamps will be cleared. Continue?`
    );
  };

  const handlePreview = async () => {
    if (!ensureReadyForPdf()) return;
    if (!confirmDraftResetForFinalizedEdits('preview the updated PDF')) return;

    const shouldMarkDraft = Boolean(invoiceForm.status && invoiceForm.status !== 'draft' && hasUnsavedInvoiceChanges());
    const id = invoiceForm.status && invoiceForm.status !== 'draft' && invoiceForm.id && !shouldMarkDraft
      ? invoiceForm.id
      : await saveInvoice({ markDraft: shouldMarkDraft, successMessage: shouldMarkDraft ? 'Invoice saved as draft for preview.' : undefined });
    if (!id) return;

    setPdfBusy(true);
    setError(null);
    try {
      const blob = await invoicesApi.previewPdf(id);
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      setPreviewUrl(previewBlob(blob));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to preview PDF');
    } finally {
      setPdfBusy(false);
    }
  };

  const handleGenerate = async () => {
    if (!ensureReadyForPdf()) return;
    if (!confirmDraftResetForFinalizedEdits('regenerate the PDF')) return;

    const shouldMarkDraft = Boolean(invoiceForm.status && invoiceForm.status !== 'draft' && hasUnsavedInvoiceChanges());
    const id = invoiceForm.status && invoiceForm.status !== 'draft' && invoiceForm.id && !shouldMarkDraft
      ? invoiceForm.id
      : await saveInvoice({
        markDraft: shouldMarkDraft,
        reloadAfterSave: false,
        successMessage: shouldMarkDraft ? 'Invoice saved as draft before regeneration.' : undefined,
      });
    if (!id) return;

    setPdfBusy(true);
    setError(null);
    try {
      const blob = await invoicesApi.generatePdf(id);
      downloadBlob(blob, 'invoice.pdf');
      await loadData();
      await loadInvoice(id);
      setSuccess('Invoice generated.');
      window.setTimeout(() => setSuccess(null), 3500);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to generate PDF');
    } finally {
      setPdfBusy(false);
    }
  };

  const handleDeleteInvoice = async (id: number) => {
    if (!window.confirm('Delete this draft invoice?')) return;
    setDeletingId(id);
    setError(null);
    try {
      await invoicesApi.delete(id);
      if (invoiceForm.id === id) resetInvoiceForm();
      await loadData();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete invoice');
    } finally {
      setDeletingId(null);
    }
  };

  const handleStatusChange = async (status: InvoiceStatus) => {
    if (!invoiceForm.id) return;
    setStatusBusy(true);
    setError(null);
    try {
      const response = await invoicesApi.updateStatus(invoiceForm.id, status);
      await loadData();
      hydrateInvoiceForm(response.invoice);
      setSuccess(`Invoice marked ${status}.`);
      window.setTimeout(() => setSuccess(null), 3500);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to update invoice status');
    } finally {
      setStatusBusy(false);
    }
  };

  const startChatSession = async () => {
    setChatBusy(true);
    setError(null);
    try {
      const response = await invoiceChatSessionsApi.create({ title: 'Invoice Assistant' });
      setActiveChatSession(response.invoice_chat_session);
      setChatSessions((current) => [response.invoice_chat_session, ...current]);
      return response.invoice_chat_session;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to start invoice assistant');
      return null;
    } finally {
      setChatBusy(false);
    }
  };

  const loadChatSession = async (sessionId: number) => {
    setChatBusy(true);
    setError(null);
    try {
      const response = await invoiceChatSessionsApi.get(sessionId);
      setActiveChatSession(response.invoice_chat_session);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load assistant session');
    } finally {
      setChatBusy(false);
    }
  };

  const sendChatMessage = async () => {
    const content = chatInput.trim();
    if (!content) return;

    setChatBusy(true);
    setError(null);
    let createdSessionId: number | null = null;
    try {
      let session = activeChatSession;
      if (!session) {
        const createResponse = await invoiceChatSessionsApi.create({ title: content.slice(0, 60) });
        session = createResponse.invoice_chat_session;
        createdSessionId = session.id;
      }
      setActiveChatSession(session);
      const response = await invoiceChatSessionsApi.message(session.id, content, chatImages);
      setActiveChatSession(response.invoice_chat_session);
      setChatSessions((current) => {
        const withoutSession = current.filter((candidate) => candidate.id !== response.invoice_chat_session.id);
        return [response.invoice_chat_session, ...withoutSession];
      });
      setChatInput('');
      setChatImages([]);
    } catch (err) {
      if (createdSessionId) {
        await invoiceChatSessionsApi.delete(createdSessionId).catch(() => undefined);
        setActiveChatSession(null);
        setChatSessions((current) => current.filter((session) => session.id !== createdSessionId));
      }
      setError(err instanceof Error ? err.message : 'Failed to ask invoice assistant');
    } finally {
      setChatBusy(false);
    }
  };

  const createInvoiceFromPreview = async () => {
    if (!activeChatSession) return;
    if (hasUnsavedInvoiceChanges() && !window.confirm('Discard unsaved invoice changes?')) return;

    setChatBusy(true);
    setError(null);
    try {
      const response = await invoiceChatSessionsApi.confirm(activeChatSession.id);
      hydrateInvoiceForm(response.invoice);
      setActiveChatSession(response.invoice_chat_session);
      await loadData();
      setSuccess('Invoice created from AI preview.');
      window.setTimeout(() => setSuccess(null), 3500);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create invoice from preview');
    } finally {
      setChatBusy(false);
    }
  };

  const usePreviewAsDraft = () => {
    const preview = activeChatSession?.current_preview as InvoiceAiPreview | undefined;
    if (!preview || preview.status !== 'preview') return;
    if (hasUnsavedInvoiceChanges() && !window.confirm('Discard unsaved invoice changes?')) return;

    applyPreviewToForm(preview);
    setSuccess('AI preview loaded as an unsaved draft.');
    window.setTimeout(() => setSuccess(null), 3500);
  };

  const copyEmail = async () => {
    const content = [invoiceForm.email_subject, '', invoiceForm.email_body].join('\n');
    try {
      await navigator.clipboard.writeText(content.trim());
      setError(null);
      setSuccess('Email copy copied to clipboard.');
      window.setTimeout(() => setSuccess(null), 3500);
    } catch {
      setSuccess(null);
      setError('Unable to copy email text. Please select and copy it manually.');
    }
  };

  const buildRecipientPayload = (): InvoiceRecipientPayload => ({
    name: recipientForm.name.trim(),
    email: recipientForm.email.trim() || null,
    address: recipientForm.address.trim() || null,
    default_rate: recipientForm.default_rate ? Number(recipientForm.default_rate) : null,
    invoice_prefix: recipientForm.invoice_prefix.trim() || null,
    payment_terms: recipientForm.payment_terms.trim() || null,
    template_type: recipientForm.template_type,
    notes: recipientForm.notes.trim() || null,
    active: recipientForm.active,
  });

  const editRecipient = (recipient: InvoiceRecipient) => {
    setRecipientForm({
      id: recipient.id,
      name: recipient.name,
      email: recipient.email || '',
      address: recipient.address || '',
      default_rate: recipient.default_rate === null || recipient.default_rate === undefined ? '' : String(recipient.default_rate),
      invoice_prefix: recipient.invoice_prefix || '',
      payment_terms: recipient.payment_terms || '',
      template_type: recipient.template_type,
      notes: recipient.notes || '',
      active: recipient.active,
    });
    setShowRecipientForm(true);
  };

  const saveRecipient = async () => {
    setRecipientSaving(true);
    setError(null);
    try {
      const payload = buildRecipientPayload();
      if (!payload.name) throw new Error('Recipient name is required');
      const response = recipientForm.id
        ? await invoiceRecipientsApi.update(recipientForm.id, payload)
        : await invoiceRecipientsApi.create(payload);
      await loadData();
      setInvoiceForm((current) => current.invoice_recipient_id ? current : { ...current, invoice_recipient_id: String(response.invoice_recipient.id) });
      setRecipientForm(emptyRecipientForm());
      setShowRecipientForm(false);
      setSuccess('Recipient saved.');
      window.setTimeout(() => setSuccess(null), 3500);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save recipient');
    } finally {
      setRecipientSaving(false);
    }
  };

  return (
    <div>
      <Header
        title="Invoice Maker"
        description="Create standalone invoices with recipients, line items, PDF output, email copy, and status tracking."
      />

      <div className="grid gap-6 p-6 lg:grid-cols-[360px_minmax(0,1fr)] lg:p-8">
        <div className="space-y-6">
          <Card>
            <CardContent className="space-y-4">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <h2 className="text-base font-semibold text-neutral-900">Invoice History</h2>
                  <p className="text-sm text-neutral-500">Saved invoices for the active company</p>
                </div>
                <Button size="sm" variant="outline" onClick={handleNewInvoice}>
                  <Plus className="mr-1.5 h-4 w-4" />
                  New
                </Button>
              </div>

              {loading ? (
                <p className="text-sm text-neutral-500">Loading...</p>
              ) : invoices.length === 0 ? (
                <div className="rounded-lg border border-dashed border-neutral-300 p-4 text-sm text-neutral-500">
                  No invoices yet.
                </div>
              ) : (
                <div className="space-y-2">
                  {invoices.map((invoice) => (
                    <button
                      key={invoice.id}
                      type="button"
                      onClick={() => handleSelectInvoice(invoice.id)}
                      className={`w-full rounded-lg border p-3 text-left transition-colors hover:border-primary-300 hover:bg-primary-50/40 ${
                        invoiceForm.id === invoice.id ? 'border-primary-300 bg-primary-50' : 'border-neutral-200 bg-white'
                      }`}
                    >
                      <div className="flex items-start justify-between gap-3">
                        <div className="min-w-0">
                          <p className="truncate text-sm font-semibold text-neutral-900">{invoice.invoice_number}</p>
                          <p className="truncate text-xs text-neutral-500">{invoice.recipient_name || 'No recipient'}</p>
                        </div>
                        <Badge className={statusColors[invoice.status]}>{invoice.status}</Badge>
                      </div>
                      <div className="mt-2 flex items-center justify-between text-xs text-neutral-500">
                        <span>{formatDateOnly(invoice.invoice_date)}</span>
                        <span className="font-medium text-neutral-700">{currency(invoice.total_amount)}</span>
                      </div>
                    </button>
                  ))}
                </div>
              )}
            </CardContent>
          </Card>

          <Card>
            <CardContent className="space-y-4">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <h2 className="text-base font-semibold text-neutral-900">Recipients</h2>
                  <p className="text-sm text-neutral-500">Bill-to profiles and defaults</p>
                </div>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => {
                    setRecipientForm(emptyRecipientForm());
                    setShowRecipientForm((value) => !value);
                  }}
                >
                  <Plus className="mr-1.5 h-4 w-4" />
                  Add
                </Button>
              </div>

              {showRecipientForm && (
                <div className="space-y-3 rounded-xl border border-neutral-200 bg-neutral-50/70 p-3">
                  <Input value={recipientForm.name} onChange={(event) => setRecipientForm((current) => ({ ...current, name: event.target.value }))} placeholder="Recipient name" />
                  <Input value={recipientForm.email} onChange={(event) => setRecipientForm((current) => ({ ...current, email: event.target.value }))} placeholder="Email" />
                  <Textarea value={recipientForm.address} onChange={(event) => setRecipientForm((current) => ({ ...current, address: event.target.value }))} placeholder="Address" rows={2} />
                  <div className="grid grid-cols-2 gap-2">
                    <Input type="number" step="0.01" value={recipientForm.default_rate} onChange={(event) => setRecipientForm((current) => ({ ...current, default_rate: event.target.value }))} placeholder="Default rate" />
                    <Input value={recipientForm.invoice_prefix} onChange={(event) => setRecipientForm((current) => ({ ...current, invoice_prefix: event.target.value }))} placeholder="Prefix" />
                  </div>
                  <Textarea value={recipientForm.payment_terms} onChange={(event) => setRecipientForm((current) => ({ ...current, payment_terms: event.target.value }))} placeholder="Payment terms" rows={2} />
                  <div className="flex justify-end gap-2">
                    <Button size="sm" variant="ghost" onClick={() => setShowRecipientForm(false)}>Cancel</Button>
                    <Button size="sm" onClick={saveRecipient} disabled={recipientSaving}>
                      {recipientSaving ? 'Saving...' : 'Save Recipient'}
                    </Button>
                  </div>
                </div>
              )}

              <div className="max-h-80 space-y-2 overflow-y-auto pr-1">
                {activeRecipients.map((recipient) => (
                  <button
                    key={recipient.id}
                    type="button"
                    onClick={() => editRecipient(recipient)}
                    className="w-full rounded-lg border border-neutral-200 bg-white p-3 text-left text-sm transition-colors hover:border-primary-300 hover:bg-primary-50/40"
                  >
                    <span className="font-medium text-neutral-900">{recipient.name}</span>
                    <span className="block truncate text-xs text-neutral-500">{recipient.email || recipient.payment_terms || 'No defaults set'}</span>
                  </button>
                ))}
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardContent className="space-y-4">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <h2 className="flex items-center gap-2 text-base font-semibold text-neutral-900">
                    <Bot className="h-4 w-4 text-primary-600" />
                    AI Invoice Assistant
                  </h2>
                  <p className="text-sm text-neutral-500">Structured invoice drafts for staff approval</p>
                </div>
                <Button size="sm" variant="outline" onClick={startChatSession} disabled={chatBusy}>
                  <Plus className="mr-1.5 h-4 w-4" />
                  New
                </Button>
              </div>

              {chatSessions.length > 0 && (
                <div className="flex gap-2 overflow-x-auto pb-1">
                  {chatSessions.slice(0, 6).map((session) => (
                    <button
                      key={session.id}
                      type="button"
                      onClick={() => loadChatSession(session.id)}
                      className={`shrink-0 rounded-full border px-3 py-1.5 text-xs font-medium transition-colors ${
                        activeChatSession?.id === session.id
                          ? 'border-primary-300 bg-primary-50 text-primary-700'
                          : 'border-neutral-200 bg-white text-neutral-600 hover:border-primary-200'
                      }`}
                    >
                      {session.invoice_number || session.recipient_name || session.title}
                    </button>
                  ))}
                </div>
              )}

              <div className="space-y-2 rounded-xl border border-neutral-200 bg-neutral-50/70 p-3">
                <div className="max-h-52 space-y-2 overflow-y-auto pr-1">
                  {(activeChatSession?.messages || []).length === 0 ? (
                    <div className="rounded-lg border border-dashed border-neutral-300 bg-white p-3 text-sm text-neutral-500">
                      Ask for an invoice draft by recipient, service, and amount.
                    </div>
                  ) : (
                    activeChatSession?.messages?.map((message) => (
                      <div
                        key={message.id}
                        className={`rounded-lg px-3 py-2 text-sm ${
                          message.role === 'user'
                            ? 'bg-primary-600 text-white'
                            : 'border border-neutral-200 bg-white text-neutral-700'
                        }`}
                      >
                        {message.content}
                        {message.image_urls.length > 0 && (
                          <span className={`mt-1 block text-xs ${message.role === 'user' ? 'text-primary-100' : 'text-neutral-400'}`}>
                            {message.image_urls.length} attachment{message.image_urls.length === 1 ? '' : 's'}
                          </span>
                        )}
                      </div>
                    ))
                  )}
                </div>
                {chatImages.length > 0 && (
                  <div className="flex flex-wrap gap-2">
                    {chatImages.map((image) => (
                      <span key={`${image.name}-${image.size}`} className="inline-flex items-center gap-1 rounded-full bg-white px-2 py-1 text-xs text-neutral-600">
                        {image.name}
                        <button
                          type="button"
                          onClick={() => setChatImages((current) => current.filter((candidate) => candidate !== image))}
                          className="rounded-full p-0.5 text-neutral-400 hover:bg-neutral-100 hover:text-neutral-700"
                          aria-label={`Remove ${image.name}`}
                        >
                          <X className="h-3 w-3" />
                        </button>
                      </span>
                    ))}
                  </div>
                )}
                <div className="flex gap-2">
                  <label className="inline-flex h-10 w-10 cursor-pointer items-center justify-center rounded-xl border border-neutral-300 bg-white text-neutral-600 transition-colors hover:border-primary-300 hover:text-primary-700">
                    <ImagePlus className="h-4 w-4" />
                    <input
                      type="file"
                      className="sr-only"
                      accept="image/png,image/jpeg,image/webp,application/pdf"
                      multiple
                      onChange={(event) => {
                        const files = Array.from(event.target.files || []);
                        setChatImages((current) => [...current, ...files].slice(0, 4));
                        event.target.value = '';
                      }}
                      disabled={chatBusy}
                    />
                  </label>
                  <Input
                    value={chatInput}
                    onChange={(event) => setChatInput(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter' && !event.shiftKey) {
                        event.preventDefault();
                        sendChatMessage();
                      }
                    }}
                    placeholder="Invoice Shimizu Technology $1,000 for accounting service"
                    disabled={chatBusy}
                  />
                  <Button type="button" size="sm" className="h-10 w-10 px-0 py-0" onClick={sendChatMessage} disabled={chatBusy || !chatInput.trim()} aria-label="Send invoice assistant message">
                    <Send className="h-4 w-4" />
                  </Button>
                </div>
              </div>

              {activePreview?.status === 'preview' && (
                <div className="space-y-3 rounded-xl border border-primary-200 bg-primary-50/40 p-3">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <h3 className="flex items-center gap-2 text-sm font-semibold text-neutral-900">
                        <Sparkles className="h-4 w-4 text-primary-600" />
                        Preview v{activeChatSession?.current_preview_version}
                      </h3>
                      <p className="text-xs text-neutral-500">
                        {activePreview.invoice_recipient_name || 'Recipient needed'} · {currency(previewTotal(activePreview))}
                      </p>
                    </div>
                    <Badge className="bg-blue-100 text-blue-700">AI draft</Badge>
                  </div>
                  <div className="space-y-1 text-xs text-neutral-600">
                    {previewLineItems.map((item, index) => (
                      <div key={`${item.description}-${index}`} className="flex justify-between gap-3">
                        <span className="truncate">{item.description}</span>
                        <span className="shrink-0 font-medium">{currency(Number(item.quantity || 0) * Number(item.rate || 0))}</span>
                      </div>
                    ))}
                  </div>
                  <div className="grid gap-2 sm:grid-cols-2">
                    <Button type="button" variant="outline" size="sm" onClick={usePreviewAsDraft} disabled={chatBusy}>
                      Load Draft
                    </Button>
                    <Button type="button" size="sm" onClick={createInvoiceFromPreview} disabled={chatBusy}>
                      Create Invoice
                    </Button>
                  </div>
                </div>
              )}
            </CardContent>
          </Card>
        </div>

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
                  <h2 className="flex items-center gap-2 text-lg font-semibold text-neutral-900">
                    <ReceiptText className="h-5 w-5 text-primary-600" />
                    {invoiceForm.id ? 'Edit Invoice' : 'New Invoice'}
                  </h2>
                  <p className="text-sm text-neutral-500">
                    {activeLineItems.length} items · {currency(invoiceTotal)}
                    {invoiceForm.generated_at && ` · Generated ${new Date(invoiceForm.generated_at).toLocaleDateString()}`}
                  </p>
                </div>
                <div className="flex flex-wrap gap-2">
                  {invoiceForm.status && <Badge className={statusColors[invoiceForm.status]}>{invoiceForm.status}</Badge>}
                  {invoiceForm.id && invoiceForm.status === 'draft' && (
                    <Button
                      variant="outline"
                      size="sm"
                      className="text-red-600 hover:text-red-700"
                      onClick={() => handleDeleteInvoice(invoiceForm.id!)}
                      disabled={deletingId === invoiceForm.id}
                    >
                      <Trash2 className="mr-1.5 h-4 w-4" />
                      Delete
                    </Button>
                  )}
                </div>
              </div>

              <div className="grid gap-4 md:grid-cols-2">
                <label className="space-y-1.5">
                  <span className="text-sm font-medium text-neutral-700">Bill To</span>
                  <select
                    className="h-10 w-full rounded-xl border border-neutral-300 bg-white px-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary-300"
                    value={invoiceForm.invoice_recipient_id}
                    onChange={(event) => applyRecipientDefaults(event.target.value)}
                  >
                    <option value="">Select recipient...</option>
                    {recipients.map((recipient) => (
                      <option key={recipient.id} value={recipient.id}>
                        {recipient.name}{recipient.active ? '' : ' (archived)'}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="space-y-1.5">
                  <span className="text-sm font-medium text-neutral-700">Invoice #</span>
                  <Input value={invoiceForm.invoice_number} onChange={(event) => setInvoiceForm((current) => ({ ...current, invoice_number: event.target.value }))} placeholder="Auto-generated if blank" />
                </label>
                <label className="space-y-1.5">
                  <span className="text-sm font-medium text-neutral-700">Invoice Date</span>
                  <Input type="date" value={invoiceForm.invoice_date} onChange={(event) => setInvoiceForm((current) => ({ ...current, invoice_date: event.target.value }))} />
                </label>
                <div className="grid grid-cols-2 gap-3">
                  <label className="space-y-1.5">
                    <span className="text-sm font-medium text-neutral-700">Period Start</span>
                    <Input type="date" value={invoiceForm.service_period_start} onChange={(event) => setInvoiceForm((current) => ({ ...current, service_period_start: event.target.value }))} />
                  </label>
                  <label className="space-y-1.5">
                    <span className="text-sm font-medium text-neutral-700">Period End</span>
                    <Input type="date" value={invoiceForm.service_period_end} onChange={(event) => setInvoiceForm((current) => ({ ...current, service_period_end: event.target.value }))} />
                  </label>
                </div>
              </div>

              <div className="space-y-3">
                <div className="flex items-center justify-between">
                  <h3 className="text-sm font-semibold uppercase tracking-[0.08em] text-neutral-500">Line Items</h3>
                  <div className="flex items-center gap-3">
                    <span className="text-sm font-medium text-neutral-700">{currency(invoiceTotal)}</span>
                    <Button type="button" size="sm" variant="outline" onClick={addLineItem}>
                      <Plus className="mr-1.5 h-4 w-4" />
                      Line
                    </Button>
                  </div>
                </div>

                {activeLineItems.length === 0 ? (
                  <div className="rounded-xl border border-dashed border-neutral-300 p-6 text-center text-sm text-neutral-500">
                    Add line items to build the invoice.
                  </div>
                ) : (
                  <div className="space-y-3">
                    {activeLineItems.map((item, index) => (
                      <div key={item.local_id} className="rounded-xl border border-neutral-200 bg-white p-4">
                        <div className="mb-3 flex items-center justify-between gap-3">
                          <span className="text-xs font-semibold uppercase tracking-[0.08em] text-neutral-400">Line {index + 1}</span>
                          <button
                            type="button"
                            onClick={() => removeLineItem(item.local_id)}
                            className="rounded-lg p-1 text-neutral-400 hover:bg-red-50 hover:text-red-600"
                            aria-label="Remove line item"
                          >
                            <X className="h-4 w-4" />
                          </button>
                        </div>
                        <div className="grid gap-3 md:grid-cols-[minmax(0,1fr)_120px_120px_120px]">
                          <label className="space-y-1.5">
                            <span className="text-sm font-medium text-neutral-700">Description</span>
                            <Input value={item.description} onChange={(event) => updateLineItem(item.local_id, { description: event.target.value })} placeholder="Service description" />
                          </label>
                          <label className="space-y-1.5">
                            <span className="text-sm font-medium text-neutral-700">Qty</span>
                            <Input type="number" step="0.01" min="0" value={item.quantity} onChange={(event) => updateLineItem(item.local_id, { quantity: Number(event.target.value || 0) })} />
                          </label>
                          <label className="space-y-1.5">
                            <span className="text-sm font-medium text-neutral-700">Rate</span>
                            <Input type="number" step="0.01" min="0" value={item.rate} onChange={(event) => updateLineItem(item.local_id, { rate: Number(event.target.value || 0) })} />
                          </label>
                          <label className="space-y-1.5">
                            <span className="text-sm font-medium text-neutral-700">Date</span>
                            <Input type="date" value={item.service_date || ''} onChange={(event) => updateLineItem(item.local_id, { service_date: event.target.value })} />
                          </label>
                        </div>
                        <p className="mt-2 text-right text-sm font-medium text-neutral-700">
                          {currency(Number(item.quantity || 0) * Number(item.rate || 0))}
                        </p>
                      </div>
                    ))}
                  </div>
                )}
              </div>

              <div className="grid gap-4 md:grid-cols-2">
                <label className="space-y-1.5">
                  <span className="text-sm font-medium text-neutral-700">Payment Terms</span>
                  <Textarea value={invoiceForm.payment_terms} onChange={(event) => setInvoiceForm((current) => ({ ...current, payment_terms: event.target.value }))} rows={3} />
                </label>
                <label className="space-y-1.5">
                  <span className="text-sm font-medium text-neutral-700">Notes</span>
                  <Textarea value={invoiceForm.notes} onChange={(event) => setInvoiceForm((current) => ({ ...current, notes: event.target.value }))} rows={3} />
                </label>
              </div>

              <div className="rounded-xl border border-neutral-200 bg-neutral-50/70 p-4">
                <div className="mb-3 flex items-center justify-between gap-3">
                  <div>
                    <h3 className="flex items-center gap-2 text-sm font-semibold text-neutral-900">
                      <Mail className="h-4 w-4 text-primary-600" />
                      Email Draft
                    </h3>
                    <p className="text-xs text-neutral-500">Draft text to copy into Gmail after attaching the PDF.</p>
                  </div>
                  <Button type="button" variant="outline" size="sm" onClick={copyEmail} disabled={!invoiceForm.email_subject && !invoiceForm.email_body}>
                    <Copy className="mr-1.5 h-4 w-4" />
                    Copy
                  </Button>
                </div>
                <div className="space-y-3">
                  <Input value={invoiceForm.email_subject} onChange={(event) => setInvoiceForm((current) => ({ ...current, email_subject: event.target.value }))} placeholder="Subject line to paste into Gmail" />
                  <Textarea value={invoiceForm.email_body} onChange={(event) => setInvoiceForm((current) => ({ ...current, email_body: event.target.value }))} placeholder="Message body to paste into Gmail" rows={4} />
                </div>
              </div>

              {invoiceForm.id && invoiceForm.status && invoiceForm.status !== 'draft' && (
                <div className="flex flex-wrap items-center gap-2 rounded-xl border border-neutral-200 bg-white p-3">
                  <span className="mr-2 text-sm font-medium text-neutral-700">Status:</span>
                  {(statusActions[invoiceForm.status] || []).map((status) => (
                    <Button key={status} type="button" size="sm" variant="outline" onClick={() => handleStatusChange(status)} disabled={statusBusy || invoiceForm.status === status}>
                      Mark {status}
                    </Button>
                  ))}
                </div>
              )}

              <div className="flex flex-col-reverse gap-3 border-t border-neutral-200 pt-5 sm:flex-row sm:justify-end">
                <Button type="button" variant="outline" onClick={handleSaveDraft} disabled={saving || pdfBusy}>
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
                <h3 className="font-semibold text-neutral-900">Invoice Preview</h3>
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
            <iframe title="Invoice preview" src={previewUrl} className="h-full w-full" />
          </div>
        </div>
      )}
    </div>
  );
}
