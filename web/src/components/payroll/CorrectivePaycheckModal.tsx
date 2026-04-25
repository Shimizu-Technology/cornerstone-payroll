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
import { payPeriodsApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import type {
  CorrectivePaycheckInputs,
  CorrectivePaycheckPreview,
  PayPeriod,
  PayrollItem,
} from '@/types';

interface CorrectivePaycheckModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  originalPayPeriod: PayPeriod;
  originalItem: PayrollItem;
  onIssued: (result: {
    supplemental: PayPeriod;
    correctiveItem: PayrollItem;
  }) => void;
}

interface FormState {
  hours_worked: string;
  overtime_hours: string;
  holiday_hours: string;
  pto_hours: string;
  bonus: string;
  reported_tips: string;
  pay_date: string;
  reason: string;
  notes: string;
}

function toStr(value: number | null | undefined): string {
  if (value === null || value === undefined || Number.isNaN(value)) return '';
  return String(value);
}

function num(value: string): number {
  const parsed = parseFloat(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function todayIsoDate(): string {
  const d = new Date();
  const year = d.getFullYear();
  const month = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export function CorrectivePaycheckModal({
  open,
  onOpenChange,
  originalPayPeriod,
  originalItem,
  onIssued,
}: CorrectivePaycheckModalProps) {
  const [form, setForm] = useState<FormState>(() => ({
    hours_worked: toStr(originalItem.hours_worked),
    overtime_hours: toStr(originalItem.overtime_hours),
    holiday_hours: toStr(originalItem.holiday_hours),
    pto_hours: toStr(originalItem.pto_hours),
    bonus: toStr(originalItem.bonus),
    reported_tips: toStr(originalItem.reported_tips),
    pay_date: todayIsoDate(),
    reason: '',
    notes: '',
  }));
  const [preview, setPreview] = useState<CorrectivePaycheckPreview | null>(null);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [issuing, setIssuing] = useState(false);
  const [issueError, setIssueError] = useState<string | null>(null);

  // When the modal re-opens for a different item, reset the form.
  useEffect(() => {
    if (!open) return;
    setForm({
      hours_worked: toStr(originalItem.hours_worked),
      overtime_hours: toStr(originalItem.overtime_hours),
      holiday_hours: toStr(originalItem.holiday_hours),
      pto_hours: toStr(originalItem.pto_hours),
      bonus: toStr(originalItem.bonus),
      reported_tips: toStr(originalItem.reported_tips),
      pay_date: todayIsoDate(),
      reason: '',
      notes: '',
    });
    setPreview(null);
    setPreviewError(null);
    setIssueError(null);
  }, [open, originalItem.id]);  // eslint-disable-line react-hooks/exhaustive-deps

  const correctedInputs: CorrectivePaycheckInputs = useMemo(
    () => ({
      hours_worked: num(form.hours_worked),
      overtime_hours: num(form.overtime_hours),
      holiday_hours: num(form.holiday_hours),
      pto_hours: num(form.pto_hours),
      bonus: num(form.bonus),
      reported_tips: num(form.reported_tips),
    }),
    [form.hours_worked, form.overtime_hours, form.holiday_hours, form.pto_hours, form.bonus, form.reported_tips],
  );

  // Did the operator actually change anything? (Cheap local diff so we
  // don't fire a preview request for an unchanged form.)
  const inputsChanged = useMemo(() => {
    const o = originalItem;
    return (
      Math.abs(num(form.hours_worked) - (o.hours_worked ?? 0)) > 0.001 ||
      Math.abs(num(form.overtime_hours) - (o.overtime_hours ?? 0)) > 0.001 ||
      Math.abs(num(form.holiday_hours) - (o.holiday_hours ?? 0)) > 0.001 ||
      Math.abs(num(form.pto_hours) - (o.pto_hours ?? 0)) > 0.001 ||
      Math.abs(num(form.bonus) - (o.bonus ?? 0)) > 0.005 ||
      Math.abs(num(form.reported_tips) - (o.reported_tips ?? 0)) > 0.005
    );
  }, [form, originalItem]);

  // Debounced preview fetch when corrected inputs change.
  const fetchPreview = useCallback(async () => {
    if (!inputsChanged) {
      setPreview(null);
      setPreviewError(null);
      return;
    }
    setPreviewLoading(true);
    setPreviewError(null);
    try {
      const result = await payPeriodsApi.correctivePaycheckPreview(originalPayPeriod.id, {
        employee_id: originalItem.employee_id,
        corrected_inputs: correctedInputs,
      });
      setPreview(result);
    } catch (err) {
      setPreviewError(err instanceof Error ? err.message : 'Preview failed');
      setPreview(null);
    } finally {
      setPreviewLoading(false);
    }
  }, [inputsChanged, originalPayPeriod.id, originalItem.employee_id, correctedInputs]);

  useEffect(() => {
    if (!open) return;
    const handle = setTimeout(fetchPreview, 350);
    return () => clearTimeout(handle);
  }, [open, fetchPreview]);

  const canSubmit =
    inputsChanged &&
    !!preview &&
    !preview.meta.is_zero_change &&
    form.reason.trim().length > 0 &&
    form.pay_date.length > 0 &&
    !issuing;

  const handleSubmit = async () => {
    setIssuing(true);
    setIssueError(null);
    try {
      const result = await payPeriodsApi.issueCorrectivePaycheck(originalPayPeriod.id, {
        employee_id: originalItem.employee_id,
        corrected_inputs: correctedInputs,
        pay_date: form.pay_date,
        reason: form.reason.trim(),
        notes: form.notes.trim() || undefined,
      });
      onIssued({
        supplemental: result.supplemental_pay_period,
        correctiveItem: result.corrective_payroll_item,
      });
      onOpenChange(false);
    } catch (err) {
      setIssueError(err instanceof Error ? err.message : 'Failed to issue corrective paycheck');
    } finally {
      setIssuing(false);
    }
  };

  const deltas = preview?.deltas;
  const corrected = preview?.corrected;
  const original = preview?.original;
  const willGenerateCheck = preview?.meta.will_generate_check ?? false;
  const employeeName = originalItem.employee_name ?? 'this employee';

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="dialog-wide max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Issue Corrective Paycheck</DialogTitle>
          <DialogDescription>
            Issue a one-off corrective check for <strong>{employeeName}</strong> for pay period{' '}
            <strong>{originalPayPeriod.period_description ?? `${originalPayPeriod.start_date} – ${originalPayPeriod.end_date}`}</strong>.
            The original committed period will not be touched — a separate
            supplemental period carrying the delta will be created and committed.
            YTD totals, tax sync, FIT auto-deposit, and reports will all reflect
            the corrected amounts.
          </DialogDescription>
        </DialogHeader>

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
          {/* Inputs */}
          <div className="space-y-3">
            <h3 className="text-sm font-semibold text-gray-900">Corrected inputs</h3>
            <p className="text-xs text-gray-500">
              Enter what the values <em>should have been</em>. The delta against
              the original will become the corrective check.
            </p>

            <FieldRow label="Regular hours" original={originalItem.hours_worked}>
              <Input
                type="text"
                inputMode="decimal"
                value={form.hours_worked}
                onChange={e => setForm(f => ({ ...f, hours_worked: e.target.value }))}
              />
            </FieldRow>
            <FieldRow label="Overtime hours" original={originalItem.overtime_hours}>
              <Input
                type="text"
                inputMode="decimal"
                value={form.overtime_hours}
                onChange={e => setForm(f => ({ ...f, overtime_hours: e.target.value }))}
              />
            </FieldRow>
            <FieldRow label="Holiday hours" original={originalItem.holiday_hours}>
              <Input
                type="text"
                inputMode="decimal"
                value={form.holiday_hours}
                onChange={e => setForm(f => ({ ...f, holiday_hours: e.target.value }))}
              />
            </FieldRow>
            <FieldRow label="PTO hours" original={originalItem.pto_hours}>
              <Input
                type="text"
                inputMode="decimal"
                value={form.pto_hours}
                onChange={e => setForm(f => ({ ...f, pto_hours: e.target.value }))}
              />
            </FieldRow>
            <FieldRow label="Bonus" original={originalItem.bonus} prefix="$">
              <Input
                type="text"
                inputMode="decimal"
                value={form.bonus}
                onChange={e => setForm(f => ({ ...f, bonus: e.target.value }))}
              />
            </FieldRow>
            <FieldRow label="Tips" original={originalItem.reported_tips} prefix="$">
              <Input
                type="text"
                inputMode="decimal"
                value={form.reported_tips}
                onChange={e => setForm(f => ({ ...f, reported_tips: e.target.value }))}
              />
            </FieldRow>
          </div>

          {/* Preview */}
          <div className="space-y-3 rounded-lg border bg-gray-50 p-4">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-semibold text-gray-900">Computed delta</h3>
              {previewLoading && (
                <span className="text-xs text-gray-500">Calculating…</span>
              )}
            </div>

            {!inputsChanged && (
              <p className="text-sm italic text-gray-500">
                No changes yet — adjust an input above to see the delta.
              </p>
            )}

            {previewError && (
              <p className="text-sm text-red-600">{previewError}</p>
            )}

            {preview?.meta.is_zero_change && (
              <p className="text-sm text-gray-600">
                The corrected inputs match the original — nothing to issue.
              </p>
            )}

            {preview && !preview.meta.is_zero_change && deltas && original && corrected && (
              <div className="space-y-2 text-sm">
                <DeltaLine label="Gross pay" original={original.gross_pay} corrected={corrected.gross_pay} delta={deltas.gross_pay} />
                <DeltaLine label="Federal income tax" original={original.withholding_tax} corrected={corrected.withholding_tax} delta={deltas.withholding_tax} />
                <DeltaLine label="Social Security" original={original.social_security_tax} corrected={corrected.social_security_tax} delta={deltas.social_security_tax} />
                <DeltaLine label="Medicare" original={original.medicare_tax} corrected={corrected.medicare_tax} delta={deltas.medicare_tax} />
                <hr />
                <DeltaLine label="Net pay" original={original.net_pay} corrected={corrected.net_pay} delta={deltas.net_pay} bold />
                <div className="mt-2 rounded border-l-4 border-blue-400 bg-blue-50 p-3 text-xs text-blue-900">
                  {willGenerateCheck ? (
                    <>
                      <p className="font-medium">A new check will be cut for {formatCurrency(deltas.net_pay)}.</p>
                      <p>The supplemental period gets its own check #, FIT
                      deposit (if enabled), tax sync, and transmittal.
                      YTDs and reports update automatically.</p>
                    </>
                  ) : (
                    <>
                      <p className="font-medium">No check will be cut (net delta is {formatCurrency(deltas.net_pay)}).</p>
                      <p>The supplemental will be recorded as an accounting
                      adjustment so YTDs/W-2s correct themselves, but you'll
                      need to recover any overpayment (e.g. via a deduction
                      in the next regular period).</p>
                    </>
                  )}
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Why + when */}
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <div>
            <Label htmlFor="cpr-reason">Reason <span className="text-red-500">*</span></Label>
            <Textarea
              id="cpr-reason"
              rows={2}
              value={form.reason}
              onChange={e => setForm(f => ({ ...f, reason: e.target.value }))}
              placeholder="e.g. Client reported actual 80h worked, original entry was 60h"
            />
            <p className="mt-1 text-xs text-gray-500">Recorded on the corrective item and on the supplemental period's notes.</p>
          </div>
          <div>
            <Label htmlFor="cpr-pay-date">Corrective check pay date <span className="text-red-500">*</span></Label>
            <Input
              id="cpr-pay-date"
              type="date"
              value={form.pay_date}
              onChange={e => setForm(f => ({ ...f, pay_date: e.target.value }))}
              min={originalPayPeriod.end_date}
            />
            <p className="mt-1 text-xs text-gray-500">Must be on or after the original period's end date ({originalPayPeriod.end_date}).</p>
          </div>
        </div>

        {issueError && (
          <p className="rounded border border-red-200 bg-red-50 p-2 text-sm text-red-700">{issueError}</p>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)} disabled={issuing}>
            Cancel
          </Button>
          <Button onClick={handleSubmit} disabled={!canSubmit}>
            {issuing ? 'Issuing…' : 'Issue corrective paycheck'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
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
  delta: number;
  bold?: boolean;
}

function DeltaLine({ label, original, corrected, delta, bold }: DeltaLineProps) {
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
