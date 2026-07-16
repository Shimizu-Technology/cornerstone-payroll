import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Archive,
  Bot,
  Building2,
  CalendarClock,
  CheckCircle2,
  CircleDollarSign,
  Download,
  Eye,
  FilePlus2,
  FileText,
  History,
  Import,
  Loader2,
  MailCheck,
  Plus,
  ReceiptText,
  RotateCcw,
  Search,
  Undo2,
  Upload,
  WalletCards,
  X,
} from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { useAuth } from '@/contexts/AuthContext';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import {
  invoiceBillingProfilesApi,
  invoiceReceivablesApi,
  invoiceRecipientsApi,
  invoicesApi,
  type BlobDownload,
  type Invoice,
  type InvoiceBillingProfile,
  type InvoiceLineItem,
  type InvoiceReceivablesSummary,
  type InvoiceRecipient,
  type InvoiceStatus,
} from '@/services/api';

type Modal = 'new' | 'import' | 'details' | null;
type DetailAction = 'payment' | 'delivery' | 'credit' | null;
type Payment = NonNullable<Invoice['payments']>[number];
type CreditNote = NonNullable<Invoice['credit_notes']>[number];
type FinancialActivity =
  | { kind: 'payment'; activityAt: string; payment: Payment }
  | { kind: 'credit'; activityAt: string; credit: CreditNote };

interface DraftLine extends InvoiceLineItem {
  localId: string;
}

interface DraftForm {
  invoice_billing_profile_id: string;
  invoice_recipient_id: string;
  invoice_number: string;
  invoice_date: string;
  due_date: string;
  customer_reference: string;
  payment_terms: string;
  notes: string;
  line_items: DraftLine[];
}

interface ImportForm {
  file: File | null;
  invoice_billing_profile_id: string;
  invoice_recipient_id: string;
  invoice_number: string;
  invoice_date: string;
  due_date: string;
  total_amount: string;
  customer_reference: string;
  notes: string;
  delivered_at: string;
  delivery_channel: string;
}

const dateOnly = () => new Date().toISOString().slice(0, 10);
const newLine = (): DraftLine => ({ localId: crypto.randomUUID(), description: '', quantity: 1, rate: 0, position: 0 });
const emptyDraft = (): DraftForm => ({
  invoice_billing_profile_id: '',
  invoice_recipient_id: '',
  invoice_number: '',
  invoice_date: dateOnly(),
  due_date: '',
  customer_reference: '',
  payment_terms: '',
  notes: '',
  line_items: [newLine()],
});
const emptyImport = (): ImportForm => ({
  file: null,
  invoice_billing_profile_id: '',
  invoice_recipient_id: '',
  invoice_number: '',
  invoice_date: dateOnly(),
  due_date: '',
  total_amount: '',
  customer_reference: '',
  notes: '',
  delivered_at: '',
  delivery_channel: 'email',
});

const statusStyles: Record<InvoiceStatus, string> = {
  draft: 'bg-neutral-100 text-neutral-700',
  open: 'bg-blue-100 text-blue-700',
  partially_paid: 'bg-violet-100 text-violet-700',
  paid: 'bg-green-100 text-green-700',
  overdue: 'bg-amber-100 text-amber-800',
  voided: 'bg-red-100 text-red-700',
  uncollectible: 'bg-rose-100 text-rose-800',
  generated: 'bg-blue-100 text-blue-700',
  sent: 'bg-amber-100 text-amber-800',
  archived: 'bg-neutral-200 text-neutral-700',
};

const statusLabel = (status: InvoiceStatus) => ({
  draft: 'Draft',
  open: 'Open',
  partially_paid: 'Partially paid',
  paid: 'Paid',
  overdue: 'Overdue',
  voided: 'Voided',
  uncollectible: 'Uncollectible',
  generated: 'PDF ready',
  sent: 'Sent',
  archived: 'Archived',
}[status]);

const money = (value?: number | null, currency = 'USD') => new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency,
}).format(Number(value || 0));

const formatDate = (value?: string | null) => {
  if (!value) return '—';
  const [year, month, day] = value.slice(0, 10).split('-').map(Number);
  return new Date(year, month - 1, day).toLocaleDateString();
};

const formatDateTime = (value?: string | null) => value ? new Date(value).toLocaleString() : '—';

function downloadBlob(data: BlobDownload, fallback: string) {
  const url = URL.createObjectURL(data.blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = data.filename || fallback;
  anchor.click();
  URL.revokeObjectURL(url);
}

function ModalShell({ title, subtitle, onClose, children, wide = false }: {
  title: string;
  subtitle?: string;
  onClose: () => void;
  children: React.ReactNode;
  wide?: boolean;
}) {
  return (
    <div className="invoice-modal-backdrop fixed inset-0 z-50 flex items-center justify-center bg-neutral-950/45 p-3 sm:p-6">
      <div className={`invoice-modal-panel flex max-h-[94vh] w-full flex-col overflow-hidden rounded-2xl bg-white shadow-2xl ${wide ? 'max-w-6xl' : 'max-w-3xl'}`}>
        <div className="flex items-start justify-between gap-4 border-b border-neutral-200 px-5 py-4 sm:px-6">
          <div>
            <h2 className="text-xl font-semibold text-neutral-950">{title}</h2>
            {subtitle && <p className="mt-1 text-sm text-neutral-500">{subtitle}</p>}
          </div>
          <button type="button" onClick={onClose} className="rounded-lg p-2 text-neutral-400 hover:bg-neutral-100 hover:text-neutral-700" aria-label="Close">
            <X className="h-5 w-5" />
          </button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto p-5 sm:p-6">{children}</div>
      </div>
    </div>
  );
}

export function InvoiceCenter() {
  const { user } = useAuth();
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [recipients, setRecipients] = useState<InvoiceRecipient[]>([]);
  const [profiles, setProfiles] = useState<InvoiceBillingProfile[]>([]);
  const [summary, setSummary] = useState<InvoiceReceivablesSummary | null>(null);
  const [selected, setSelected] = useState<Invoice | null>(null);
  const [modal, setModal] = useState<Modal>(null);
  const [detailAction, setDetailAction] = useState<DetailAction>(null);
  const [draft, setDraft] = useState<DraftForm>(emptyDraft);
  const [editingDraftId, setEditingDraftId] = useState<number | null>(null);
  const [importForm, setImportForm] = useState<ImportForm>(emptyImport);
  const [statusFilter, setStatusFilter] = useState<'active' | InvoiceStatus | 'archived' | 'all'>('active');
  const [businessFilter, setBusinessFilter] = useState<'all' | string>('all');
  const [search, setSearch] = useState('');
  const [loading, setLoading] = useState(true);
  const [scopeLoading, setScopeLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const loadSequence = useRef(0);

  const load = useCallback(async ({ silent = false }: { silent?: boolean } = {}) => {
    const sequence = ++loadSequence.current;
    const billingProfileId = businessFilter === 'all' ? undefined : Number(businessFilter);
    if (!silent) setLoading(true);
    setError(null);
    try {
      const [invoiceResult, recipientResult, profileResult, summaryResult] = await Promise.all([
        invoicesApi.list({ billing_profile_id: billingProfileId }),
        invoiceRecipientsApi.list({ active: true }),
        invoiceBillingProfilesApi.list(),
        invoiceReceivablesApi.summary({ billing_profile_id: billingProfileId }),
      ]);
      if (sequence !== loadSequence.current) return;
      setInvoices(invoiceResult.invoices);
      setRecipients(recipientResult.invoice_recipients);
      setProfiles(profileResult.invoice_billing_profiles);
      setSummary(summaryResult);
      const activeProfiles = profileResult.invoice_billing_profiles.filter((profile) => profile.active);
      const defaultProfile = activeProfiles.find((profile) => profile.is_default) || activeProfiles[0];
      setDraft((current) => ({ ...current, invoice_billing_profile_id: current.invoice_billing_profile_id || String(defaultProfile?.id || '') }));
      setImportForm((current) => ({ ...current, invoice_billing_profile_id: current.invoice_billing_profile_id || String(defaultProfile?.id || '') }));
    } catch (loadError) {
      if (sequence === loadSequence.current) {
        setError(loadError instanceof Error ? loadError.message : 'Unable to load the Invoice Center');
      }
    } finally {
      if (sequence === loadSequence.current) setLoading(false);
    }
  }, [businessFilter]);

  useEffect(() => {
    let active = true;
    setScopeLoading(true);
    void load({ silent: true }).finally(() => {
      if (active) setScopeLoading(false);
    });
    return () => { active = false; };
  }, [load]);
  useEffect(() => () => { if (previewUrl) URL.revokeObjectURL(previewUrl); }, [previewUrl]);

  const filteredInvoices = useMemo(() => invoices.filter((invoice) => {
    const matchesStatus = statusFilter === 'all'
      || (statusFilter === 'active' && !invoice.archived && !['voided', 'uncollectible'].includes(invoice.status))
      || (statusFilter === 'archived' && invoice.archived)
      || invoice.status === statusFilter;
    const needle = search.trim().toLowerCase();
    const matchesSearch = !needle || [invoice.invoice_number, invoice.recipient_name, invoice.billing_profile_name, invoice.customer_reference]
      .some((value) => value?.toLowerCase().includes(needle));
    return matchesStatus && matchesSearch;
  }), [invoices, search, statusFilter]);

  const activeProfiles = useMemo(() => profiles.filter((profile) => profile.active), [profiles]);
  const selectedBusiness = businessFilter === 'all'
    ? null
    : profiles.find((profile) => String(profile.id) === businessFilter) || null;

  const financialActivity = useMemo<FinancialActivity[]>(() => {
    if (!selected) return [];
    const payments: FinancialActivity[] = (selected.payments || []).map((payment) => ({
      kind: 'payment',
      payment,
      activityAt: payment.reversed_at || payment.created_at,
    }));
    const credits: FinancialActivity[] = (selected.credit_notes || []).map((credit) => ({
      kind: 'credit',
      credit,
      activityAt: credit.voided_at || credit.created_at,
    }));
    return [...payments, ...credits].sort((left, right) =>
      new Date(right.activityAt).getTime() - new Date(left.activityAt).getTime()
    );
  }, [selected]);

  const deliveryHistory = useMemo(() => [...(selected?.deliveries || [])].sort((left, right) =>
    new Date(right.created_at).getTime() - new Date(left.created_at).getTime()
  ), [selected]);

  const auditTimeline = useMemo(() => [...(selected?.events || [])].sort((left, right) =>
    new Date(right.created_at).getTime() - new Date(left.created_at).getTime()
  ), [selected]);

  const applyInvoice = (invoice: Invoice) => {
    setSelected(invoice);
    setInvoices((current) => current.map((row) => row.id === invoice.id ? invoice : row));
  };

  const refreshSelected = async (id: number) => {
    const response = await invoicesApi.get(id);
    applyInvoice(response.invoice);
    return response.invoice;
  };

  const openDetails = async (id: number) => {
    setBusy(true);
    setError(null);
    try {
      const invoice = await refreshSelected(id);
      setSelected(invoice);
      setModal('details');
      setDetailAction(null);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : 'Unable to open invoice');
    } finally {
      setBusy(false);
    }
  };

  const run = async (action: () => Promise<void>, message: string) => {
    setBusy(true);
    setError(null);
    setSuccess(null);
    try {
      await action();
      await load({ silent: true });
      setSuccess(message);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : 'Invoice action failed');
    } finally {
      setBusy(false);
    }
  };

  const openNewDraft = () => {
    const defaultProfile = selectedBusiness?.active
      ? selectedBusiness
      : activeProfiles.find((profile) => profile.is_default) || activeProfiles[0];
    setEditingDraftId(null);
    setDraft({ ...emptyDraft(), invoice_billing_profile_id: String(defaultProfile?.id || '') });
    setModal('new');
  };

  const editSelectedDraft = () => {
    if (!selected || selected.status !== 'draft') return;
    setEditingDraftId(selected.id);
    setDraft({
      invoice_billing_profile_id: String(selected.invoice_billing_profile_id),
      invoice_recipient_id: String(selected.invoice_recipient_id),
      invoice_number: selected.invoice_number,
      invoice_date: selected.invoice_date,
      due_date: selected.due_date || '',
      customer_reference: selected.customer_reference || '',
      payment_terms: selected.payment_terms || '',
      notes: selected.notes || '',
      line_items: (selected.line_items || []).map((line, position) => ({
        ...line,
        localId: `saved-${line.id || position}`,
        position,
      })),
    });
    setModal('new');
  };

  const closeDraftModal = () => {
    setModal(null);
    setEditingDraftId(null);
  };

  const submitDraft = () => run(async () => {
    if (!draft.invoice_recipient_id) throw new Error('Choose a customer');
    const lines = draft.line_items.filter((line) => line.description.trim() && Number(line.quantity) > 0);
    if (!lines.length) throw new Error('Add at least one invoice line');
    const payload = {
      invoice_recipient_id: Number(draft.invoice_recipient_id),
      invoice_billing_profile_id: Number(draft.invoice_billing_profile_id),
      invoice_number: draft.invoice_number.trim() || null,
      invoice_date: draft.invoice_date,
      due_date: draft.due_date || null,
      currency: 'USD',
      customer_reference: draft.customer_reference || null,
      payment_terms: draft.payment_terms || null,
      notes: draft.notes || null,
      line_items: lines.map((line, position) => ({ ...line, position })),
    };
    const result = editingDraftId
      ? await invoicesApi.update(editingDraftId, payload)
      : await invoicesApi.create(payload);
    setDraft(emptyDraft());
    setEditingDraftId(null);
    applyInvoice(result.invoice);
    setModal('details');
    setDetailAction(null);
  }, editingDraftId ? 'Draft invoice updated.' : 'Draft invoice created. Review it, then issue it when ready.');

  const submitImport = () => run(async () => {
    if (!importForm.file) throw new Error('Choose the original invoice PDF or image');
    if (!importForm.invoice_number.trim()) throw new Error('Enter the invoice number shown on the original');
    const result = await invoicesApi.import({
      file: importForm.file,
      invoice_recipient_id: Number(importForm.invoice_recipient_id),
      invoice_billing_profile_id: Number(importForm.invoice_billing_profile_id),
      invoice_number: importForm.invoice_number,
      invoice_date: importForm.invoice_date,
      due_date: importForm.due_date || undefined,
      total_amount: Number(importForm.total_amount),
      customer_reference: importForm.customer_reference || undefined,
      notes: importForm.notes || undefined,
      delivered_at: importForm.delivered_at || undefined,
      delivery_channel: importForm.delivery_channel,
    });
    setImportForm(emptyImport());
    applyInvoice(result.invoice);
    setModal('details');
    setDetailAction(null);
  }, 'External invoice imported with its original file preserved.');

  const issueSelected = () => selected && run(async () => {
    const response = await invoicesApi.issue(selected.id);
    applyInvoice(response.invoice);
  }, 'Invoice issued and its exact PDF preserved.');

  const previewSelected = async () => {
    if (!selected) return;
    setBusy(true);
    try {
      const data = selected.status === 'draft'
        ? await invoicesApi.previewPdf(selected.id)
        : await invoicesApi.downloadArtifact(selected.id, 'inline');
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      setPreviewUrl(URL.createObjectURL(data.blob));
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : 'Unable to preview invoice');
    } finally {
      setBusy(false);
    }
  };

  const downloadSelected = async () => {
    if (!selected) return;
    setBusy(true);
    try {
      const data = selected.status === 'draft'
        ? await invoicesApi.generatePdf(selected.id)
        : await invoicesApi.downloadArtifact(selected.id);
      downloadBlob(data, `${selected.invoice_number}.pdf`);
      await refreshSelected(selected.id);
      await load({ silent: true });
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : 'Unable to download invoice');
    } finally {
      setBusy(false);
    }
  };

  const submitPayment = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!selected) return;
    const form = new FormData(event.currentTarget);
    await run(async () => {
      const response = await invoicesApi.recordPayment(selected.id, {
        amount: Number(form.get('amount')),
        received_on: String(form.get('received_on')),
        payment_method: String(form.get('payment_method')),
        reference_number: String(form.get('reference_number') || '') || undefined,
        notes: String(form.get('notes') || '') || undefined,
      });
      applyInvoice(response.invoice);
      setDetailAction(null);
    }, 'Payment recorded and the receivable balance updated.');
  };

  const submitDelivery = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!selected) return;
    const form = new FormData(event.currentTarget);
    await run(async () => {
      const response = await invoicesApi.recordDelivery(selected.id, {
        channel: String(form.get('channel')),
        recipient: String(form.get('recipient') || '') || undefined,
        delivered_at: String(form.get('delivered_at') || '') || undefined,
        provider_reference: String(form.get('provider_reference') || '') || undefined,
        notes: String(form.get('notes') || '') || undefined,
      });
      applyInvoice(response.invoice);
      setDetailAction(null);
    }, 'Delivery evidence recorded.');
  };

  const submitCredit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!selected) return;
    const form = new FormData(event.currentTarget);
    await run(async () => {
      const response = await invoicesApi.issueCredit(selected.id, {
        amount: Number(form.get('amount')),
        issue_date: String(form.get('issue_date')),
        reason: String(form.get('reason')),
      });
      applyInvoice(response.invoice);
      setDetailAction(null);
    }, 'Credit note issued and applied to the balance.');
  };

  const reversePayment = async (paymentId: number) => {
    if (!selected) return;
    const reason = window.prompt('Why is this payment being reversed?');
    if (!reason?.trim()) return;
    await run(async () => {
      const response = await invoicesApi.reversePayment(selected.id, paymentId, reason.trim());
      applyInvoice(response.invoice);
    }, 'Payment reversed; the original record remains in history.');
  };

  const voidCredit = async (creditId: number) => {
    if (!selected) return;
    const reason = window.prompt('Why is this credit note being voided?');
    if (!reason?.trim()) return;
    await run(async () => {
      const response = await invoicesApi.voidCredit(selected.id, creditId, reason.trim());
      applyInvoice(response.invoice);
    }, 'Credit note voided; its history remains intact.');
  };

  const changeLifecycle = async (status: 'voided' | 'uncollectible' | 'archived' | 'restored') => {
    if (!selected) return;
    if (status === 'voided' && !window.confirm('Void this invoice? This keeps the invoice and history but removes it from receivables.')) return;
    await run(async () => {
      const response = await invoicesApi.updateStatus(selected.id, status);
      applyInvoice(response.invoice);
    }, status === 'archived' ? 'Invoice archived.' : status === 'restored' ? 'Invoice restored.' : `Invoice marked ${status}.`);
  };

  const invoiceTotal = draft.line_items.reduce((sum, line) => sum + Number(line.quantity || 0) * Number(line.rate || 0), 0);

  return (
    <div className="space-y-6">
      <Header
        title="Invoice Center"
        description="Create invoices, preserve outside invoices, and track organization receivables from issue through payment."
        contextLabel="Organization"
        contextValue={user?.organization_name || 'Organization-wide finance'}
        actions={(
          <div className="flex flex-wrap gap-2">
            <Link to="/tools/invoices/assistant" className="inline-flex min-h-11 items-center justify-center rounded-full border border-neutral-300 bg-white/80 px-4 py-2.5 text-sm font-semibold text-neutral-700 transition hover:border-primary-300 hover:bg-primary-50 hover:text-primary-800"><Bot className="mr-1.5 h-4 w-4" />AI invoice maker</Link>
            <Button variant="outline" onClick={() => setModal('import')}><Import className="mr-1.5 h-4 w-4" />Import invoice</Button>
            <Button onClick={openNewDraft}><Plus className="mr-1.5 h-4 w-4" />New invoice</Button>
          </div>
        )}
      />

      <div className="flex flex-col gap-4 rounded-2xl border border-primary-100 bg-gradient-to-r from-primary-50/80 to-white p-4 sm:flex-row sm:items-center sm:justify-between sm:px-5">
        <div className="flex items-start gap-3">
          <div className="rounded-xl bg-white p-2.5 text-primary-700 shadow-sm"><Building2 className="h-5 w-5" /></div>
          <div>
            <p className="font-semibold text-neutral-950">Organization-wide accounts receivable</p>
            <p className="mt-1 max-w-2xl text-sm leading-5 text-neutral-600">
              Invoices belong to an invoice-from business, not the payroll client selected in the sidebar. Choose a business to focus its totals and activity.
            </p>
          </div>
        </div>
        <label className="min-w-64 text-sm font-medium text-neutral-700">
          Invoice business
          <div className="relative mt-1">
            <select
              value={businessFilter}
              onChange={(event) => setBusinessFilter(event.target.value)}
              disabled={scopeLoading}
              className="h-11 w-full rounded-lg border border-neutral-300 bg-white px-3 pr-9 text-sm font-semibold text-neutral-900 disabled:opacity-70"
            >
              <option value="all">All invoice businesses</option>
              {profiles.map((profile) => (
                <option key={profile.id} value={profile.id}>{profile.name}{profile.active ? '' : ' (archived)'}</option>
              ))}
            </select>
            {scopeLoading && <Loader2 className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 animate-spin text-primary-600" />}
          </div>
        </label>
      </div>

      {(error || success) && (
        <div role="status" className={`invoice-toast fixed right-4 top-4 z-[80] w-[min(28rem,calc(100vw-2rem))] rounded-xl border px-4 py-3 text-sm shadow-xl ${error ? 'border-red-200 bg-red-50 text-red-700' : 'border-green-200 bg-green-50 text-green-700'}`}>
          <div className="flex items-start justify-between gap-3">
            <span>{error || success}</span>
            <button onClick={() => { setError(null); setSuccess(null); }}><X className="h-4 w-4" /></button>
          </div>
        </div>
      )}

      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        {[
          { label: 'Outstanding', value: money(summary?.totals.outstanding), detail: `${summary?.totals.open_count || 0} open invoices`, icon: WalletCards, tone: 'text-blue-700 bg-blue-50' },
          { label: 'Overdue', value: money(summary?.totals.overdue), detail: `${summary?.totals.overdue_count || 0} need attention`, icon: CalendarClock, tone: 'text-amber-700 bg-amber-50' },
          { label: 'Payments recorded', value: money(summary?.totals.paid), detail: 'All non-reversed payments', icon: CircleDollarSign, tone: 'text-green-700 bg-green-50' },
          { label: 'Drafts', value: String(summary?.totals.draft_count || 0), detail: 'Not yet official', icon: FilePlus2, tone: 'text-violet-700 bg-violet-50' },
        ].map(({ label, value, detail, icon: Icon, tone }) => (
          <Card key={label}><CardContent className="flex items-start justify-between gap-4 p-5">
            <div><p className="text-sm font-medium text-neutral-500">{label}</p><p className="mt-2 text-2xl font-semibold text-neutral-950">{value}</p><p className="mt-1 text-xs text-neutral-500">{detail}</p></div>
            <div className={`rounded-xl p-2.5 ${tone}`}><Icon className="h-5 w-5" /></div>
          </CardContent></Card>
        ))}
      </div>

      <div className="grid gap-6 xl:grid-cols-[minmax(0,1fr)_360px]">
        <Card>
          <CardContent className="p-0">
            <div className="flex flex-col gap-3 border-b border-neutral-200 p-4 sm:flex-row sm:items-center sm:justify-between">
              <div><h2 className="font-semibold text-neutral-950">Invoices</h2><p className="text-sm text-neutral-500">{selectedBusiness ? `Issued by ${selectedBusiness.name}` : 'All invoice businesses in this organization'}</p></div>
              <div className="flex flex-col gap-2 sm:flex-row">
                <div className="relative"><Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-400" /><Input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search number or customer" className="pl-9 sm:w-64" /></div>
                <select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value as typeof statusFilter)} className="h-10 rounded-md border border-neutral-300 bg-white px-3 text-sm">
                  <option value="active">Active</option><option value="draft">Draft</option><option value="open">Open</option><option value="overdue">Overdue</option><option value="partially_paid">Partially paid</option><option value="paid">Paid</option><option value="voided">Voided</option><option value="uncollectible">Uncollectible</option><option value="archived">Archived</option><option value="all">All</option>
                </select>
              </div>
            </div>
            {loading ? (
              <div className="flex min-h-64 items-center justify-center text-neutral-500"><Loader2 className="mr-2 h-5 w-5 animate-spin" />Loading invoices</div>
            ) : filteredInvoices.length === 0 ? (
              <div className="flex min-h-64 flex-col items-center justify-center p-8 text-center"><ReceiptText className="h-10 w-10 text-neutral-300" /><h3 className="mt-3 font-semibold text-neutral-900">No invoices in this view</h3><p className="mt-1 max-w-sm text-sm text-neutral-500">Create a new invoice here or import one that was made outside Cornerstone.</p></div>
            ) : (
              <div className="divide-y divide-neutral-100">
                {filteredInvoices.map((invoice) => (
                  <button key={invoice.id} type="button" onClick={() => openDetails(invoice.id)} className="grid w-full gap-3 px-4 py-4 text-left transition-colors hover:bg-neutral-50 sm:grid-cols-[minmax(0,1fr)_130px_130px_28px] sm:items-center">
                    <div className="min-w-0"><div className="flex flex-wrap items-center gap-2"><span className="font-semibold text-neutral-950">{invoice.invoice_number}</span><Badge className={statusStyles[invoice.status]}>{statusLabel(invoice.status)}</Badge>{invoice.origin === 'imported' && <Badge className="bg-sky-50 text-sky-700">Imported</Badge>}{invoice.archived && <Badge className="bg-neutral-200 text-neutral-700">Archived</Badge>}</div><p className="mt-1 truncate text-sm text-neutral-600">{invoice.recipient_name}</p><p className="mt-0.5 text-xs text-neutral-400">From {invoice.billing_profile_name || 'Invoice business'} · Invoice {formatDate(invoice.invoice_date)} · Due {formatDate(invoice.due_date)}</p></div>
                    <div><p className="text-xs uppercase tracking-wide text-neutral-400">Balance</p><p className={`font-semibold ${invoice.status === 'overdue' ? 'text-amber-700' : 'text-neutral-900'}`}>{money(invoice.balance_due, invoice.currency)}</p></div>
                    <div><p className="text-xs uppercase tracking-wide text-neutral-400">Invoice total</p><p className="font-medium text-neutral-700">{money(invoice.total_amount, invoice.currency)}</p></div>
                    <Eye className="h-4 w-4 text-neutral-400" />
                  </button>
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        <div className="space-y-6">
          <Card><CardContent className="p-5"><h2 className="font-semibold text-neutral-950">Receivables aging</h2><p className="mt-1 text-sm text-neutral-500">What remains unpaid as of today</p><div className="mt-5 space-y-3">
            {[
              ['Current', summary?.aging.current], ['1–30 days', summary?.aging.days_1_30], ['31–60 days', summary?.aging.days_31_60], ['61–90 days', summary?.aging.days_61_90], ['91+ days', summary?.aging.days_91_plus],
            ].map(([label, value]) => <div key={String(label)} className="flex items-center justify-between border-b border-neutral-100 pb-2 text-sm last:border-0"><span className="text-neutral-600">{label}</span><span className="font-semibold text-neutral-900">{money(Number(value || 0))}</span></div>)}
          </div></CardContent></Card>
          <Card><CardContent className="p-5"><h2 className="font-semibold text-neutral-950">Customer balances</h2><p className="mt-1 text-sm text-neutral-500">Open receivables by customer</p><div className="mt-4 space-y-2">
            {(summary?.by_recipient || []).slice(0, 8).map((row) => <div key={row.recipient_id} className="rounded-xl border border-neutral-200 p-3"><div className="flex items-center justify-between gap-3"><div className="min-w-0"><p className="truncate text-sm font-medium text-neutral-900">{row.recipient_name}</p><p className="text-xs text-neutral-500">{row.invoice_count} invoice{row.invoice_count === 1 ? '' : 's'} · oldest due {formatDate(row.oldest_due_date)}</p></div><span className="shrink-0 text-sm font-semibold">{money(row.outstanding)}</span></div></div>)}
            {!summary?.by_recipient.length && <p className="py-4 text-sm text-neutral-500">No outstanding customer balances.</p>}
          </div></CardContent></Card>
        </div>
      </div>

      {modal === 'new' && <ModalShell title={editingDraftId ? "Edit draft invoice" : "New invoice"} subtitle="Save a draft first. Issuing it freezes the financial details and preserves the exact PDF." onClose={closeDraftModal} wide>
        <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_280px]">
          <div className="space-y-5">
            <div className="grid gap-4 sm:grid-cols-2">
              <label className="text-sm font-medium">From<select value={draft.invoice_billing_profile_id} onChange={(e) => setDraft({ ...draft, invoice_billing_profile_id: e.target.value })} className="mt-1 h-10 w-full rounded-md border border-neutral-300 bg-white px-3"><option value="">Choose billing profile</option>{activeProfiles.map((profile) => <option key={profile.id} value={profile.id}>{profile.name}</option>)}</select></label>
              <label className="text-sm font-medium">Bill to<select value={draft.invoice_recipient_id} onChange={(e) => setDraft({ ...draft, invoice_recipient_id: e.target.value })} className="mt-1 h-10 w-full rounded-md border border-neutral-300 bg-white px-3"><option value="">Choose customer</option>{recipients.map((recipient) => <option key={recipient.id} value={recipient.id}>{recipient.name}</option>)}</select></label>
              <label className="text-sm font-medium">Invoice number <span className="font-normal text-neutral-400">(automatic if blank)</span><Input className="mt-1" value={draft.invoice_number} onChange={(e) => setDraft({ ...draft, invoice_number: e.target.value })} placeholder="ST-2026-0001" /></label>
              <label className="text-sm font-medium">Customer reference<Input className="mt-1" value={draft.customer_reference} onChange={(e) => setDraft({ ...draft, customer_reference: e.target.value })} placeholder="PO number or project" /></label>
              <label className="text-sm font-medium">Invoice date<Input className="mt-1" type="date" value={draft.invoice_date} onChange={(e) => setDraft({ ...draft, invoice_date: e.target.value })} /></label>
              <label className="text-sm font-medium">Due date<Input className="mt-1" type="date" value={draft.due_date} onChange={(e) => setDraft({ ...draft, due_date: e.target.value })} /></label>
            </div>
            <div><div className="mb-2 flex items-center justify-between"><h3 className="text-sm font-semibold">Line items</h3><Button type="button" size="sm" variant="outline" onClick={() => setDraft({ ...draft, line_items: [...draft.line_items, { ...newLine(), position: draft.line_items.length }] })}><Plus className="mr-1 h-3.5 w-3.5" />Add line</Button></div><div className="space-y-2">
              {draft.line_items.map((line, index) => <div key={line.localId} className="grid gap-2 rounded-xl border border-neutral-200 p-3 sm:grid-cols-[minmax(0,1fr)_90px_120px_36px]">
                <Input value={line.description} onChange={(e) => setDraft({ ...draft, line_items: draft.line_items.map((item) => item.localId === line.localId ? { ...item, description: e.target.value } : item) })} placeholder="Description" />
                <Input type="number" min="0" step="0.01" value={line.quantity} onChange={(e) => setDraft({ ...draft, line_items: draft.line_items.map((item) => item.localId === line.localId ? { ...item, quantity: Number(e.target.value) } : item) })} aria-label="Quantity" />
                <Input type="number" min="0" step="0.01" value={line.rate} onChange={(e) => setDraft({ ...draft, line_items: draft.line_items.map((item) => item.localId === line.localId ? { ...item, rate: Number(e.target.value) } : item) })} aria-label="Rate" />
                <button type="button" onClick={() => setDraft({ ...draft, line_items: draft.line_items.filter((item) => item.localId !== line.localId) })} className="rounded-md text-neutral-400 hover:bg-red-50 hover:text-red-600" aria-label={`Remove line ${index + 1}`}><X className="mx-auto h-4 w-4" /></button>
              </div>)}
            </div></div>
            <div className="grid gap-4 sm:grid-cols-2"><label className="text-sm font-medium">Payment terms<Textarea className="mt-1" value={draft.payment_terms} onChange={(e) => setDraft({ ...draft, payment_terms: e.target.value })} rows={3} /></label><label className="text-sm font-medium">Notes<Textarea className="mt-1" value={draft.notes} onChange={(e) => setDraft({ ...draft, notes: e.target.value })} rows={3} /></label></div>
          </div>
          <div className="rounded-2xl border border-neutral-200 bg-neutral-50 p-5"><p className="text-sm font-medium text-neutral-500">Draft total</p><p className="mt-2 text-3xl font-semibold">{money(invoiceTotal)}</p><p className="mt-4 text-sm leading-relaxed text-neutral-600">A draft can be edited and previewed. Once issued, financial fields are locked; changes require a credit or a replacement invoice so the audit trail stays trustworthy.</p><div className="mt-6 space-y-2"><Button className="w-full" onClick={submitDraft} disabled={busy}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}{editingDraftId ? 'Save changes' : 'Save draft'}</Button><Button className="w-full" variant="outline" onClick={closeDraftModal}>Cancel</Button></div></div>
        </div>
      </ModalShell>}

      {modal === 'import' && <ModalShell title="Import an outside invoice" subtitle="For outgoing invoices created somewhere else. Vendor bills and expenses do not belong here." onClose={() => setModal(null)}>
        <div className="space-y-5">
          <label className="flex cursor-pointer flex-col items-center justify-center rounded-2xl border-2 border-dashed border-neutral-300 bg-neutral-50 px-6 py-8 text-center hover:border-primary-400"><Upload className="h-8 w-8 text-primary-600" /><span className="mt-3 font-medium text-neutral-900">{importForm.file?.name || 'Choose the original PDF or image'}</span><span className="mt-1 text-sm text-neutral-500">PDF, JPEG, PNG, or WebP · up to 15 MB</span><input type="file" className="sr-only" accept="application/pdf,image/jpeg,image/png,image/webp" onChange={(e) => setImportForm({ ...importForm, file: e.target.files?.[0] || null })} /></label>
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="text-sm font-medium">From<select value={importForm.invoice_billing_profile_id} onChange={(e) => setImportForm({ ...importForm, invoice_billing_profile_id: e.target.value })} className="mt-1 h-10 w-full rounded-md border border-neutral-300 bg-white px-3"><option value="">Choose billing profile</option>{activeProfiles.map((profile) => <option key={profile.id} value={profile.id}>{profile.name}</option>)}</select></label>
            <label className="text-sm font-medium">Customer<select value={importForm.invoice_recipient_id} onChange={(e) => setImportForm({ ...importForm, invoice_recipient_id: e.target.value })} className="mt-1 h-10 w-full rounded-md border border-neutral-300 bg-white px-3"><option value="">Choose customer</option>{recipients.map((recipient) => <option key={recipient.id} value={recipient.id}>{recipient.name}</option>)}</select></label>
            <label className="text-sm font-medium">Invoice number<Input className="mt-1" value={importForm.invoice_number} onChange={(e) => setImportForm({ ...importForm, invoice_number: e.target.value })} /></label>
            <label className="text-sm font-medium">Invoice total<Input className="mt-1" type="number" min="0.01" step="0.01" value={importForm.total_amount} onChange={(e) => setImportForm({ ...importForm, total_amount: e.target.value })} /></label>
            <label className="text-sm font-medium">Invoice date<Input className="mt-1" type="date" value={importForm.invoice_date} onChange={(e) => setImportForm({ ...importForm, invoice_date: e.target.value })} /></label>
            <label className="text-sm font-medium">Due date<Input className="mt-1" type="date" value={importForm.due_date} onChange={(e) => setImportForm({ ...importForm, due_date: e.target.value })} /></label>
            <label className="text-sm font-medium">Customer reference<Input className="mt-1" value={importForm.customer_reference} onChange={(e) => setImportForm({ ...importForm, customer_reference: e.target.value })} /></label>
            <label className="text-sm font-medium">Already sent at <span className="font-normal text-neutral-400">(optional)</span><Input className="mt-1" type="datetime-local" value={importForm.delivered_at} onChange={(e) => setImportForm({ ...importForm, delivered_at: e.target.value })} /></label>
          </div>
          <label className="text-sm font-medium">Internal notes<Textarea className="mt-1" value={importForm.notes} onChange={(e) => setImportForm({ ...importForm, notes: e.target.value })} rows={3} /></label>
          <div className="flex justify-end gap-2"><Button variant="outline" onClick={() => setModal(null)}>Cancel</Button><Button onClick={submitImport} disabled={busy}><Import className="mr-1.5 h-4 w-4" />Import and track</Button></div>
        </div>
      </ModalShell>}

      {modal === 'details' && selected && <ModalShell title={`${selected.invoice_number} · ${selected.recipient_name || 'Customer'}`} subtitle={`${selected.origin === 'imported' ? 'Imported invoice' : 'Cornerstone invoice'} · ${statusLabel(selected.status)}`} onClose={() => { setModal(null); setDetailAction(null); }} wide>
        <div className={`space-y-6 transition-opacity duration-200 ${busy ? 'opacity-70' : 'opacity-100'}`}>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {[['Invoice total', money(selected.total_amount, selected.currency)], ['Paid', money(selected.amount_paid, selected.currency)], ['Credits', money(selected.credit_total, selected.currency)], ['Balance due', money(selected.balance_due, selected.currency)]].map(([label, value]) => <div key={label} className="rounded-xl border border-neutral-200 p-4"><p className="text-xs font-medium uppercase tracking-wide text-neutral-400">{label}</p><p className="mt-2 text-xl font-semibold">{value}</p></div>)}
          </div>
          {selected.legacy_artifact_missing && <div className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">This legacy invoice has lifecycle history but no exact preserved file. New and imported invoices always preserve immutable evidence.</div>}
          <div className="flex min-h-11 flex-wrap gap-2 transition-all duration-200">
            <Button variant="outline" onClick={previewSelected} disabled={busy}><Eye className="mr-1.5 h-4 w-4" />Preview</Button>
            {selected.status === 'draft' ? <><Button variant="outline" onClick={editSelectedDraft}>Edit draft</Button><Button onClick={issueSelected} disabled={busy}><CheckCircle2 className="mr-1.5 h-4 w-4" />Issue invoice</Button></> : <Button variant="outline" onClick={downloadSelected} disabled={!selected.has_artifact || busy}><Download className="mr-1.5 h-4 w-4" />Download original</Button>}
            {!['draft', 'voided'].includes(selected.status) && <Button variant="outline" onClick={() => setDetailAction('delivery')}><MailCheck className="mr-1.5 h-4 w-4" />Record delivery</Button>}
            {!['draft', 'voided', 'uncollectible'].includes(selected.status) && <><Button variant="outline" onClick={() => setDetailAction('payment')} disabled={selected.balance_due <= 0}><CircleDollarSign className="mr-1.5 h-4 w-4" />Record payment</Button><Button variant="outline" onClick={() => setDetailAction('credit')} disabled={selected.balance_due <= 0}><FileText className="mr-1.5 h-4 w-4" />Issue credit</Button></>}
            {selected.archived ? <Button variant="outline" onClick={() => changeLifecycle('restored')}><RotateCcw className="mr-1.5 h-4 w-4" />Restore</Button> : <Button variant="outline" onClick={() => changeLifecycle('archived')}><Archive className="mr-1.5 h-4 w-4" />Archive</Button>}
            {selected.status === 'open' || selected.status === 'overdue' || selected.status === 'partially_paid' ? <Button variant="outline" onClick={() => changeLifecycle('uncollectible')}>Mark uncollectible</Button> : null}
            {!['draft', 'voided', 'paid'].includes(selected.status) && <Button variant="outline" className="text-red-700" onClick={() => changeLifecycle('voided')}>Void invoice</Button>}
          </div>

          {detailAction && <div key={detailAction} className="invoice-action-panel rounded-2xl border border-primary-200 bg-primary-50/40 p-4">
            {detailAction === 'payment' && <form onSubmit={submitPayment} className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5"><label className="text-sm font-medium">Amount<Input required name="amount" type="number" min="0.01" max={selected.balance_due} step="0.01" defaultValue={selected.balance_due} className="mt-1" /></label><label className="text-sm font-medium">Received on<Input required name="received_on" type="date" defaultValue={dateOnly()} className="mt-1" /></label><label className="text-sm font-medium">Method<select name="payment_method" className="mt-1 h-10 w-full rounded-md border border-neutral-300 bg-white px-3"><option value="check">Check</option><option value="ach">ACH</option><option value="cash">Cash</option><option value="card">Card</option><option value="wire">Wire</option><option value="other">Other</option></select></label><label className="text-sm font-medium">Reference<Input name="reference_number" className="mt-1" /></label><div className="flex items-end gap-2"><Button type="submit" disabled={busy}>Save payment</Button><Button type="button" variant="ghost" onClick={() => setDetailAction(null)}>Cancel</Button></div></form>}
            {detailAction === 'delivery' && <form onSubmit={submitDelivery} className="grid gap-3 sm:grid-cols-2 lg:grid-cols-6"><label className="text-sm font-medium">Channel<select name="channel" className="mt-1 h-10 w-full rounded-md border border-neutral-300 bg-white px-3"><option value="email">Email</option><option value="mail">Mail</option><option value="hand_delivery">Hand delivery</option><option value="portal">Portal</option><option value="other">Other</option></select></label><label className="text-sm font-medium">Recipient<Input name="recipient" defaultValue={selected.invoice_recipient?.email || ''} className="mt-1" /></label><label className="text-sm font-medium">Delivered at<Input name="delivered_at" type="datetime-local" className="mt-1" /></label><label className="text-sm font-medium">Reference<Input name="provider_reference" className="mt-1" /></label><label className="text-sm font-medium">Notes<Input name="notes" className="mt-1" /></label><div className="flex items-end gap-2"><Button type="submit" disabled={busy}>Record delivery</Button><Button type="button" variant="ghost" onClick={() => setDetailAction(null)}>Cancel</Button></div></form>}
            {detailAction === 'credit' && <form onSubmit={submitCredit} className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"><label className="text-sm font-medium">Amount<Input required name="amount" type="number" min="0.01" max={selected.balance_due} step="0.01" className="mt-1" /></label><label className="text-sm font-medium">Issue date<Input required name="issue_date" type="date" defaultValue={dateOnly()} className="mt-1" /></label><label className="text-sm font-medium">Reason<Input required name="reason" className="mt-1" /></label><div className="flex items-end gap-2"><Button type="submit" disabled={busy}>Issue credit</Button><Button type="button" variant="ghost" onClick={() => setDetailAction(null)}>Cancel</Button></div></form>}
          </div>}

          <div className="grid gap-6 lg:grid-cols-2">
            <div className="space-y-4"><div className="rounded-xl border border-neutral-200 p-4"><h3 className="font-semibold">Invoice details</h3><dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-3 text-sm"><div><dt className="text-neutral-400">From</dt><dd className="font-medium">{selected.billing_profile_name}</dd></div><div><dt className="text-neutral-400">Customer</dt><dd className="font-medium">{selected.recipient_name}</dd></div><div><dt className="text-neutral-400">Invoice date</dt><dd>{formatDate(selected.invoice_date)}</dd></div><div><dt className="text-neutral-400">Due date</dt><dd>{formatDate(selected.due_date)}</dd></div><div><dt className="text-neutral-400">Reference</dt><dd>{selected.customer_reference || '—'}</dd></div><div><dt className="text-neutral-400">Source</dt><dd className="capitalize">{selected.origin}</dd></div></dl></div>
              {!!selected.line_items?.length && <div className="rounded-xl border border-neutral-200 p-4"><h3 className="font-semibold">Line items</h3><div className="mt-3 divide-y divide-neutral-100">{selected.line_items.map((line) => <div key={line.id || line.description} className="flex justify-between gap-4 py-2 text-sm"><div><p className="font-medium">{line.description}</p><p className="text-neutral-400">{line.quantity} × {money(line.rate, selected.currency)}</p></div><span className="font-semibold">{money(line.amount, selected.currency)}</span></div>)}</div></div>}
            </div>
            <div className="space-y-4">
              <div className="rounded-xl border border-neutral-200 p-4"><div className="flex items-center justify-between gap-3"><h3 className="flex items-center gap-2 font-semibold"><History className="h-4 w-4" />Payments and credits</h3><span className="text-xs text-neutral-400">Newest activity first</span></div><div className="mt-3 space-y-2">
                {financialActivity.map((activity) => activity.kind === 'payment' ? (
                  <div key={`payment-${activity.payment.id}`} className="flex items-start justify-between gap-3 rounded-lg bg-neutral-50 p-3 text-sm"><div><p className="font-medium">Payment · {money(activity.payment.amount, selected.currency)}</p><p className="text-neutral-500">Effective {formatDate(activity.payment.received_on)} · {activity.payment.payment_method}{activity.payment.reference_number ? ` · ${activity.payment.reference_number}` : ''}</p><p className="mt-1 text-xs text-neutral-400">Recorded {formatDateTime(activity.payment.created_at)}{activity.payment.recorded_by_name ? ` · ${activity.payment.recorded_by_name}` : ''}</p>{activity.payment.reversed && <p className="mt-1 text-red-600">Reversed {formatDateTime(activity.payment.reversed_at)}: {activity.payment.reversal_reason}</p>}</div>{!activity.payment.reversed && <button onClick={() => reversePayment(activity.payment.id)} className="text-xs font-medium text-red-600"><Undo2 className="mr-1 inline h-3 w-3" />Reverse</button>}</div>
                ) : (
                  <div key={`credit-${activity.credit.id}`} className="flex items-start justify-between gap-3 rounded-lg bg-neutral-50 p-3 text-sm"><div><p className="font-medium">Credit {activity.credit.credit_number} · {money(activity.credit.total_amount, selected.currency)}</p><p className="text-neutral-500">Effective {formatDate(activity.credit.issue_date)} · {activity.credit.reason}</p><p className="mt-1 text-xs text-neutral-400">Recorded {formatDateTime(activity.credit.created_at)}{activity.credit.issued_by_name ? ` · ${activity.credit.issued_by_name}` : ''}</p>{activity.credit.status === 'voided' && <p className="mt-1 text-red-600">Voided {formatDateTime(activity.credit.voided_at)}: {activity.credit.void_reason}</p>}</div>{activity.credit.status === 'issued' && <button onClick={() => voidCredit(activity.credit.id)} className="text-xs font-medium text-red-600">Void</button>}</div>
                ))}
                {!financialActivity.length && <p className="py-3 text-sm text-neutral-500">No payments or credits recorded.</p>}
              </div></div>
              <div className="rounded-xl border border-neutral-200 p-4"><div className="flex items-center justify-between gap-3"><h3 className="flex items-center gap-2 font-semibold"><MailCheck className="h-4 w-4" />Delivery history</h3><span className="text-xs text-neutral-400">Newest first</span></div><div className="mt-3 space-y-2">{deliveryHistory.map((delivery) => <div key={delivery.id} className="rounded-lg bg-neutral-50 p-3 text-sm"><div className="flex flex-wrap items-center justify-between gap-2"><p className="font-medium capitalize">{delivery.channel.replaceAll('_', ' ')}</p><span className="text-xs text-neutral-400">{formatDateTime(delivery.delivered_at)}</span></div><p className="mt-1 text-neutral-600">To {delivery.recipient || 'Recipient not recorded'}</p>{delivery.provider_reference && <p className="mt-1 text-xs text-neutral-500">Reference: {delivery.provider_reference}</p>}{delivery.notes && <p className="mt-1 text-xs text-neutral-500">{delivery.notes}</p>}<p className="mt-1 text-xs text-neutral-400">Recorded {formatDateTime(delivery.created_at)}{delivery.recorded_by_name ? ` · ${delivery.recorded_by_name}` : ''}{delivery.artifact_id ? ' · Preserved invoice attached' : ''}</p></div>)}{!deliveryHistory.length && <p className="py-3 text-sm text-neutral-500">No delivery has been recorded.</p>}</div></div>
              <div className="rounded-xl border border-neutral-200 p-4"><div className="flex items-center justify-between gap-3"><h3 className="flex items-center gap-2 font-semibold"><History className="h-4 w-4" />Audit timeline</h3><span className="text-xs text-neutral-400">Recorded order</span></div><div className="mt-3 space-y-3">{auditTimeline.map((event) => { const effectiveDiffers = Math.abs(new Date(event.created_at).getTime() - new Date(event.occurred_at).getTime()) > 60_000; return <div key={event.id} className="flex gap-3 text-sm"><span className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-primary-500" /><div><p className="font-medium capitalize">{event.event_type.replaceAll('_', ' ')}</p><p className="text-xs text-neutral-400">Recorded {formatDateTime(event.created_at)}{event.actor_name ? ` · ${event.actor_name}` : ''}</p>{effectiveDiffers && <p className="text-xs text-neutral-400">Effective {formatDateTime(event.occurred_at)}</p>}</div></div>; })}</div></div>
            </div>
          </div>
        </div>
      </ModalShell>}

      {previewUrl && <div className="invoice-modal-backdrop fixed inset-0 z-[60] flex items-center justify-center bg-neutral-950/60 p-4"><div className="invoice-modal-panel flex h-[92vh] w-full max-w-6xl flex-col overflow-hidden rounded-2xl bg-white"><div className="flex items-center justify-between border-b px-4 py-3"><div><span className="font-semibold">Invoice preview</span>{selected && <span className="ml-2 text-sm text-neutral-400">{selected.invoice_number}</span>}</div><Button variant="ghost" onClick={() => { URL.revokeObjectURL(previewUrl); setPreviewUrl(null); }}>Close</Button></div><iframe title="Invoice preview" src={previewUrl} className="h-full w-full" /></div></div>}

      {busy && !modal && <div className="fixed bottom-6 right-6 z-50 flex items-center gap-2 rounded-full bg-neutral-950 px-4 py-2 text-sm text-white shadow-lg"><Loader2 className="h-4 w-4 animate-spin" />Working</div>}
    </div>
  );
}
