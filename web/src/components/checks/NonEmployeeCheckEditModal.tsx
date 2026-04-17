import { useState, useEffect, useMemo } from 'react';
import { createPortal } from 'react-dom';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { nonEmployeeChecksApi } from '@/services/api';
import type { NonEmployeeCheck, NonEmployeeCheckType } from '@/types';

interface NonEmployeeCheckEditModalProps {
  check: NonEmployeeCheck | null;
  onClose: () => void;
  onSaved: (updated: NonEmployeeCheck) => void;
}

const CHECK_TYPE_LABELS: Record<NonEmployeeCheckType, string> = {
  contractor: 'Contractor',
  tax_deposit: 'Tax Deposit',
  child_support: 'Child Support',
  garnishment: 'Garnishment',
  vendor: 'Vendor',
  reimbursement: 'Reimbursement',
  other: 'Other',
};

interface FormState {
  payable_to: string;
  amount: string;
  check_type: NonEmployeeCheckType;
  check_number: string;
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
    reference_number: check.reference_number || '',
    memo: check.memo || '',
    description: check.description || '',
    reason: '',
  };
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
                className="w-full rounded border px-3 py-2 text-sm"
                value={form.payable_to}
                onChange={e => setForm(p => p && { ...p, payable_to: e.target.value })}
              />
            </Field>

            <Field label="Amount" required>
              <input
                type="number"
                step="0.01"
                min="0.01"
                className="w-full rounded border px-3 py-2 text-sm"
                value={form.amount}
                onChange={e => setForm(p => p && { ...p, amount: e.target.value })}
              />
            </Field>

            <Field label="Check Type">
              <select
                className="w-full rounded border px-3 py-2 text-sm"
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
                className="w-full rounded border px-3 py-2 text-sm"
                value={form.check_number}
                onChange={e => setForm(p => p && { ...p, check_number: e.target.value })}
              />
            </Field>

            <Field label="Memo" className="md:col-span-2">
              <input
                className="w-full rounded border px-3 py-2 text-sm"
                value={form.memo}
                onChange={e => setForm(p => p && { ...p, memo: e.target.value })}
              />
            </Field>

            <Field label="Reference #" className="md:col-span-2">
              <input
                className="w-full rounded border px-3 py-2 text-sm"
                value={form.reference_number}
                onChange={e => setForm(p => p && { ...p, reference_number: e.target.value })}
              />
            </Field>

            <Field label="Description" className="md:col-span-2">
              <textarea
                rows={2}
                className="w-full rounded border px-3 py-2 text-sm"
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
                className="w-full rounded border px-3 py-2 text-sm"
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
    reference_number: 'Reference #',
    memo: 'Memo',
    description: 'Description',
  };
  return map[field] || field;
}
