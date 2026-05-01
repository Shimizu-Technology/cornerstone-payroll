import { useState, useEffect, useMemo } from 'react';
import { createPortal } from 'react-dom';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { NumericInput } from '@/components/ui/numeric-input';
import { nonEmployeeChecksApi } from '@/services/api';
import type { NonEmployeeCheck, NonEmployeeCheckType, PaymentPeriodType } from '@/types';

interface NonEmployeeCheckEditModalProps {
  check: NonEmployeeCheck | null;
  onClose: () => void;
  onSaved: (updated: NonEmployeeCheck) => void;
}

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

const PERIOD_LABELS: Record<PaymentPeriodType, string> = {
  none: 'No tax period',
  pay_period: 'Pay period',
  month: 'Monthly',
  quarter: 'Quarterly',
  year: 'Annual',
};

const currentYear = new Date().getFullYear();
const currentMonth = new Date().getMonth() + 1;
const currentQuarter = Math.floor(new Date().getMonth() / 3) + 1;

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
  reference_number: string;
  memo: string;
  description: string;
  reason: string;
}

function buildInitialState(check: NonEmployeeCheck): FormState {
  return {
    payable_to: check.payable_to,
    amount: String(check.amount),
    check_type: check.check_type,
    check_number: check.check_number || '',
    payment_period_type: check.payment_period_type,
    tax_year: check.tax_year ? String(check.tax_year) : '',
    tax_quarter: check.tax_quarter ? String(check.tax_quarter) : '',
    tax_month: check.tax_month ? String(check.tax_month) : '',
    due_date: check.due_date || '',
    payment_date: check.payment_date || '',
    confirmation_number: check.confirmation_number || '',
    reference_number: check.reference_number || '',
    memo: check.memo || '',
    description: check.description || '',
    reason: '',
  };
}

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

function handlePeriodTypeChange(
  prev: FormState,
  paymentPeriodType: PaymentPeriodType
): FormState {
  const taxYear = prev.tax_year || String(currentYear);

  switch (paymentPeriodType) {
  case 'month':
    return {
      ...prev,
      payment_period_type: paymentPeriodType,
      tax_year: taxYear,
      tax_month: prev.tax_month || String(currentMonth),
      tax_quarter: '',
    };
  case 'quarter':
    return {
      ...prev,
      payment_period_type: paymentPeriodType,
      tax_year: taxYear,
      tax_quarter: prev.tax_quarter || String(currentQuarter),
      tax_month: '',
    };
  case 'year':
    return {
      ...prev,
      payment_period_type: paymentPeriodType,
      tax_year: taxYear,
      tax_month: '',
      tax_quarter: '',
    };
  case 'none':
    return {
      ...prev,
      payment_period_type: paymentPeriodType,
      tax_year: '',
      tax_month: '',
      tax_quarter: '',
    };
  default:
    return { ...prev, payment_period_type: paymentPeriodType };
  }
}

export function NonEmployeeCheckEditModal({ check, onClose, onSaved }: NonEmployeeCheckEditModalProps) {
  const [form, setForm] = useState<FormState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  // Reset form whenever the modal is opened with a (possibly different) check.
  useEffect(() => {
    if (check) {
      setForm(buildInitialState(check));
      setError(null);
    } else {
      setForm(null);
    }
  }, [check]);

  // ESC closes the modal — matches the rest of the panel's modal behaviour.
  useEffect(() => {
    if (!check) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !saving) onClose();
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [check, saving, onClose]);

  // Track which fields have changed so we can show a clear summary of pending
  // edits and warn loudly when the amount is being changed.
  //
  // Amount needs numeric (not string) comparison: the API returns amounts like
  // "125.5" while a user editing the field may save "125.50" — these are the
  // same value and shouldn't register as a change.
  const changedSummary = useMemo(() => {
    if (!check || !form) return { fields: [] as string[], amountChanged: false };
    const before = buildInitialState(check);
    const fields: string[] = [];
    (Object.keys(before) as (keyof FormState)[]).forEach(key => {
      if (key === 'reason') return;
      if (key === 'amount') {
        const beforeNum = parseFloat(before.amount);
        const afterNum = parseFloat(form.amount);
        const beforeValid = Number.isFinite(beforeNum);
        const afterValid = Number.isFinite(afterNum);
        // Treat unparseable values as a change so we still surface the issue.
        if (!beforeValid || !afterValid) {
          if ((form.amount || '') !== (before.amount || '')) fields.push('amount');
        } else if (Math.abs(beforeNum - afterNum) > 0.005) {
          fields.push('amount');
        }
        return;
      }
      if ((form[key] || '') !== (before[key] || '')) fields.push(key);
    });
    return { fields, amountChanged: fields.includes('amount') };
  }, [check, form]);

  if (!check || !form) return null;

  const isPrinted = !!check.printed_at;
  const isFitDeposit = check.auto_generated_type === 'fit_deposit';
  const dirty = changedSummary.fields.length > 0;

  const handleSave = async () => {
    if (!dirty) {
      onClose();
      return;
    }

    // Confirm amount changes for FIT auto-deposits — overrides the
    // calculated total that flows from the underlying PayrollItems.
    if (changedSummary.amountChanged && isFitDeposit) {
      const ok = window.confirm(
        'You are changing the amount of the auto-generated FIT deposit. The new amount ' +
        'will not be recalculated from payroll if you re-run the FIT generator. Continue?'
      );
      if (!ok) return;
    }

    if (isPrinted) {
      const ok = window.confirm(
        'This check has already been marked printed. Editing it will not reprint or void ' +
        'the existing physical check — you may want to void and reissue instead. Continue?'
      );
      if (!ok) return;
    }

    setError(null);
    setSaving(true);

    try {
      const amountNum = parseFloat(form.amount);
      if (Number.isNaN(amountNum) || amountNum <= 0) {
        throw new Error('Amount must be a positive number');
      }

      // Coerce blank check_number to null. Postgres treats "" as NOT NULL,
      // so the partial unique index on (company_id, check_number) would
      // fire on the second blank check in the same company saved through
      // this modal. The backend coerces too, but normalising here also
      // keeps audit-log diffs clean ("" → null no-ops, not "no-op edits").
      const checkNumberValue = form.check_number.trim() === '' ? null : form.check_number;

      const payload: Parameters<typeof nonEmployeeChecksApi.update>[1] = {
        payable_to: form.payable_to,
        amount: amountNum,
        check_type: form.check_type,
        check_number: checkNumberValue,
        ...(check.pay_period_id ? {} : periodPayload(form)),
        due_date: check.pay_period_id ? undefined : form.due_date || null,
        payment_date: check.pay_period_id ? undefined : form.payment_date || null,
        confirmation_number: check.pay_period_id ? undefined : form.confirmation_number.trim() || null,
        reference_number: form.reference_number,
        memo: form.memo,
        description: form.description,
      };

      const res = await nonEmployeeChecksApi.update(check.id, payload, form.reason || undefined);
      onSaved(res.non_employee_check);
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save check');
    } finally {
      setSaving(false);
    }
  };

  return createPortal(
    <div className="fixed inset-0 z-[9999] flex items-center justify-center bg-gray-900/70 p-4">
      <div className="flex max-h-[92vh] w-full max-w-2xl flex-col overflow-hidden rounded-2xl bg-white shadow-2xl">
        <div className="flex items-start justify-between border-b px-6 py-4">
          <div>
            <h2 className="text-lg font-semibold text-gray-900">Edit Check</h2>
            <p className="mt-1 text-sm text-gray-500">
              {check.payable_to}
              {check.check_number && ` · #${check.check_number}`}
            </p>
            <div className="mt-2 flex flex-wrap items-center gap-2">
              {isFitDeposit && (
                <Badge className="bg-amber-100 text-amber-800">Auto-generated FIT</Badge>
              )}
              {isPrinted && (
                <Badge className="bg-green-100 text-green-800">
                  Printed {new Date(check.printed_at!).toLocaleDateString()}
                </Badge>
              )}
            </div>
          </div>
          <button
            onClick={onClose}
            disabled={saving}
            className="rounded-md p-1 text-gray-400 hover:bg-gray-100 hover:text-gray-600"
            aria-label="Close"
          >
            <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          {isPrinted && (
            <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
              This check has been printed. Edits update the record and downstream reports
              but do <strong>not</strong> affect the physical check that already went out.
              For amount or payee corrections that require a new physical check, void this
              one and create a replacement.
            </div>
          )}

          {error && (
            <div className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">
              {error}
            </div>
          )}

          <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            <Field label="Payable To" required>
              <input
                className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                placeholder="e.g., Treasurer of Guam"
                value={form.payable_to}
                onChange={e => setForm(p => p && { ...p, payable_to: e.target.value })}
              />
            </Field>

            <Field label="Amount" required>
              <NumericInput
                min={0.01}
                fixedDecimalsOnBlur={2}
                inputMode="decimal"
                placeholder="e.g., 256.78"
                className="w-full px-3 py-2 text-sm"
                value={form.amount === '' ? null : Number(form.amount)}
                onValueChange={(value) =>
                  setForm(p => (p ? { ...p, amount: value == null ? '' : String(value) } : p))
                }
              />
            </Field>

            <Field label="Check Type">
              <select
                className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                value={form.check_type}
                onChange={e => setForm(p => p && { ...p, check_type: e.target.value as NonEmployeeCheckType })}
              >
                {Object.entries(CHECK_TYPE_LABELS).map(([val, label]) => (
                  <option key={val} value={val}>{label}</option>
                ))}
              </select>
            </Field>

            <Field label="Check Number">
              <input
                className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                placeholder="e.g., 1234"
                value={form.check_number}
                onChange={e => setForm(p => p && { ...p, check_number: e.target.value })}
              />
            </Field>

            {!check.pay_period_id && (
              <>
                <Field label="Tax/reporting period">
                  <select
                    className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                    value={form.payment_period_type}
                    onChange={e => setForm(p => p && handlePeriodTypeChange(p, e.target.value as PaymentPeriodType))}
                  >
                    {(['none', 'month', 'quarter', 'year'] as PaymentPeriodType[]).map(type => (
                      <option key={type} value={type}>{PERIOD_LABELS[type]}</option>
                    ))}
                  </select>
                </Field>

                {form.payment_period_type !== 'none' && (
                  <Field label="Tax year">
                    <input
                      className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                      inputMode="numeric"
                      placeholder="e.g., 2026"
                      value={form.tax_year}
                      onChange={e => setForm(p => p && { ...p, tax_year: e.target.value })}
                    />
                  </Field>
                )}

                {form.payment_period_type === 'quarter' && (
                  <Field label="Tax quarter">
                    <select
                      className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                      value={form.tax_quarter}
                      onChange={e => setForm(p => p && { ...p, tax_quarter: e.target.value })}
                    >
                      <option value="" disabled>Select quarter</option>
                      {[1, 2, 3, 4].map(q => <option key={q} value={q}>Q{q}</option>)}
                    </select>
                  </Field>
                )}

                {form.payment_period_type === 'month' && (
                  <Field label="Tax month">
                    <select
                      className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                      value={form.tax_month}
                      onChange={e => setForm(p => p && { ...p, tax_month: e.target.value })}
                    >
                      <option value="" disabled>Select month</option>
                      {Array.from({ length: 12 }, (_, i) => i + 1).map(month => (
                        <option key={month} value={month}>
                          {new Date(2026, month - 1, 1).toLocaleString(undefined, { month: 'long' })}
                        </option>
                      ))}
                    </select>
                  </Field>
                )}

                <Field label="Payment date" hint="Date the check/payment is issued.">
                  <input
                    className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                    type="date"
                    value={form.payment_date}
                    onChange={e => setForm(p => p && { ...p, payment_date: e.target.value })}
                  />
                </Field>

                <Field label="Due date" hint="Deadline for the tax bill or obligation.">
                  <input
                    className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                    type="date"
                    value={form.due_date}
                    onChange={e => setForm(p => p && { ...p, due_date: e.target.value })}
                  />
                </Field>

                <Field label="Confirmation Number">
                  <input
                    className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                    placeholder="e.g., GRT-2026-05"
                    value={form.confirmation_number}
                    onChange={e => setForm(p => p && { ...p, confirmation_number: e.target.value })}
                  />
                </Field>
              </>
            )}

            <Field label="Memo" className="md:col-span-2">
              <input
                className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                placeholder="e.g., May GRT payment"
                value={form.memo}
                onChange={e => setForm(p => p && { ...p, memo: e.target.value })}
              />
            </Field>

            <Field label="Reference #" className="md:col-span-2">
              <input
                className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                placeholder="e.g., invoice or tax voucher #"
                value={form.reference_number}
                onChange={e => setForm(p => p && { ...p, reference_number: e.target.value })}
              />
            </Field>

            <Field label="Description" className="md:col-span-2">
              <textarea
                rows={2}
                className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                placeholder="e.g., Notes about what this payment covers or how it was calculated"
                value={form.description}
                onChange={e => setForm(p => p && { ...p, description: e.target.value })}
              />
            </Field>

            <Field
              label="Reason for change (optional)"
              hint="Recorded in the audit history. Leave blank for routine fixes; fill in for anything you want documented."
              className="md:col-span-2"
            >
              <input
                className="w-full rounded-xl border border-neutral-300 px-3.5 py-2.5 text-sm shadow-sm focus-visible:border-primary-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"
                placeholder="e.g. Updated check number after re-run"
                value={form.reason}
                onChange={e => setForm(p => p && { ...p, reason: e.target.value })}
              />
            </Field>
          </div>

          {dirty && (
            <div className="rounded-lg border border-blue-200 bg-blue-50 p-3 text-sm">
              <p className="font-medium text-blue-900">
                Pending changes ({changedSummary.fields.length})
              </p>
              <p className="mt-1 text-blue-800">
                {changedSummary.fields.map(f => fieldLabel(f)).join(', ')}
              </p>
              {changedSummary.amountChanged && (
                <p className="mt-2 text-amber-800">
                  ⚠ Amount change will flow into transmittal totals and any other report that
                  pulls from this check.
                </p>
              )}
            </div>
          )}
        </div>

        <div className="flex items-center justify-between border-t bg-gray-50 px-6 py-3">
          <p className="text-xs text-gray-500">
            All edits are logged with your name and timestamp.
          </p>
          <div className="flex gap-2">
            <Button variant="outline" size="sm" onClick={onClose} disabled={saving}>
              Cancel
            </Button>
            <Button size="sm" onClick={handleSave} disabled={saving || !dirty}>
              {saving ? 'Saving…' : 'Save Changes'}
            </Button>
          </div>
        </div>
      </div>
    </div>,
    document.body
  );
}

function Field({
  label,
  required,
  hint,
  className,
  children,
}: {
  label: string;
  required?: boolean;
  hint?: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div className={className}>
      <label className="block text-xs font-medium text-gray-700 mb-1">
        {label}
        {required && <span className="text-red-500 ml-0.5">*</span>}
      </label>
      {children}
      {hint && <p className="mt-1 text-xs text-gray-500">{hint}</p>}
    </div>
  );
}

function fieldLabel(field: string): string {
  const map: Record<string, string> = {
    payable_to: 'Payable To',
    amount: 'Amount',
    check_type: 'Check Type',
    check_number: 'Check Number',
    payment_period_type: 'Tax/reporting Period',
    tax_year: 'Tax Year',
    tax_quarter: 'Tax Quarter',
    tax_month: 'Tax Month',
    due_date: 'Due Date',
    payment_date: 'Payment Date',
    confirmation_number: 'Confirmation Number',
    reference_number: 'Reference #',
    memo: 'Memo',
    description: 'Description',
  };
  return map[field] || field;
}
