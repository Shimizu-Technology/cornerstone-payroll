import { useCallback, useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import { Link } from 'react-router-dom';
import { CheckCircle2, FileText, Printer, Search, Settings, Trash2 } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { NumericInput } from '@/components/ui/numeric-input';
import { nonEmployeeChecksApi, companiesApi, type CompanyDetail } from '@/services/api';
import { useCompany } from '@/contexts/CompanyContext';
import type { NonEmployeeCheck, NonEmployeeCheckType, PaymentPeriodType } from '@/types';
import { NonEmployeeCheckEditModal } from '@/components/checks/NonEmployeeCheckEditModal';
import { NonEmployeeCheckHistory } from '@/components/checks/NonEmployeeCheckHistory';

const CHECK_TYPE_LABELS: Record<NonEmployeeCheckType, string> = {
  contractor: 'Contractor',
  tax_deposit: 'Tax Deposit',
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
  'grt',
  'estimated_tax',
  'w1_balance',
  'swica',
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
  unprinted: 'bg-yellow-100 text-yellow-700',
  printed: 'bg-green-100 text-green-700',
  voided: 'bg-red-100 text-red-700',
};

interface FormState {
  payable_to: string;
  amount: string;
  check_type: NonEmployeeCheckType;
  check_number: string;
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
}

const initialForm: FormState = {
  payable_to: '',
  amount: '',
  check_type: 'grt',
  check_number: '',
  payment_period_type: 'month',
  tax_year: String(new Date().getFullYear()),
  tax_quarter: String(Math.floor(new Date().getMonth() / 3) + 1),
  tax_month: String(new Date().getMonth() + 1),
  due_date: '',
  payment_date: new Date().toISOString().slice(0, 10),
  confirmation_number: '',
  memo: '',
  reference_number: '',
  description: '',
};

const fieldClassName = 'rounded-xl';

function periodPayload(form: Pick<FormState, 'payment_period_type' | 'tax_year' | 'tax_quarter' | 'tax_month'>) {
  return {
    payment_period_type: form.payment_period_type,
    tax_year: form.payment_period_type === 'none' ? null : form.tax_year ? Number(form.tax_year) : null,
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
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [creating, setCreating] = useState(false);
  const [form, setForm] = useState<FormState>(initialForm);
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
  const [startingSlot, setStartingSlot] = useState(1);

  const loadChecks = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await nonEmployeeChecksApi.list({
        standalone: 'true',
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

  useEffect(() => {
    loadChecks();
  }, [loadChecks]);

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
      payable_to: form.payable_to.trim(),
      amount: Number(form.amount),
      check_type: form.check_type,
      check_number: form.check_number.trim() || undefined,
      ...periodPayload(form),
      due_date: form.due_date || null,
      payment_date: form.payment_date || null,
      confirmation_number: form.confirmation_number.trim() || null,
      memo: form.memo.trim() || undefined,
      reference_number: form.reference_number.trim() || undefined,
      description: form.description.trim() || undefined,
    };

    setCreating(true);
    try {
      await nonEmployeeChecksApi.create(payload);
      setShowForm(false);
      setForm(initialForm);
      await loadChecks();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create check');
    } finally {
      setCreating(false);
    }
  };

  const handleSavedCheck = (updated: NonEmployeeCheck) => {
    setChecks(prev => prev.map(check => (check.id === updated.id ? updated : check)));
    setPreviewCheck(prev => (prev?.id === updated.id ? updated : prev));
  };

  const handleMarkPrinted = async (check: NonEmployeeCheck) => {
    setBusyId(check.id);
    try {
      const response = await nonEmployeeChecksApi.markPrinted(check.id);
      handleSavedCheck(response.non_employee_check);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to mark printed');
    } finally {
      setBusyId(null);
    }
  };

  const handleVoid = async (check: NonEmployeeCheck) => {
    if (!voidReason.trim()) return;
    setBusyId(check.id);
    try {
      const response = await nonEmployeeChecksApi.voidCheck(check.id, voidReason.trim());
      handleSavedCheck(response.non_employee_check);
      setVoidingId(null);
      setVoidReason('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to void check');
    } finally {
      setBusyId(null);
    }
  };

  const handleDelete = async (check: NonEmployeeCheck) => {
    if (!window.confirm(`Delete ${check.payable_to}'s check?`)) return;
    setBusyId(check.id);
    try {
      await nonEmployeeChecksApi.delete(check.id);
      setChecks(prev => prev.filter(c => c.id !== check.id));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete check');
    } finally {
      setBusyId(null);
    }
  };

  const handlePreview = async (check: NonEmployeeCheck) => {
    setBusyId(check.id);
    try {
      const blob = await nonEmployeeChecksApi.checkPdf(
        check.id,
        company?.check_stock_type === 'first_hawaiian_4up' ? { startingSlot } : undefined
      );
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      setPreviewUrl(URL.createObjectURL(blob));
      setPreviewCheck(check);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to generate check PDF');
    } finally {
      setBusyId(null);
    }
  };

  const closePreview = () => {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    setPreviewUrl(null);
    setPreviewCheck(null);
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
        description="Standalone company checks for GRT, quarterly payments, vendors, reimbursements, and other non-pay-period disbursements."
        actions={
          <Button onClick={() => setShowForm(prev => !prev)}>
            {showForm ? 'Cancel' : 'New Check'}
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
            <div className="grid grid-cols-1 gap-4 md:grid-cols-4">
              <Input
                label="Payable to"
                value={form.payable_to}
                onChange={e => setForm(p => ({ ...p, payable_to: e.target.value }))}
              />
              <FormField label="Amount">
                <NumericInput
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
              <Input
                label="Check number"
                helperText="Optional until printed."
                value={form.check_number}
                onChange={e => setForm(p => ({ ...p, check_number: e.target.value }))}
              />
              <Select
                label="Tax/reporting period"
                value={form.payment_period_type}
                onChange={e => setForm(p => ({ ...p, payment_period_type: e.target.value as PaymentPeriodType }))}
              >
                {(['none', 'month', 'quarter', 'year'] as PaymentPeriodType[]).map(type => <option key={type} value={type}>{PERIOD_LABELS[type]}</option>)}
              </Select>
              {form.payment_period_type !== 'none' && (
                <Input
                  label="Tax year"
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
                helperText="Date the check/payment is issued."
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
                value={form.confirmation_number}
                onChange={e => setForm(p => ({ ...p, confirmation_number: e.target.value }))}
              />
              <Input
                label="Reference number"
                value={form.reference_number}
                onChange={e => setForm(p => ({ ...p, reference_number: e.target.value }))}
              />
              <Input
                label="Memo"
                value={form.memo}
                onChange={e => setForm(p => ({ ...p, memo: e.target.value }))}
              />
            </div>
            <FormField label="Description" className="mt-4">
              <textarea
                className={`${fieldClassName} min-h-[88px] w-full border border-neutral-300 bg-white px-3.5 py-2.5 text-sm text-neutral-900 shadow-sm transition-all duration-200 placeholder:text-neutral-400 focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200`}
                rows={2}
                value={form.description}
                onChange={e => setForm(p => ({ ...p, description: e.target.value }))}
              />
            </FormField>
            <div className="mt-4 rounded-xl border border-blue-100 bg-blue-50 px-4 py-3 text-sm text-blue-900">
              Checks & Payments uses the same stock type and X/Y alignment as payroll checks.
              <Link to="/check-settings" className="ml-1 font-medium text-blue-700 underline underline-offset-2">
                Open Check Settings
              </Link>
            </div>
            <div className="mt-4 flex gap-2">
              <Button onClick={handleCreate} disabled={creating}>{creating ? 'Creating...' : 'Create Check'}</Button>
              <Button variant="outline" onClick={() => setShowForm(false)} disabled={creating}>Cancel</Button>
            </div>
          </Card>
        )}

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
            <div className="flex flex-wrap gap-2">
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
            </div>
          </div>
        </Card>

        <Card className="overflow-hidden">
          <div className="border-b bg-white px-4 py-3 text-sm text-neutral-600">
            {totals.count} active check{totals.count === 1 ? '' : 's'} · {formatCurrency(totals.amount)}
          </div>
          {loading ? (
            <div className="p-6 text-sm text-neutral-500">Loading checks...</div>
          ) : visibleChecks.length === 0 ? (
            <div className="p-6 text-sm text-neutral-500">No standalone checks found.</div>
          ) : (
            <div className="divide-y">
              {visibleChecks.map(check => (
                <div key={check.id} className={check.voided ? 'bg-red-50' : 'bg-white'}>
                  <div className="flex flex-col gap-3 p-4 xl:flex-row xl:items-center xl:justify-between">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="font-medium text-neutral-900">{check.payable_to}</span>
                        <Badge className={STATUS_COLORS[check.check_status] || 'bg-gray-100 text-gray-700'}>{check.check_status}</Badge>
                        <Badge variant="outline">{CHECK_TYPE_LABELS[check.check_type]}</Badge>
                        {check.edit_count ? (
                          <button className="text-xs font-medium text-blue-700" onClick={() => toggleHistory(check.id)}>
                            {check.edit_count} edit{check.edit_count === 1 ? '' : 's'}
                          </button>
                        ) : null}
                      </div>
                      <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-neutral-500">
                        <span className="font-semibold text-neutral-900">{formatCurrency(Number(check.amount))}</span>
                        <span>Check #{check.check_number || '-'}</span>
                        <span>{periodLabel(check)}</span>
                        {check.payment_date && <span>Payment {formatDate(check.payment_date)}</span>}
                        {check.due_date && <span>Due {formatDate(check.due_date)}</span>}
                        {check.confirmation_number && <span>Confirmation {check.confirmation_number}</span>}
                      </div>
                      {(check.memo || check.description) && (
                        <p className="mt-1 max-w-3xl truncate text-sm text-neutral-600">{check.memo || check.description}</p>
                      )}
                    </div>
                    <div className="flex flex-wrap gap-2">
                      <Button size="sm" variant="outline" onClick={() => handlePreview(check)} disabled={busyId === check.id}>
                        <FileText className="mr-1.5 h-3.5 w-3.5" /> Preview
                      </Button>
                      {!check.voided && !check.printed_at && (
                        <Button size="sm" variant="outline" onClick={() => handleMarkPrinted(check)} disabled={busyId === check.id}>
                          <CheckCircle2 className="mr-1.5 h-3.5 w-3.5" /> Mark Printed
                        </Button>
                      )}
                      {!check.voided && <Button size="sm" variant="outline" onClick={() => setEditingCheck(check)}>Edit</Button>}
                      {!check.voided && voidingId !== check.id && (
                        <Button size="sm" variant="outline" className="border-red-300 text-red-600" onClick={() => setVoidingId(check.id)}>Void</Button>
                      )}
                      {voidingId === check.id && (
                        <>
                          <Input className="h-9 w-44" placeholder="Void reason" value={voidReason} onChange={e => setVoidReason(e.target.value)} />
                          <Button size="sm" variant="destructive" onClick={() => handleVoid(check)} disabled={busyId === check.id}>Confirm</Button>
                        </>
                      )}
                      {!check.printed_at && !check.voided && (
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

      <NonEmployeeCheckEditModal check={editingCheck} onClose={() => setEditingCheck(null)} onSaved={handleSavedCheck} />

      {previewUrl && previewCheck && createPortal(
        <div className="fixed inset-0 z-[9999] flex items-center justify-center bg-neutral-950/70 p-4">
          <div className="flex h-[92vh] w-[95vw] max-w-[1400px] flex-col overflow-hidden rounded-xl bg-white shadow-2xl">
            <div className="flex items-center justify-between border-b px-5 py-4">
              <div>
                <h2 className="text-lg font-semibold text-neutral-900">{previewCheck.payable_to}</h2>
                <p className="text-sm text-neutral-500">{formatCurrency(Number(previewCheck.amount))} · Check #{previewCheck.check_number || '-'}</p>
              </div>
              <div className="flex gap-2">
                <Button variant="outline" onClick={() => window.open(previewUrl)?.print()}>
                  <Printer className="mr-1.5 h-4 w-4" /> Print
                </Button>
                <Button onClick={closePreview}>Close</Button>
              </div>
            </div>
            <div className="flex-1 bg-neutral-100 p-4">
              <iframe src={`${previewUrl}#toolbar=0&navpanes=0&scrollbar=1&view=Fit`} className="h-full w-full rounded-lg border bg-white" title="Check preview" />
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
  return new Date(`${value}T00:00:00`).toLocaleDateString();
}

function periodLabel(check: NonEmployeeCheck) {
  if (check.payment_period_type === 'month' && check.tax_year && check.tax_month) {
    return `${new Date(check.tax_year, check.tax_month - 1, 1).toLocaleString(undefined, { month: 'long' })} ${check.tax_year}`;
  }
  if (check.payment_period_type === 'quarter' && check.tax_year && check.tax_quarter) return `Q${check.tax_quarter} ${check.tax_year}`;
  if (check.payment_period_type === 'year' && check.tax_year) return String(check.tax_year);
  return PERIOD_LABELS[check.payment_period_type] || 'No tax period';
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
