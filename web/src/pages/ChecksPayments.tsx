import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Link } from 'react-router';
import { CheckCircle2, Copy, Download, FileText, Printer, Search, Settings, Trash2 } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { NumericInput } from '@/components/ui/numeric-input';
import { nonEmployeeChecksApi, companiesApi, payrollLiabilityCenterApi, type CompanyDetail } from '@/services/api';
import { useCompany } from '@/contexts/CompanyContext';
import type { NonEmployeeCheck, NonEmployeeCheckType, OutgoingPaymentMethod, PaymentPeriodType, PayrollLiabilityCenter as PayrollLiabilityCenterData, PayrollLiabilityCenterObligation } from '@/types';
import { NonEmployeeCheckEditModal } from '@/components/checks/NonEmployeeCheckEditModal';
import { NonEmployeeCheckHistory } from '@/components/checks/NonEmployeeCheckHistory';
import { VoucherLineItemsEditor } from '@/components/checks/VoucherLineItemsEditor';
import { normalizeVoucherLineItems, type VoucherLineItemForm } from '@/components/checks/voucherLineItems';
import { DRT } from '@/lib/constants';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { PayrollLiabilityCenter } from '@/components/payroll/PayrollLiabilityCenter';
import { formatDateRange } from '@/lib/utils';

const CHECK_TYPE_LABELS: Record<NonEmployeeCheckType, string> = {
  contractor: 'Contractor',
  tax_deposit: 'FIT / Tax Deposit',
  grt: 'GRT',
  estimated_tax: 'Estimated Tax',
  w1_balance: 'W-1 Balance',
  swica: 'SWICA',
  child_support: 'Child Support',
  garnishment: 'Garnishment',
  vendor: 'Vendor',
  reimbursement: 'Reimbursement',
  other: 'Other',
};

const STANDALONE_TYPES: NonEmployeeCheckType[] = [
  'tax_deposit',
  'grt',
  'estimated_tax',
  'w1_balance',
  'swica',
  'child_support',
  'garnishment',
  'vendor',
  'reimbursement',
  'contractor',
  'other',
];

const PERIOD_LABELS: Record<PaymentPeriodType, string> = {
  none: 'No tax period',
  pay_period: 'Pay period',
  month: 'Monthly',
  quarter: 'Quarterly',
  year: 'Annual',
};

const STATUS_COLORS: Record<string, string> = {
  pending: 'bg-gray-100 text-gray-700',
  prepared: 'bg-blue-100 text-blue-800',
  unprinted: 'bg-yellow-100 text-yellow-700',
  printed: 'bg-green-100 text-green-700',
  paid: 'bg-emerald-100 text-emerald-800',
  voided: 'bg-red-100 text-red-700',
};

interface FormState {
  pay_period_id: number | null;
  payable_to: string;
  amount: string;
  check_type: NonEmployeeCheckType;
  check_number: string;
  payment_method: OutgoingPaymentMethod;
  payment_period_type: PaymentPeriodType;
  tax_year: string;
  tax_quarter: string;
  tax_month: string;
  due_date: string;
  payment_date: string;
  confirmation_number: string;
  memo: string;
  reference_number: string;
  description: string;
  line_items: VoucherLineItemForm[];
  liability_entry_ids: number[];
}

function localDateString() {
  const date = new Date();
  const yyyy = date.getFullYear();
  const mm = String(date.getMonth() + 1).padStart(2, '0');
  const dd = String(date.getDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
}

function initialFormState(): FormState {
  const today = new Date();
  return {
    pay_period_id: null,
    payable_to: '',
    amount: '',
    check_type: 'grt',
    check_number: '',
    payment_method: 'check',
    payment_period_type: 'month',
    tax_year: String(today.getFullYear()),
    tax_quarter: String(Math.floor(today.getMonth() / 3) + 1),
    tax_month: String(today.getMonth() + 1),
    due_date: '',
    payment_date: localDateString(),
    confirmation_number: '',
    memo: '',
    reference_number: '',
    description: '',
    line_items: [],
    liability_entry_ids: [],
  };
}

const fieldClassName = 'rounded-xl';

function periodPayload(form: Pick<FormState, 'payment_period_type' | 'tax_year' | 'tax_quarter' | 'tax_month'>) {
  const usesTaxYear = ['month', 'quarter', 'year'].includes(form.payment_period_type);
  return {
    payment_period_type: form.payment_period_type,
    tax_year: usesTaxYear && form.tax_year ? Number(form.tax_year) : null,
    tax_quarter: form.payment_period_type === 'quarter' && form.tax_quarter
      ? Number(form.tax_quarter)
      : null,
    tax_month: form.payment_period_type === 'month' && form.tax_month
      ? Number(form.tax_month)
      : null,
  };
}

export function ChecksPayments() {
  const { activeCompanyId } = useCompany();
  const [checks, setChecks] = useState<NonEmployeeCheck[]>([]);
  const [company, setCompany] = useState<CompanyDetail | null>(null);
  const [liabilityCenter, setLiabilityCenter] = useState<PayrollLiabilityCenterData | null>(null);
  const [liabilityLoading, setLiabilityLoading] = useState(true);
  const [liabilityError, setLiabilityError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [creating, setCreating] = useState(false);
  const [form, setForm] = useState<FormState>(() => initialFormState());
  const [typeFilter, setTypeFilter] = useState<string>('all');
  const [statusFilter, setStatusFilter] = useState<string>('active');
  const [search, setSearch] = useState('');
  const [editingCheck, setEditingCheck] = useState<NonEmployeeCheck | null>(null);
  const [historyIds, setHistoryIds] = useState<Set<number>>(new Set());
  const [voidingId, setVoidingId] = useState<number | null>(null);
  const [voidReason, setVoidReason] = useState('');
  const [busyId, setBusyId] = useState<number | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [previewCheck, setPreviewCheck] = useState<NonEmployeeCheck | null>(null);
  const [previewTitle, setPreviewTitle] = useState('Check preview');
  const [previewLoaded, setPreviewLoaded] = useState(false);
  const [startingSlot, setStartingSlot] = useState(1);
  const [payingCheck, setPayingCheck] = useState<NonEmployeeCheck | null>(null);
  const [paymentConfirmation, setPaymentConfirmation] = useState('');
  const [paymentDate, setPaymentDate] = useState(localDateString());
  const previewFrameRef = useRef<HTMLIFrameElement | null>(null);

  const loadChecks = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await nonEmployeeChecksApi.list({
        ...(statusFilter === 'active' ? { active: 'true' } : {}),
        ...(typeFilter !== 'all' ? { check_type: typeFilter } : {}),
      });
      setChecks(response.non_employee_checks);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load checks');
    } finally {
      setLoading(false);
    }
  }, [statusFilter, typeFilter]);

  const loadLiabilities = useCallback(async () => {
    setLiabilityLoading(true);
    setLiabilityError(null);
    try {
      const response = await payrollLiabilityCenterApi.get();
      setLiabilityCenter(response.payroll_liability_center);
    } catch (err) {
      setLiabilityError(err instanceof Error ? err.message : 'Failed to load payroll liabilities');
    } finally {
      setLiabilityLoading(false);
    }
  }, []);

  useEffect(() => {
    loadChecks();
  }, [loadChecks]);

  useEffect(() => {
    void loadLiabilities();
  }, [activeCompanyId, loadLiabilities]);

  useEffect(() => {
    if (!activeCompanyId) return;
    companiesApi.get(activeCompanyId).then(res => setCompany(res.company)).catch(() => {});
  }, [activeCompanyId]);

  const visibleChecks = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return checks;
    return checks.filter(check =>
      [
        check.payable_to,
        check.check_number,
        check.memo,
        check.description,
        check.reference_number,
        check.confirmation_number,
        CHECK_TYPE_LABELS[check.check_type],
      ]
        .filter(Boolean)
        .some(value => String(value).toLowerCase().includes(q))
    );
  }, [checks, search]);

  const totals = useMemo(() => {
    const active = visibleChecks.filter(check => !check.voided);
    return {
      count: active.length,
      amount: active.reduce((sum, check) => sum + Number(check.amount), 0),
    };
  }, [visibleChecks]);

  const handleCreate = async () => {
    setError(null);
    if (!form.payable_to.trim() || !form.amount) {
      setError('Payable to and amount are required');
      return;
    }

    const payload = {
      pay_period_id: form.pay_period_id,
      payable_to: form.payable_to.trim(),
      amount: Number(form.amount),
      check_type: form.check_type,
      check_number: form.check_number.trim() || undefined,
      ...periodPayload(form),
      due_date: form.due_date || null,
      payment_date: form.payment_date || null,
      confirmation_number: form.confirmation_number.trim() || null,
      payment_method: form.payment_method,
      liability_entry_ids: form.liability_entry_ids,
      memo: form.memo.trim() || undefined,
      reference_number: form.reference_number.trim() || undefined,
      description: form.description.trim() || undefined,
    };
    const lineItems = normalizeVoucherLineItems(form.line_items);
    if (form.line_items.length > 0 && lineItems.length !== form.line_items.length) {
      setError('Each voucher detail line needs an amount, or remove the incomplete line');
      return;
    }
    if (lineItems.length > 0) {
      const lineTotal = lineItems.reduce((sum, item) => sum + item.amount, 0);
      if (Math.abs(lineTotal - Number(form.amount)) > 0.005) {
        setError('Voucher line items must total the check amount');
        return;
      }
      Object.assign(payload, { line_items_attributes: lineItems });
    }

    setCreating(true);
    try {
      await nonEmployeeChecksApi.create(payload);
      setShowForm(false);
      setForm(initialFormState());
      await Promise.all([loadChecks(), loadLiabilities()]);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create check');
    } finally {
      setCreating(false);
    }
  };

  const handleCloneCheck = (check: NonEmployeeCheck) => {
    setError(null);
    setShowForm(true);
    setForm({
      // A clone is a new standalone payment. Never carry an old payroll run
      // association forward without also carrying its exact liability journal
      // allocation, which intentionally cannot be cloned.
      pay_period_id: null,
      payable_to: check.payable_to || '',
      amount: check.amount != null ? String(check.amount) : '',
      check_type: check.check_type,
      check_number: '',
      payment_method: check.payment_method || 'check',
      payment_period_type: check.payment_period_type === 'pay_period'
        ? 'none'
        : check.payment_period_type || 'none',
      tax_year: check.tax_year ? String(check.tax_year) : String(new Date().getFullYear()),
      tax_quarter: check.tax_quarter ? String(check.tax_quarter) : String(Math.floor(new Date().getMonth() / 3) + 1),
      tax_month: check.tax_month ? String(check.tax_month) : String(new Date().getMonth() + 1),
      due_date: check.due_date || '',
      payment_date: localDateString(),
      confirmation_number: '',
      memo: check.memo || '',
      reference_number: check.reference_number || '',
      description: check.description || '',
      line_items: (check.line_items || []).map((lineItem) => ({
        description: lineItem.description || '',
        reference_number: lineItem.reference_number || '',
        service_period: lineItem.service_period || '',
        amount: lineItem.amount != null ? String(lineItem.amount) : '',
      })),
      liability_entry_ids: [],
    });
    window.requestAnimationFrame(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  };

  const handleSavedCheck = (updated: NonEmployeeCheck) => {
    setChecks(prev => prev.map(check => (check.id === updated.id ? updated : check)));
    setPreviewCheck(prev => (prev?.id === updated.id ? updated : prev));
  };

  const handlePrepareLiabilities = (obligations: PayrollLiabilityCenterObligation[]) => {
    const amount = obligations.reduce((sum, obligation) => sum + Math.max(obligation.unreserved_amount, 0), 0);
    const authority = obligations[0]?.authority || '';
    const payableTo = authority === 'Guam Department of Revenue and Taxation' ? 'Treasurer of Guam' : authority;
    setError(null);
    setShowForm(true);
    setForm({
      ...initialFormState(),
      pay_period_id: obligations.length === 1 ? obligations[0].pay_period_id : null,
      payable_to: payableTo,
      amount: amount.toFixed(2),
      check_type: liabilityPaymentType(obligations),
      payment_period_type: obligations.length === 1 ? 'pay_period' : 'none',
      memo: obligations.length === 1
        ? `Payroll liabilities · PPE ${formatDate(obligations[0].period_end)}`
        : `Combined payroll liabilities · ${obligations.length} pay periods`,
      description: `Prepared from committed payroll liability journal for ${authority}.`,
      liability_entry_ids: obligations.flatMap((obligation) => obligation.entry_ids),
      line_items: obligations.map((obligation) => ({
        description: `${authority} · PPE ${formatDate(obligation.period_end)}`,
        reference_number: '',
        service_period: formatDateRange(obligation.period_start, obligation.period_end),
        amount: Math.max(obligation.unreserved_amount, 0).toFixed(2),
      })),
    });
    window.requestAnimationFrame(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  };

  const handleMarkPrinted = async (check: NonEmployeeCheck) => {
    setBusyId(check.id);
    try {
      const response = await nonEmployeeChecksApi.markPrinted(check.id);
      handleSavedCheck(response.non_employee_check);
      await loadLiabilities();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to mark printed');
    } finally {
      setBusyId(null);
    }
  };

  const handleMarkPaid = async () => {
    if (!payingCheck || !paymentDate) return;
    setBusyId(payingCheck.id);
    setError(null);
    try {
      const response = await nonEmployeeChecksApi.markPaid(payingCheck.id, {
        payment_date: paymentDate,
        confirmation_number: paymentConfirmation.trim() || undefined,
      });
      handleSavedCheck(response.non_employee_check);
      setPayingCheck(null);
      setPaymentConfirmation('');
      await loadLiabilities();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to mark payment paid');
    } finally {
      setBusyId(null);
    }
  };

  const handleVoid = async (check: NonEmployeeCheck) => {
    if (!voidReason.trim()) return;
    setBusyId(check.id);
    try {
      await nonEmployeeChecksApi.voidCheck(check.id, voidReason.trim());
      await Promise.all([loadChecks(), loadLiabilities()]);
      setVoidingId(null);
      setVoidReason('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to void check');
    } finally {
      setBusyId(null);
    }
  };

  const handleDelete = async (check: NonEmployeeCheck) => {
    if (!window.confirm(`Delete the payment to ${check.payable_to}?`)) return;
    setBusyId(check.id);
    try {
      await nonEmployeeChecksApi.delete(check.id);
      setChecks(prev => prev.filter(c => c.id !== check.id));
      await loadLiabilities();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete check');
    } finally {
      setBusyId(null);
    }
  };

  const handlePreview = async (check: NonEmployeeCheck) => {
    setBusyId(check.id);
    setPreviewLoaded(false);
    try {
      const blob = await nonEmployeeChecksApi.checkPdf(
        check.id,
        company?.check_stock_type === 'first_hawaiian_4up' ? { startingSlot } : undefined
      );
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      setPreviewUrl(URL.createObjectURL(blob));
      setPreviewCheck(check);
      setPreviewTitle('Check preview');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to generate check PDF');
    } finally {
      setBusyId(null);
    }
  };

  const handleVoucherPreview = async (check: NonEmployeeCheck) => {
    setBusyId(check.id);
    setPreviewLoaded(false);
    try {
      const blob = await nonEmployeeChecksApi.voucherPdf(check.id);
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      setPreviewUrl(URL.createObjectURL(blob));
      setPreviewCheck(check);
      setPreviewTitle('Payment voucher');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to generate payment voucher');
    } finally {
      setBusyId(null);
    }
  };

  const closePreview = () => {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    setPreviewUrl(null);
    setPreviewCheck(null);
    setPreviewLoaded(false);
  };

  const handlePrintPreview = () => {
    const frameWindow = previewFrameRef.current?.contentWindow;
    if (!frameWindow || !previewLoaded) return;
    frameWindow.focus();
    frameWindow.print();
  };

  const exportRegisterCsv = () => {
    const headers = [
      'Payee',
      'Amount',
      'Type',
      'Status',
      'Payment Method',
      'Check Number',
      'Payment Date',
      'Paid At',
      'Paid By',
      'Payroll Liability Allocated',
      'Due Date',
      'Tax Period',
      'Tax Year',
      'Tax Quarter',
      'Tax Month',
      'Confirmation Number',
      'Reference Number',
      'Memo',
      'Description',
      'Created By',
      'Created At',
    ];
    const rows = visibleChecks.map(check => [
      check.payable_to,
      Number(check.amount).toFixed(2),
      CHECK_TYPE_LABELS[check.check_type],
      check.check_status,
      check.payment_method,
      check.check_number || '',
      check.payment_date || '',
      check.paid_at || '',
      check.paid_by_name || '',
      check.liability_allocated_amount ? Number(check.liability_allocated_amount).toFixed(2) : '',
      check.due_date || '',
      periodLabel(check),
      check.tax_year || '',
      check.tax_quarter || '',
      check.tax_month || '',
      check.confirmation_number || '',
      check.reference_number || '',
      check.memo || '',
      check.description || '',
      check.created_by_name || '',
      check.created_at,
    ]);
    const csv = [headers, ...rows].map(row => row.map(csvCell).join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    const date = new Date().toISOString().slice(0, 10);
    link.href = url;
    link.download = `checks_payments_register_${date}.csv`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 100);
  };

  const toggleCreateForm = () => {
    setShowForm((current) => {
      const next = !current;
      if (next) setForm(initialFormState());
      return next;
    });
  };

  const toggleHistory = (id: number) => {
    setHistoryIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  return (
    <div className="min-h-full bg-neutral-50">
      <Header
        title="Checks & Payments"
        description="Prepare checks and electronic payments, then reconcile payroll taxes and other obligations in one place."
        actions={
          <Button onClick={toggleCreateForm}>
            {showForm ? 'Cancel' : 'New Payment'}
          </Button>
        }
      />

      <div className="space-y-4 p-4 sm:p-6 lg:p-8">
        {error && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
            {error}
          </div>
        )}

        {showForm && (
          <Card className="p-4 sm:p-5">
            {form.liability_entry_ids.length > 0 && (
              <div className="mb-4 rounded-xl border border-primary-200 bg-primary-50 px-4 py-3 text-sm text-primary-900">
                <p className="font-semibold">Connected to committed payroll</p>
                <p className="mt-2 leading-5">This payment reserves the selected liability journal entries. It will not count as paid until you explicitly confirm it below.</p>
              </div>
            )}
            <div className="grid grid-cols-1 gap-4 md:grid-cols-4">
              <Input
                label="Payable to"
                placeholder="e.g., Treasurer of Guam"
                value={form.payable_to}
                onChange={e => setForm(p => ({ ...p, payable_to: e.target.value }))}
              />
              <FormField label="Amount">
                <NumericInput
                  placeholder="e.g., 256.78"
                  min={0.01}
                  fixedDecimalsOnBlur={2}
                  value={form.amount === '' ? null : Number(form.amount)}
                  onValueChange={value => setForm(p => ({ ...p, amount: value == null ? '' : String(value) }))}
                />
              </FormField>
              <Select
                label="Check type"
                value={form.check_type}
                onChange={e => setForm(p => ({ ...p, check_type: e.target.value as NonEmployeeCheckType }))}
              >
                {STANDALONE_TYPES.map(type => <option key={type} value={type}>{CHECK_TYPE_LABELS[type]}</option>)}
              </Select>
              <Select
                label="Payment method"
                value={form.payment_method}
                onChange={e => setForm(p => ({ ...p, payment_method: e.target.value as OutgoingPaymentMethod, check_number: e.target.value === 'check' ? p.check_number : '' }))}
              >
                <option value="check">Paper check</option>
                <option value="ach">ACH</option>
                <option value="eftps">EFTPS</option>
                <option value="wire">Wire</option>
                <option value="card">Card</option>
                <option value="cash">Cash</option>
                <option value="other">Other</option>
              </Select>
              {form.payment_method === 'check' && <Input
                  label="Check number"
                  helperText="Optional until printed."
                  placeholder="e.g., 1234"
                  value={form.check_number}
                  onChange={e => setForm(p => ({ ...p, check_number: e.target.value }))}
                />}
              <Select
                label="Tax/reporting period"
                value={form.payment_period_type}
                disabled={form.liability_entry_ids.length > 0 && form.pay_period_id !== null}
                onChange={e => setForm(p => ({
                  ...p,
                  payment_period_type: e.target.value as PaymentPeriodType,
                  pay_period_id: e.target.value === 'pay_period' ? p.pay_period_id : null,
                }))}
              >
                {form.pay_period_id !== null && <option value="pay_period">Pay period</option>}
                {(['none', 'month', 'quarter', 'year'] as PaymentPeriodType[]).map(type => <option key={type} value={type}>{PERIOD_LABELS[type]}</option>)}
              </Select>
              {(['month', 'quarter', 'year'] as PaymentPeriodType[]).includes(form.payment_period_type) && (
                <Input
                  label="Tax year"
                  placeholder="e.g., 2026"
                  inputMode="numeric"
                  value={form.tax_year}
                  onChange={e => setForm(p => ({ ...p, tax_year: e.target.value }))}
                />
              )}
              {form.payment_period_type === 'quarter' && (
                <Select
                  label="Tax quarter"
                  value={form.tax_quarter}
                  onChange={e => setForm(p => ({ ...p, tax_quarter: e.target.value }))}
                >
                  {[1, 2, 3, 4].map(q => <option key={q} value={q}>Q{q}</option>)}
                </Select>
              )}
              {form.payment_period_type === 'month' && (
                <Select
                  label="Tax month"
                  value={form.tax_month}
                  onChange={e => setForm(p => ({ ...p, tax_month: e.target.value }))}
                >
                  {Array.from({ length: 12 }, (_, i) => i + 1).map(month => <option key={month} value={month}>{new Date(2026, month - 1, 1).toLocaleString(undefined, { month: 'long' })}</option>)}
                </Select>
              )}
              <Input
                label="Payment date"
                helperText="Planned issue date. Confirming paid is a separate step."
                type="date"
                value={form.payment_date}
                onChange={e => setForm(p => ({ ...p, payment_date: e.target.value }))}
              />
              <Input
                label="Due date"
                helperText="Deadline for the tax bill or obligation."
                type="date"
                value={form.due_date}
                onChange={e => setForm(p => ({ ...p, due_date: e.target.value }))}
              />
              <Input
                label="Confirmation number"
                placeholder="e.g., GRT-2026-05"
                value={form.confirmation_number}
                onChange={e => setForm(p => ({ ...p, confirmation_number: e.target.value }))}
              />
              <Input
                label="Reference number"
                placeholder="e.g., invoice or tax voucher #"
                value={form.reference_number}
                onChange={e => setForm(p => ({ ...p, reference_number: e.target.value }))}
              />
              <Input
                label="Memo"
                placeholder="e.g., May GRT payment"
                value={form.memo}
                onChange={e => setForm(p => ({ ...p, memo: e.target.value }))}
              />
            </div>
            <FormField label="Description" className="mt-4">
              <textarea
                className={`${fieldClassName} min-h-[88px] w-full border border-neutral-300 bg-white px-3.5 py-2.5 text-sm text-neutral-900 shadow-sm transition-all duration-200 placeholder:text-neutral-400 focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200`}
                rows={2}
                placeholder="e.g., Notes about what this payment covers or how it was calculated"
                value={form.description}
                onChange={e => setForm(p => ({ ...p, description: e.target.value }))}
              />
            </FormField>
            {form.check_type === 'grt' && (
              <div className="mt-4 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <p className="font-semibold">GRT / Business Privilege Tax workflow</p>
                  <div className="flex flex-wrap gap-2 text-xs font-medium">
                    <a href={DRT.GUAMTAX_HOME} target="_blank" rel="noopener noreferrer" className="text-blue-700 underline underline-offset-2">Open GuamTax</a>
                    <a href={DRT.GUAMTAX_GRT_HELP} target="_blank" rel="noopener noreferrer" className="text-blue-700 underline underline-offset-2">GRT filing help</a>
                    <a href={DRT.BPT_EFILE_GUIDANCE_PDF} target="_blank" rel="noopener noreferrer" className="text-blue-700 underline underline-offset-2">BPT e-file guidance</a>
                  </div>
                </div>
                <ul className="mt-1 list-inside list-disc space-y-1">
                  <li>Total the client’s gross receipts/payments received for the filing month from the accounting records.</li>
                  <li>File the monthly GRT/BPT return through GuamTax.com; GuamTax calculates the tax due from the entered values.</li>
                  <li>Create this check for the GuamTax balance due, payable to Treasurer of Guam when paying in person.</li>
                  <li>If paying in person, bring two printed copies of the e-filed return: one for DRT/Treasurer and one stamped copy for the firm/client file.</li>
                  <li>Record the GuamTax confirmation number and keep this separate from payroll FIT/Form 500 tax deposits.</li>
                </ul>
              </div>
            )}
            <VoucherLineItemsEditor
              items={form.line_items}
              amount={form.amount}
              onChange={line_items => setForm(p => ({ ...p, line_items }))}
              className="mt-4"
            />
            {form.payment_method === 'check' && <div className="mt-4 rounded-xl border border-blue-100 bg-blue-50 px-4 py-3 text-sm text-blue-900">
              Checks & Payments uses the same stock type and X/Y alignment as payroll checks.
              Before printing on live check stock, test on plain paper or a photocopy of the real check first.
              <Link to="/check-settings" className="ml-1 font-medium text-blue-700 underline underline-offset-2">
                Open Check Settings
              </Link>
            </div>}
            <div className="mt-4 grid grid-cols-1 gap-2 sm:flex">
              <Button onClick={handleCreate} disabled={creating}>{creating ? 'Creating...' : form.liability_entry_ids.length > 0 ? 'Prepare Payment' : 'Create Payment'}</Button>
              <Button variant="outline" onClick={() => setShowForm(false)} disabled={creating}>Cancel</Button>
            </div>
          </Card>
        )}

        <PayrollLiabilityCenter
          center={liabilityCenter}
          loading={liabilityLoading}
          error={liabilityError}
          onPrepare={handlePrepareLiabilities}
          onUpdated={setLiabilityCenter}
        />

        <Card className="p-4">
          <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
            <div className="flex flex-1 items-center gap-2 rounded-lg border bg-white px-3 py-2">
              <Search className="h-4 w-4 text-neutral-400" />
              <input
                className="w-full bg-transparent text-sm outline-none"
                placeholder="Search payee, check number, memo, or confirmation"
                value={search}
                onChange={e => setSearch(e.target.value)}
              />
            </div>
            <div className="grid grid-cols-1 gap-2 sm:flex sm:flex-wrap [&>*]:w-full sm:[&>*]:w-auto">
              <select className="rounded-xl border border-neutral-300 bg-white px-3.5 py-2.5 text-sm" value={typeFilter} onChange={e => setTypeFilter(e.target.value)}>
                <option value="all">All types</option>
                {STANDALONE_TYPES.map(type => <option key={type} value={type}>{CHECK_TYPE_LABELS[type]}</option>)}
              </select>
              <select className="rounded-xl border border-neutral-300 bg-white px-3.5 py-2.5 text-sm" value={statusFilter} onChange={e => setStatusFilter(e.target.value)}>
                <option value="active">Active only</option>
                <option value="all">Include voided</option>
              </select>
              {company?.check_stock_type === 'first_hawaiian_4up' && (
                <select className="rounded-xl border border-neutral-300 bg-white px-3.5 py-2.5 text-sm" value={startingSlot} onChange={e => setStartingSlot(Number(e.target.value))}>
                  {[1, 2, 3, 4].map(slot => <option key={slot} value={slot}>Slot {slot}</option>)}
                </select>
              )}
              <Link
                to="/check-settings"
                className="inline-flex items-center rounded-xl border border-neutral-300 bg-white px-3.5 py-2.5 text-sm font-medium text-neutral-700 shadow-sm hover:bg-neutral-50"
              >
                <Settings className="mr-1.5 h-4 w-4" /> Check Settings
              </Link>
              <Button
                type="button"
                variant="outline"
                onClick={exportRegisterCsv}
                disabled={visibleChecks.length === 0}
              >
                <Download className="mr-1.5 h-4 w-4" /> Export Register
              </Button>
            </div>
          </div>
        </Card>

        <Card className="overflow-hidden">
          <div className="border-b bg-white px-4 py-3 text-sm text-neutral-600">
            {totals.count} active payment{totals.count === 1 ? '' : 's'} · {formatCurrency(totals.amount)}
          </div>
          {loading ? (
            <div className="p-6 text-sm text-neutral-500">Loading checks...</div>
          ) : visibleChecks.length === 0 ? (
            <div className="p-6 text-sm text-neutral-500">No payments found.</div>
          ) : (
            <div className="divide-y">
              {visibleChecks.map(check => (
                <div key={check.id} className={check.voided ? 'bg-red-50' : 'bg-white'}>
                  <div className="flex flex-col gap-3 p-4 xl:flex-row xl:items-center xl:justify-between">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="font-medium text-neutral-900">{check.payable_to}</span>
                        <Badge className={STATUS_COLORS[displayCheckStatus(check)] || 'bg-gray-100 text-gray-700'}>{displayCheckStatus(check)}</Badge>
                        <Badge variant="outline">{CHECK_TYPE_LABELS[check.check_type]}</Badge>
                        {check.liability_payment && <Badge variant="outline">Payroll liability</Badge>}
                        {check.edit_count ? (
                          <button className="text-xs font-medium text-blue-700" onClick={() => toggleHistory(check.id)}>
                            {check.edit_count} edit{check.edit_count === 1 ? '' : 's'}
                          </button>
                        ) : null}
                      </div>
                      <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-neutral-500">
                        <span className="font-semibold text-neutral-900">{formatCurrency(Number(check.amount))}</span>
                        <span>{check.payment_method === 'check' ? `Check #${check.check_number || '-'}` : check.payment_method.toUpperCase()}</span>
                        <span>{periodLabel(check)}</span>
                        {check.payment_date && <span>{check.paid_at ? 'Paid' : 'Payment date'} {formatDate(check.payment_date)}</span>}
                        {check.paid_by_name && <span>Confirmed by {check.paid_by_name}</span>}
                        {check.due_date && <span>Due {formatDate(check.due_date)}</span>}
                        {check.confirmation_number && <span>Confirmation {check.confirmation_number}</span>}
                        <span>Created {check.created_by_name ? `by ${check.created_by_name} ` : ''}{formatDate(check.created_at)}</span>
                      </div>
                      {(check.memo || check.description) && (
                        <p className="mt-1 max-w-3xl truncate text-sm text-neutral-600">{check.memo || check.description}</p>
                      )}
                      {check.check_type === 'grt' && (
                        <div className="mt-2 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900">
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <span className="font-semibold">GRT workflow reminder</span>
                            <div className="flex flex-wrap gap-2 font-medium">
                              <a href={DRT.GUAMTAX_HOME} target="_blank" rel="noopener noreferrer" className="text-blue-700 underline underline-offset-2">Open GuamTax</a>
                              <a href={DRT.GUAMTAX_GRT_HELP} target="_blank" rel="noopener noreferrer" className="text-blue-700 underline underline-offset-2">GRT help</a>
                            </div>
                          </div>
                          <p className="mt-1">
                            Confirm monthly receipts total, GuamTax filing/confirmation, and two printed return copies if paying in person.
                          </p>
                        </div>
                      )}
                    </div>
                    <div className="grid grid-cols-2 gap-2 sm:flex sm:flex-wrap sm:justify-end [&>button]:w-full sm:[&>button]:w-auto">
                      {check.payment_method === 'check' && <Button size="sm" variant="outline" onClick={() => handlePreview(check)} disabled={busyId === check.id}>
                        <FileText className="mr-1.5 h-3.5 w-3.5" /> Preview
                      </Button>}
                      <Button size="sm" variant="outline" onClick={() => handleVoucherPreview(check)} disabled={busyId === check.id}>
                        <FileText className="mr-1.5 h-3.5 w-3.5" /> Voucher
                      </Button>
                      {!check.voided && check.payment_method === 'check' && !check.printed_at && (
                        <Button size="sm" variant="outline" onClick={() => handleMarkPrinted(check)} disabled={busyId === check.id}>
                          <CheckCircle2 className="mr-1.5 h-3.5 w-3.5" /> Mark Printed
                        </Button>
                      )}
                      {!check.voided && !check.paid_at && (
                        <Button
                          size="sm"
                          onClick={() => {
                            setPayingCheck(check);
                            setPaymentDate(check.payment_date || localDateString());
                            setPaymentConfirmation(check.confirmation_number || '');
                          }}
                          disabled={busyId === check.id || (check.payment_method === 'check' && !check.printed_at)}
                          title={check.payment_method === 'check' && !check.printed_at ? 'Print the check first' : undefined}
                        >
                          <CheckCircle2 className="mr-1.5 h-3.5 w-3.5" /> Mark Paid
                        </Button>
                      )}
                      <Button size="sm" variant="outline" onClick={() => handleCloneCheck(check)}>
                        <Copy className="mr-1.5 h-3.5 w-3.5" /> Clone
                      </Button>
                      {!check.voided && <Button size="sm" variant="outline" onClick={() => setEditingCheck(check)}>Edit</Button>}
                      {!check.voided && voidingId !== check.id && (
                        <Button size="sm" variant="outline" className="border-red-300 text-red-600" onClick={() => setVoidingId(check.id)}>Void</Button>
                      )}
                      {voidingId === check.id && (
                        <>
                          <Input className="col-span-2 h-10 w-full sm:w-44" placeholder="Void reason" value={voidReason} onChange={e => setVoidReason(e.target.value)} />
                          <Button size="sm" variant="destructive" onClick={() => handleVoid(check)} disabled={busyId === check.id}>Confirm</Button>
                        </>
                      )}
                      {!check.printed_at && !check.paid_at && !check.voided && (
                        <Button size="sm" variant="ghost" className="text-red-500" onClick={() => handleDelete(check)} disabled={busyId === check.id}>
                          <Trash2 className="h-3.5 w-3.5" />
                        </Button>
                      )}
                    </div>
                  </div>
                  {historyIds.has(check.id) && (
                    <div className="border-t bg-neutral-50">
                      <NonEmployeeCheckHistory key={`${check.id}-${check.updated_at}`} checkId={check.id} />
                    </div>
                  )}
                </div>
              ))}
            </div>
          )}
        </Card>
      </div>

      <Dialog open={payingCheck !== null} onOpenChange={(open) => { if (!open && busyId === null) setPayingCheck(null); }}>
        {payingCheck && <DialogContent>
          <DialogHeader>
            <DialogTitle>Confirm payment was issued</DialogTitle>
            <DialogDescription>{formatCurrency(Number(payingCheck.amount))} to {payingCheck.payable_to}. This is the moment connected payroll liabilities will count as paid.</DialogDescription>
          </DialogHeader>
          <div className="mt-4 grid gap-4 sm:grid-cols-2">
            <Input label="Payment date" type="date" value={paymentDate} onChange={(event) => setPaymentDate(event.target.value)} />
            <Input label="Confirmation number" helperText={['ach', 'eftps', 'wire', 'card'].includes(payingCheck.payment_method) ? 'Required for this electronic payment.' : 'Optional reference.'} value={paymentConfirmation} onChange={(event) => setPaymentConfirmation(event.target.value)} />
          </div>
          <div className="mt-4 rounded-xl border border-warning-200 bg-warning-50 px-4 py-3 text-sm leading-5 text-warning-900">Confirm only after the check was issued or the electronic transfer succeeded. A prepared payment is not the same as a paid liability.</div>
          <DialogFooter className="mt-4"><Button type="button" variant="outline" onClick={() => setPayingCheck(null)} disabled={busyId !== null}>Cancel</Button><Button type="button" onClick={() => void handleMarkPaid()} disabled={busyId !== null || !paymentDate || (['ach', 'eftps', 'wire', 'card'].includes(payingCheck.payment_method) && !paymentConfirmation.trim())}>{busyId !== null ? 'Confirming…' : 'Confirm Paid'}</Button></DialogFooter>
        </DialogContent>}
      </Dialog>

      <NonEmployeeCheckEditModal check={editingCheck} onClose={() => setEditingCheck(null)} onSaved={(updated) => { handleSavedCheck(updated); void loadLiabilities(); }} />

      {previewUrl && previewCheck && createPortal(
        <div className="fixed inset-0 z-[9999] flex items-center justify-center bg-neutral-950/70 p-4">
          <div className="flex h-[92vh] w-[95vw] max-w-[1400px] flex-col overflow-hidden rounded-xl bg-white shadow-2xl">
            <div className="flex items-center justify-between border-b px-5 py-4">
              <div>
                <h2 className="text-lg font-semibold text-neutral-900">{previewTitle}</h2>
                <p className="text-sm text-neutral-500">{formatCurrency(Number(previewCheck.amount))} · Check #{previewCheck.check_number || '-'}</p>
              </div>
              <div className="flex gap-2">
                <Button variant="outline" onClick={handlePrintPreview} disabled={!previewLoaded}>
                  <Printer className="mr-1.5 h-4 w-4" /> {previewLoaded ? 'Print' : 'Loading...'}
                </Button>
                <Button onClick={closePreview}>Close</Button>
              </div>
            </div>
            <div className="flex-1 bg-neutral-100 p-4">
              <iframe
                ref={previewFrameRef}
                src={`${previewUrl}#toolbar=0&navpanes=0&scrollbar=1&view=Fit`}
                className="h-full w-full rounded-lg border bg-white"
                title={previewTitle}
                onLoad={() => setPreviewLoaded(true)}
              />
            </div>
          </div>
        </div>,
        document.body
      )}
    </div>
  );
}

function formatCurrency(value: number) {
  return value.toLocaleString(undefined, { style: 'currency', currency: 'USD' });
}

function formatDate(value: string) {
  const date = value.includes('T') ? new Date(value) : new Date(`${value}T00:00:00`);
  return date.toLocaleDateString();
}

function displayCheckStatus(check: NonEmployeeCheck) {
  return check.liability_payment && check.check_status === 'pending' ? 'prepared' : check.check_status;
}

function liabilityPaymentType(obligations: PayrollLiabilityCenterObligation[]): NonEmployeeCheckType {
  const authority = obligations[0]?.authority;
  if (
    authority === 'Guam Department of Revenue and Taxation'
    || authority === 'United States Treasury'
  ) return 'tax_deposit';

  const categories = obligations.flatMap((obligation) => obligation.categories.map((category) => category.category));
  if (categories.length > 0 && categories.every((category) => category === 'child_support')) return 'child_support';
  if (categories.length > 0 && categories.every((category) => category === 'garnishment')) return 'garnishment';
  return 'other';
}

function periodLabel(check: NonEmployeeCheck) {
  if (check.payment_period_type === 'month' && check.tax_year && check.tax_month) {
    return `${new Date(check.tax_year, check.tax_month - 1, 1).toLocaleString(undefined, { month: 'long' })} ${check.tax_year}`;
  }
  if (check.payment_period_type === 'quarter' && check.tax_year && check.tax_quarter) return `Q${check.tax_quarter} ${check.tax_year}`;
  if (check.payment_period_type === 'year' && check.tax_year) return String(check.tax_year);
  return PERIOD_LABELS[check.payment_period_type] || 'No tax period';
}

function csvCell(value: string | number) {
  const text = String(value);
  return `"${text.replace(/"/g, '""')}"`;
}

function FormField({
  label,
  className,
  children,
}: {
  label: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div className={className}>
      <label className="mb-1.5 block text-sm font-medium text-neutral-700">
        {label}
      </label>
      {children}
    </div>
  );
}
