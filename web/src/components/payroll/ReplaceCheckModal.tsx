import { useState, useEffect, useMemo, useCallback } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { checksApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import type {
  PayPeriod,
  PayrollItem,
  PayrollItemWageRateHours,
  ReplaceCheckPreview,
  ReplaceCheckResult,
} from '@/types';

// ---------------------------------------------------------------------------
// ReplaceCheckModal
//
// Used when an employee's check is *not in the wild* (never given out, or
// returned uncashed) and the financial values need to change. Unlike
// CorrectivePaycheckModal — which leaves the original alone and cuts a
// separate supplemental delta check — this modal voids the original check
// in place and produces ONE corrected replacement check.
//
// Mode auto-detection:
//   - Unprinted item -> in_place: same check #, just update financials.
//   - Printed item   -> void_and_reissue: old # is voided, a new # is
//     assigned, and the new check becomes the canonical one.
// ---------------------------------------------------------------------------

interface ReplaceCheckModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  payPeriod: PayPeriod;
  payrollItem: PayrollItem;
  onReplaced: (result: ReplaceCheckResult) => void;
}

interface FormState {
  hours_worked: string;
  overtime_hours: string;
  holiday_hours: string;
  pto_hours: string;
  pay_rate: string;
  bonus: string;
  reported_tips: string;
  reason: string;
  // Per-bucket hours for multi-rate employees. Empty array for single-rate.
  // Each bucket carries its label + rate (immutable in this UI) plus the
  // four hour columns the operator can edit.
  wage_rate_hours: WageRateRowForm[];
}

interface WageRateRowForm {
  employee_wage_rate_id?: number;
  label: string;
  rate: number;
  is_primary?: boolean;
  active?: boolean;
  regular_hours: string;
  overtime_hours: string;
  holiday_hours: string;
  pto_hours: string;
}

const MIN_REASON_LENGTH = 10;

function toStr(value: number | null | undefined): string {
  if (value === null || value === undefined || Number.isNaN(value)) return '';
  return String(value);
}

function num(value: string): number {
  const parsed = parseFloat(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function isMultiRateItem(item: PayrollItem): boolean {
  // We treat any item with at least one active wage_rate_hours entry as
  // multi-rate. The calculator only takes the bucket path when the array
  // is present, so this matches the backend's branching.
  const entries = (item.wage_rate_hours ?? []).filter((e) => e.active !== false);
  return entries.length > 0;
}

function bucketsToForm(entries: PayrollItemWageRateHours[] | undefined): WageRateRowForm[] {
  return (entries ?? [])
    .filter((e) => e.active !== false)
    .map((e) => ({
      employee_wage_rate_id: e.employee_wage_rate_id,
      label: e.label,
      rate: e.rate,
      is_primary: e.is_primary,
      active: e.active,
      regular_hours: toStr(e.regular_hours),
      overtime_hours: toStr(e.overtime_hours),
      holiday_hours: toStr(e.holiday_hours),
      pto_hours: toStr(e.pto_hours),
    }));
}

function bucketsToPayload(rows: WageRateRowForm[]): PayrollItemWageRateHours[] {
  return rows.map((row) => ({
    employee_wage_rate_id: row.employee_wage_rate_id,
    label: row.label,
    rate: row.rate,
    is_primary: row.is_primary,
    active: row.active ?? true,
    regular_hours: num(row.regular_hours),
    overtime_hours: num(row.overtime_hours),
    holiday_hours: num(row.holiday_hours),
    pto_hours: num(row.pto_hours),
  }));
}

function bucketGross(rows: WageRateRowForm[]): number {
  return rows.reduce((sum, row) => {
    const reg = num(row.regular_hours) * row.rate;
    const ot = num(row.overtime_hours) * row.rate * 1.5;
    const hol = num(row.holiday_hours) * row.rate;
    const pto = num(row.pto_hours) * row.rate;
    return sum + reg + ot + hol + pto;
  }, 0);
}

export function ReplaceCheckModal({
  open,
  onOpenChange,
  payPeriod,
  payrollItem,
  onReplaced,
}: ReplaceCheckModalProps) {
  const isMultiRate = useMemo(() => isMultiRateItem(payrollItem), [payrollItem]);

  const [form, setForm] = useState<FormState>(() => initialForm(payrollItem));
  const [preview, setPreview] = useState<ReplaceCheckPreview | null>(null);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  // Reset on open / item change so previous submissions don't leak in.
  useEffect(() => {
    if (!open) return;
    setForm(initialForm(payrollItem));
    setPreview(null);
    setPreviewError(null);
    setSubmitError(null);
  }, [open, payrollItem.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const correctedInputs = useMemo(() => {
    // For multi-rate items the calculator overwrites the aggregate scalar
    // hour fields from the wage_rate_hours sums — so sending those scalars
    // would be silently ignored. Instead, send the per-bucket payload (and
    // omit pay_rate, which is per-bucket too). Bonus/tips remain useful for
    // both modes.
    if (isMultiRate) {
      return {
        wage_rate_hours: bucketsToPayload(form.wage_rate_hours),
        bonus: num(form.bonus),
        reported_tips: num(form.reported_tips),
      };
    }
    return {
      hours_worked: num(form.hours_worked),
      overtime_hours: num(form.overtime_hours),
      holiday_hours: num(form.holiday_hours),
      pto_hours: num(form.pto_hours),
      pay_rate: num(form.pay_rate),
      bonus: num(form.bonus),
      reported_tips: num(form.reported_tips),
    };
  }, [
    isMultiRate,
    form.wage_rate_hours,
    form.hours_worked,
    form.overtime_hours,
    form.holiday_hours,
    form.pto_hours,
    form.pay_rate,
    form.bonus,
    form.reported_tips,
  ]);

  const inputsChanged = useMemo(() => {
    const o = payrollItem;
    if (isMultiRate) {
      const original = bucketsToForm(o.wage_rate_hours);
      // Length mismatch (e.g., a hidden inactive bucket) implies a change.
      if (form.wage_rate_hours.length !== original.length) return true;
      const bucketDiff = form.wage_rate_hours.some((row, i) => {
        const orig = original[i];
        if (!orig) return true;
        return (
          Math.abs(num(row.regular_hours) - num(orig.regular_hours)) > 0.001 ||
          Math.abs(num(row.overtime_hours) - num(orig.overtime_hours)) > 0.001 ||
          Math.abs(num(row.holiday_hours) - num(orig.holiday_hours)) > 0.001 ||
          Math.abs(num(row.pto_hours) - num(orig.pto_hours)) > 0.001
        );
      });
      return (
        bucketDiff ||
        Math.abs(num(form.bonus) - (o.bonus ?? 0)) > 0.005 ||
        Math.abs(num(form.reported_tips) - (o.reported_tips ?? 0)) > 0.005
      );
    }
    return (
      Math.abs(num(form.hours_worked) - (o.hours_worked ?? 0)) > 0.001 ||
      Math.abs(num(form.overtime_hours) - (o.overtime_hours ?? 0)) > 0.001 ||
      Math.abs(num(form.holiday_hours) - (o.holiday_hours ?? 0)) > 0.001 ||
      Math.abs(num(form.pto_hours) - (o.pto_hours ?? 0)) > 0.001 ||
      Math.abs(num(form.pay_rate) - (o.pay_rate ?? 0)) > 0.005 ||
      Math.abs(num(form.bonus) - (o.bonus ?? 0)) > 0.005 ||
      Math.abs(num(form.reported_tips) - (o.reported_tips ?? 0)) > 0.005
    );
  }, [form, payrollItem, isMultiRate]);

  // Debounced preview fetch — same pattern as CorrectivePaycheckModal so the
  // UI doesn't fire on every keystroke.
  const fetchPreview = useCallback(async () => {
    if (!inputsChanged) {
      setPreview(null);
      setPreviewError(null);
      return;
    }
    setPreviewLoading(true);
    setPreviewError(null);
    try {
      const result = await checksApi.replaceCheckPreview(payrollItem.id, {
        corrected_inputs: correctedInputs,
      });
      setPreview(result);
    } catch (err) {
      setPreviewError(err instanceof Error ? err.message : 'Preview failed');
      setPreview(null);
    } finally {
      setPreviewLoading(false);
    }
  }, [inputsChanged, payrollItem.id, correctedInputs]);

  useEffect(() => {
    if (!open) return;
    const handle = setTimeout(fetchPreview, 350);
    return () => clearTimeout(handle);
  }, [open, fetchPreview]);

  const reasonValid = form.reason.trim().length >= MIN_REASON_LENGTH;
  // For single-rate, the gating used to ensure pay_rate stayed non-negative.
  // For multi-rate the rate is per-bucket and immutable in this UI, so the
  // analogous guard is "no bucket has a negative hour entry."
  const numericValid = isMultiRate
    ? form.wage_rate_hours.every(
        (row) =>
          num(row.regular_hours) >= 0 &&
          num(row.overtime_hours) >= 0 &&
          num(row.holiday_hours) >= 0 &&
          num(row.pto_hours) >= 0,
      )
    : num(form.pay_rate) >= 0;
  const canSubmit =
    inputsChanged &&
    !!preview &&
    !preview.meta.is_zero_change &&
    reasonValid &&
    !submitting &&
    numericValid;

  const handleSubmit = async () => {
    setSubmitting(true);
    setSubmitError(null);
    try {
      const result = await checksApi.replaceCheck(payrollItem.id, {
        corrected_inputs: correctedInputs,
        reason: form.reason.trim(),
      });
      onReplaced(result);
      onOpenChange(false);
    } catch (err) {
      setSubmitError(err instanceof Error ? err.message : 'Failed to replace check');
    } finally {
      setSubmitting(false);
    }
  };

  const original = preview?.original;
  const corrected = preview?.corrected;
  const mode = preview?.mode;
  const employeeName = payrollItem.employee_name ?? 'this employee';

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-3xl">
        <DialogHeader>
          <DialogTitle>Replace check (uncashed)</DialogTitle>
          <DialogDescription>
            Replace <strong>{employeeName}</strong>'s check on the committed
            period{' '}
            <strong>
              {payPeriod.period_description ?? `${payPeriod.start_date} – ${payPeriod.end_date}`}
            </strong>
            . Use this when the original check is in your possession (never
            distributed, or returned uncashed). The original check number is
            voided and a single corrected replacement is issued. YTDs and
            reports update atomically.
          </DialogDescription>
        </DialogHeader>

        <ModeBanner mode={mode} originalCheckNumber={payrollItem.check_number} payrollItem={payrollItem} />

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
          {/* Inputs */}
          <div className="space-y-3">
            <h3 className="text-sm font-semibold text-gray-900">Corrected values</h3>
            {isMultiRate ? (
              <p className="text-xs text-gray-500">
                This employee is paid at multiple rates. Enter the correct
                hours for each rate bucket — gross is recomputed from these
                buckets, then taxes are recomputed from the corrected gross.
              </p>
            ) : (
              <p className="text-xs text-gray-500">
                Enter what the values should be on the replacement check. Pay
                rate is editable in case the original used the wrong rate.
              </p>
            )}

            {isMultiRate ? (
              <div className="space-y-3">
                {form.wage_rate_hours.map((row, i) => (
                  <div
                    key={`${row.label}-${row.employee_wage_rate_id ?? i}`}
                    className="rounded border border-gray-200 bg-white p-3"
                  >
                    <div className="mb-2 flex items-center justify-between">
                      <span className="text-sm font-medium text-gray-900">{row.label}</span>
                      <span className="text-xs text-gray-500">
                        {formatCurrency(row.rate)}/hr
                      </span>
                    </div>
                    <div className="grid grid-cols-2 gap-2">
                      <BucketInput
                        label="Regular"
                        value={row.regular_hours}
                        onChange={(v) =>
                          setForm((f) => ({
                            ...f,
                            wage_rate_hours: f.wage_rate_hours.map((r, idx) =>
                              idx === i ? { ...r, regular_hours: v } : r,
                            ),
                          }))
                        }
                      />
                      <BucketInput
                        label="Overtime"
                        value={row.overtime_hours}
                        onChange={(v) =>
                          setForm((f) => ({
                            ...f,
                            wage_rate_hours: f.wage_rate_hours.map((r, idx) =>
                              idx === i ? { ...r, overtime_hours: v } : r,
                            ),
                          }))
                        }
                      />
                      <BucketInput
                        label="Holiday"
                        value={row.holiday_hours}
                        onChange={(v) =>
                          setForm((f) => ({
                            ...f,
                            wage_rate_hours: f.wage_rate_hours.map((r, idx) =>
                              idx === i ? { ...r, holiday_hours: v } : r,
                            ),
                          }))
                        }
                      />
                      <BucketInput
                        label="PTO"
                        value={row.pto_hours}
                        onChange={(v) =>
                          setForm((f) => ({
                            ...f,
                            wage_rate_hours: f.wage_rate_hours.map((r, idx) =>
                              idx === i ? { ...r, pto_hours: v } : r,
                            ),
                          }))
                        }
                      />
                    </div>
                  </div>
                ))}
                <div className="rounded bg-gray-100 px-3 py-2 text-xs text-gray-700">
                  Bucket gross (locally computed):{' '}
                  <span className="font-semibold">
                    {formatCurrency(bucketGross(form.wage_rate_hours))}
                  </span>{' '}
                  — final taxes & net come from the server preview on the right.
                </div>
                <FieldRow label="Bonus" original={payrollItem.bonus} prefix="$">
                  <Input
                    type="number"
                    step="0.01"
                    min={0}
                    value={form.bonus}
                    onChange={(e) => setForm((f) => ({ ...f, bonus: e.target.value }))}
                  />
                </FieldRow>
                <FieldRow label="Tips" original={payrollItem.reported_tips} prefix="$">
                  <Input
                    type="number"
                    step="0.01"
                    min={0}
                    value={form.reported_tips}
                    onChange={(e) =>
                      setForm((f) => ({ ...f, reported_tips: e.target.value }))
                    }
                  />
                </FieldRow>
              </div>
            ) : (
              <>
                <FieldRow label="Regular hours" original={payrollItem.hours_worked}>
                  <Input type="number" step="0.01" min={0}
                    value={form.hours_worked}
                    onChange={e => setForm(f => ({ ...f, hours_worked: e.target.value }))} />
                </FieldRow>
                <FieldRow label="Overtime hours" original={payrollItem.overtime_hours}>
                  <Input type="number" step="0.01" min={0}
                    value={form.overtime_hours}
                    onChange={e => setForm(f => ({ ...f, overtime_hours: e.target.value }))} />
                </FieldRow>
                <FieldRow label="Holiday hours" original={payrollItem.holiday_hours}>
                  <Input type="number" step="0.01" min={0}
                    value={form.holiday_hours}
                    onChange={e => setForm(f => ({ ...f, holiday_hours: e.target.value }))} />
                </FieldRow>
                <FieldRow label="PTO hours" original={payrollItem.pto_hours}>
                  <Input type="number" step="0.01" min={0}
                    value={form.pto_hours}
                    onChange={e => setForm(f => ({ ...f, pto_hours: e.target.value }))} />
                </FieldRow>
                <FieldRow label="Pay rate" original={payrollItem.pay_rate} prefix="$">
                  <Input type="number" step="0.01" min={0}
                    value={form.pay_rate}
                    onChange={e => setForm(f => ({ ...f, pay_rate: e.target.value }))} />
                </FieldRow>
                <FieldRow label="Bonus" original={payrollItem.bonus} prefix="$">
                  <Input type="number" step="0.01" min={0}
                    value={form.bonus}
                    onChange={e => setForm(f => ({ ...f, bonus: e.target.value }))} />
                </FieldRow>
                <FieldRow label="Tips" original={payrollItem.reported_tips} prefix="$">
                  <Input type="number" step="0.01" min={0}
                    value={form.reported_tips}
                    onChange={e => setForm(f => ({ ...f, reported_tips: e.target.value }))} />
                </FieldRow>
              </>
            )}
          </div>

          {/* Preview */}
          <div className="space-y-3 rounded-lg border bg-gray-50 p-4">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-semibold text-gray-900">Replacement check preview</h3>
              {previewLoading && <span className="text-xs text-gray-500">Calculating…</span>}
            </div>

            {!inputsChanged && (
              <p className="text-sm italic text-gray-500">
                No changes yet — adjust an input above to see the replacement.
              </p>
            )}

            {previewError && <p className="text-sm text-red-600">{previewError}</p>}

            {preview?.meta.is_zero_change && (
              <p className="text-sm text-gray-600">
                The corrected inputs match the original — nothing to replace.
                If the check is just lost or damaged, use the standard reprint
                action instead.
              </p>
            )}

            {preview && !preview.meta.is_zero_change && original && corrected && (
              <div className="space-y-2 text-sm">
                <DeltaLine label="Gross pay" original={original.gross_pay} corrected={corrected.gross_pay} />
                <DeltaLine label="Federal income tax" original={original.withholding_tax} corrected={corrected.withholding_tax} />
                <DeltaLine label="Social Security" original={original.social_security_tax} corrected={corrected.social_security_tax} />
                <DeltaLine label="Medicare" original={original.medicare_tax} corrected={corrected.medicare_tax} />
                <hr />
                <DeltaLine label="Net (the new check)" original={original.net_pay} corrected={corrected.net_pay} bold />

                <div className="mt-2 rounded border-l-4 border-amber-400 bg-amber-50 p-3 text-xs text-amber-900">
                  <p className="font-medium">
                    {mode === 'void_and_reissue' ? (
                      <>
                        Old check #{payrollItem.check_number} will be voided in
                        the audit trail; a new check # will be assigned for{' '}
                        {formatCurrency(corrected.net_pay)}.
                      </>
                    ) : (
                      <>
                        Check #{payrollItem.check_number} stays the same — the
                        item is rewritten in place to {formatCurrency(corrected.net_pay)}.
                        Make sure no copy of the old version was distributed.
                      </>
                    )}
                  </p>
                  <p className="mt-1">
                    YTDs, FIT deposit (if enabled), tax sync, and reports
                    update from the new values automatically.
                  </p>
                </div>
              </div>
            )}
          </div>
        </div>

        <div>
          <Label htmlFor="rcm-reason">
            Reason <span className="text-red-500">*</span>
          </Label>
          <Textarea
            id="rcm-reason"
            rows={2}
            value={form.reason}
            onChange={e => setForm(f => ({ ...f, reason: e.target.value }))}
            placeholder="e.g. Original check returned uncashed; correcting hours from 60 to 80"
          />
          <p className="mt-1 text-xs text-gray-500">
            Required ({MIN_REASON_LENGTH}+ characters). Recorded on the
            payroll item's check_events as a permanent audit entry.
          </p>
        </div>

        {submitError && (
          <p className="rounded border border-red-200 bg-red-50 p-2 text-sm text-red-700">
            {submitError}
          </p>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)} disabled={submitting}>
            Cancel
          </Button>
          <Button onClick={handleSubmit} disabled={!canSubmit}>
            {submitting
              ? 'Replacing…'
              : mode === 'void_and_reissue'
                ? 'Void original & cut replacement'
                : 'Replace check'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------
// Helpers / sub-components
// ---------------------------------------------------------------------------

function initialForm(item: PayrollItem): FormState {
  return {
    hours_worked: toStr(item.hours_worked),
    overtime_hours: toStr(item.overtime_hours),
    holiday_hours: toStr(item.holiday_hours),
    pto_hours: toStr(item.pto_hours),
    pay_rate: toStr(item.pay_rate),
    bonus: toStr(item.bonus),
    reported_tips: toStr(item.reported_tips),
    reason: '',
    wage_rate_hours: bucketsToForm(item.wage_rate_hours),
  };
}

interface BucketInputProps {
  label: string;
  value: string;
  onChange: (v: string) => void;
}

function BucketInput({ label, value, onChange }: BucketInputProps) {
  return (
    <div className="flex flex-col gap-1">
      <Label className="text-xs text-gray-600">{label}</Label>
      <Input
        type="number"
        step="0.01"
        min={0}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
    </div>
  );
}

interface ModeBannerProps {
  mode: ReplaceCheckPreview['mode'] | undefined;
  originalCheckNumber: string | null | undefined;
  payrollItem: PayrollItem;
}

function ModeBanner({ mode, originalCheckNumber, payrollItem }: ModeBannerProps) {
  // Until preview returns, infer the mode locally from check_printed_at so
  // the operator sees the right context immediately.
  const inferred = mode ?? (payrollItem.check_printed_at ? 'void_and_reissue' : 'in_place');
  const isReissue = inferred === 'void_and_reissue';

  return (
    <div
      className={`rounded-md border p-3 text-xs ${isReissue ? 'border-orange-200 bg-orange-50 text-orange-900' : 'border-blue-200 bg-blue-50 text-blue-900'}`}
    >
      <p className="font-semibold">
        {isReissue
          ? `Mode: void & reissue (check #${originalCheckNumber} was already printed)`
          : `Mode: in-place edit (check #${originalCheckNumber} not yet printed)`}
      </p>
      <p className="mt-1">
        {isReissue
          ? 'The old check number will be invalidated in the audit trail. A new check number will be assigned and printed for the corrected amount.'
          : 'Because no physical check has been printed yet, the check number is reused. Just confirm the corrected values.'}
      </p>
    </div>
  );
}

interface FieldRowProps {
  label: string;
  original?: number | null;
  prefix?: string;
  children: React.ReactNode;
}

function FieldRow({ label, original, prefix, children }: FieldRowProps) {
  return (
    <div className="grid grid-cols-12 items-center gap-2">
      <Label className="col-span-5 text-sm">{label}</Label>
      <div className="col-span-4">{children}</div>
      <div className="col-span-3 text-right text-xs text-gray-500">
        was {prefix === '$' ? formatCurrency(original ?? 0) : (original ?? 0)}
      </div>
    </div>
  );
}

interface DeltaLineProps {
  label: string;
  original: number;
  corrected: number;
  bold?: boolean;
}

function DeltaLine({ label, original, corrected, bold }: DeltaLineProps) {
  const delta = corrected - original;
  const positive = delta > 0.005;
  const negative = delta < -0.005;
  const deltaClass = positive ? 'text-green-700' : negative ? 'text-red-700' : 'text-gray-500';
  return (
    <div className={`grid grid-cols-12 ${bold ? 'font-semibold' : ''}`}>
      <span className="col-span-5">{label}</span>
      <span className="col-span-3 text-right text-gray-600">{formatCurrency(original)}</span>
      <span className="col-span-1 text-center text-gray-400">→</span>
      <span className="col-span-3 text-right">{formatCurrency(corrected)}</span>
      <span className={`col-span-12 text-right text-xs ${deltaClass}`}>
        Δ {positive ? '+' : ''}
        {formatCurrency(delta)}
      </span>
    </div>
  );
}
