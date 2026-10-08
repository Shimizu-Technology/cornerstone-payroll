import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useState, useEffect, useMemo, useCallback, useRef } from 'react';
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
import { NumericInput } from '@/components/ui/numeric-input';
import { Textarea } from '@/components/ui/textarea';
import { payPeriodsApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import type {
  CorrectivePaycheckInputs,
  CorrectivePaycheckPreview,
  CorrectivePaycheckSnapshot,
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
  tips_paid_out: string;
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

function recordedFormInputs(recorded: CorrectivePaycheckSnapshot) {
  return { hours_worked: toStr(recorded.hours_worked), overtime_hours: toStr(recorded.overtime_hours),
    holiday_hours: toStr(recorded.holiday_hours), pto_hours: toStr(recorded.pto_hours), bonus: toStr(recorded.bonus),
    reported_tips: toStr(recorded.reported_tips), tips_paid_out: toStr(recorded.tips_paid_out) };
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
    tips_paid_out: toStr(originalItem.tips_paid_out),
    pay_date: todayIsoDate(),
    reason: '',
    notes: '',
  }));
  const [preview, setPreview] = useState<CorrectivePaycheckPreview | null>(null);
  const [baseline, setBaseline] = useState<CorrectivePaycheckSnapshot | null>(null);
  const [baselinePreview, setBaselinePreview] = useState<CorrectivePaycheckPreview | null>(null);
  const previewGeneration = useRef(0);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewError, setPreviewError, previewErrorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [issuing, setIssuing] = useState(false);
  const [issueError, setIssueError, issueErrorFeedbackAttempt] = useFeedbackState<string | null>(null);

  // When the modal re-opens for a different item, reset the form.
  useEffect(() => {
    if (!open) return;
    const generation = ++previewGeneration.current;
    setBaseline(null);
    setBaselinePreview(null);
    setForm({
      hours_worked: toStr(originalItem.hours_worked),
      overtime_hours: toStr(originalItem.overtime_hours),
      holiday_hours: toStr(originalItem.holiday_hours),
      pto_hours: toStr(originalItem.pto_hours),
      bonus: toStr(originalItem.bonus),
      reported_tips: toStr(originalItem.reported_tips),
      tips_paid_out: toStr(originalItem.tips_paid_out),
      pay_date: todayIsoDate(),
      reason: '',
      notes: '',
    });
    setPreview(null);
    setPreviewError(null);
    setIssueError(null);
    setPreviewLoading(true);
    void payPeriodsApi.correctivePaycheckPreview(originalPayPeriod.id, { employee_id: originalItem.employee_id, corrected_inputs: {} })
      .then(result => {
        if (generation !== previewGeneration.current) return;
        const recorded = result.recorded ?? result.original;
        setBaseline(recorded);
        setBaselinePreview(result);
        setForm(current => ({ ...current, ...recordedFormInputs(recorded) }));
        setPreview(result);
      }).catch(err => {
        if (generation === previewGeneration.current) setPreviewError(err instanceof Error ? err.message : 'Could not verify the recorded correction baseline');
      }).finally(() => {
        if (generation === previewGeneration.current) setPreviewLoading(false);
      });
    return () => { previewGeneration.current += 1; };
  }, [open, originalItem.id, originalItem.employee_id, originalPayPeriod.id, setIssueError, setPreviewError]); // eslint-disable-line react-hooks/exhaustive-deps

  const correctedInputs: CorrectivePaycheckInputs = useMemo(
    () => ({
      hours_worked: num(form.hours_worked),
      overtime_hours: num(form.overtime_hours),
      holiday_hours: num(form.holiday_hours),
      pto_hours: num(form.pto_hours),
      bonus: num(form.bonus),
      reported_tips: num(form.reported_tips),
      tips_paid_out: num(form.tips_paid_out),
    }),
    [form.hours_worked, form.overtime_hours, form.holiday_hours, form.pto_hours, form.bonus, form.reported_tips, form.tips_paid_out],
  );

  // Did the operator actually change anything? (Cheap local diff so we
  // don't fire a preview request for an unchanged form.)
  const inputsChanged = useMemo(() => {
    if (!baseline) return false;
    const o = baseline;
    return (
      Math.abs(num(form.hours_worked) - (o.hours_worked ?? 0)) > 0.001 ||
      Math.abs(num(form.overtime_hours) - (o.overtime_hours ?? 0)) > 0.001 ||
      Math.abs(num(form.holiday_hours) - (o.holiday_hours ?? 0)) > 0.001 ||
      Math.abs(num(form.pto_hours) - (o.pto_hours ?? 0)) > 0.001 ||
      Math.abs(num(form.bonus) - (o.bonus ?? 0)) > 0.005 ||
      Math.abs(num(form.reported_tips) - (o.reported_tips ?? 0)) > 0.005 ||
      Math.abs(num(form.tips_paid_out) - (o.tips_paid_out ?? 0)) > 0.005
    );
  }, [form, baseline]);

  // Debounced preview fetch when corrected inputs change.
  const fetchPreview = useCallback(async (force = false) => {
    if ((!baseline || !inputsChanged) && !force) {
      setPreview(null);
      setPreviewError(null);
      return;
    }
    setPreviewLoading(true);
    setPreviewError(null);
    const generation = ++previewGeneration.current;
    try {
      const result = await payPeriodsApi.correctivePaycheckPreview(originalPayPeriod.id, {
        employee_id: originalItem.employee_id,
        corrected_inputs: baseline ? correctedInputs : {},
      });
      if (generation === previewGeneration.current) {
        setPreview(result);
        if (!baseline) {
          const recorded = result.recorded ?? result.original;
          setBaseline(recorded); setBaselinePreview(result);
          setForm(current => ({ ...current, ...recordedFormInputs(recorded) }));
        }
      }
    } catch (err) {
      if (generation === previewGeneration.current) {
        setPreviewError(err instanceof Error ? err.message : 'Preview failed');
        setPreview(null);
      }
    } finally {
      if (generation === previewGeneration.current) setPreviewLoading(false);
    }
  }, [baseline, inputsChanged, setPreviewError, originalPayPeriod.id, originalItem.employee_id, correctedInputs]);

  useEffect(() => {
    if (!open || !baseline) return;
    previewGeneration.current += 1;
    if (!inputsChanged) {
      setPreview(baselinePreview);
      setPreviewLoading(false);
      return;
    }
    setPreview(null);
    setPreviewLoading(inputsChanged);
    const handle = setTimeout(fetchPreview, 350);
    return () => clearTimeout(handle);
  }, [open, baseline, baselinePreview, inputsChanged, fetchPreview]);

  const canSubmit =
    !!baseline &&
    !!preview &&
    /^[0-9a-f]{64}$/.test(preview.meta.review_digest ?? '') &&
    Object.entries(correctedInputs).every(([key, value]) => preview.corrected[key as keyof CorrectivePaycheckSnapshot] === value) &&
    !previewLoading && !previewError &&
    !preview.meta.is_zero_change &&
    form.reason.trim().length > 0 &&
    form.pay_date.length > 0 &&
    !issuing;

  const handleSubmit = async () => {
    if (!canSubmit || !preview?.meta.review_digest) return;
    setIssuing(true);
    setIssueError(null);
    try {
      const result = await payPeriodsApi.issueCorrectivePaycheck(originalPayPeriod.id, {
        employee_id: originalItem.employee_id,
        corrected_inputs: correctedInputs,
        expected_review_digest: preview!.meta.review_digest!,
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
      setPreview(null);
    } finally {
      setIssuing(false);
    }
  };

  const deltas = preview?.deltas;
  const reportedTipsDelta = deltas?.reported_tips_delta ?? deltas?.reported_tips ?? 0;
  const tipsPaidOutDelta = deltas?.tips_paid_out_delta ?? deltas?.tips_paid_out ?? 0;
  const corrected = preview?.corrected;
  const recorded = preview?.recorded ?? preview?.original;
  const willGenerateCheck = preview?.meta.will_generate_check ?? false;
  const employeeName = originalItem.employee_name ?? 'this employee';
  const handleDialogOpenChange = (nextOpen: boolean): void => {
    if (!nextOpen && issuing) return;
    onOpenChange(nextOpen);
  };

  return (
    <Dialog open={open} onOpenChange={handleDialogOpenChange} dismissOnEscape={!issuing}>
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
              Enter the corrected absolute values. The remaining delta against
              the original plus active corrections will be recorded separately.
            </p>

            <FieldRow label="Regular hours" original={originalItem.hours_worked}>
              <NumericInput
                aria-label="Regular hours" disabled={!baseline || issuing}
                min={0}
                inputMode="decimal"
                value={form.hours_worked === '' ? null : Number(form.hours_worked)}
                onValueChange={value => setForm(f => ({ ...f, hours_worked: value == null ? '' : String(value) }))}
              />
            </FieldRow>
            <FieldRow label="Overtime hours" original={originalItem.overtime_hours}>
              <NumericInput
                aria-label="Overtime hours" disabled={!baseline || issuing}
                min={0}
                inputMode="decimal"
                value={form.overtime_hours === '' ? null : Number(form.overtime_hours)}
                onValueChange={value => setForm(f => ({ ...f, overtime_hours: value == null ? '' : String(value) }))}
              />
            </FieldRow>
            <FieldRow label="Holiday hours" original={originalItem.holiday_hours}>
              <NumericInput
                aria-label="Holiday hours" disabled={!baseline || issuing}
                min={0}
                inputMode="decimal"
                value={form.holiday_hours === '' ? null : Number(form.holiday_hours)}
                onValueChange={value => setForm(f => ({ ...f, holiday_hours: value == null ? '' : String(value) }))}
              />
            </FieldRow>
            <FieldRow label="PTO hours" original={originalItem.pto_hours}>
              <NumericInput
                aria-label="PTO hours" disabled={!baseline || issuing}
                min={0}
                inputMode="decimal"
                value={form.pto_hours === '' ? null : Number(form.pto_hours)}
                onValueChange={value => setForm(f => ({ ...f, pto_hours: value == null ? '' : String(value) }))}
              />
            </FieldRow>
            <FieldRow label="Bonus" original={originalItem.bonus} prefix="$">
              <NumericInput
                aria-label="Bonus" disabled={!baseline || issuing}
                min={0}
                inputMode="decimal"
                value={form.bonus === '' ? null : Number(form.bonus)}
                onValueChange={value => setForm(f => ({ ...f, bonus: value == null ? '' : String(value) }))}
              />
            </FieldRow>
            <FieldRow label="Reported tips" original={originalItem.reported_tips} prefix="$">
              <NumericInput
                aria-label="Reported tips" disabled={!baseline || issuing}
                min={0}
                inputMode="decimal"
                value={form.reported_tips === '' ? null : Number(form.reported_tips)}
                onValueChange={value => setForm(f => ({ ...f, reported_tips: value == null ? '' : String(value) }))}
              />
            </FieldRow>
            <FieldRow label="Tips paid out" original={originalItem.tips_paid_out} prefix="$">
              <NumericInput
                aria-label="Tips paid out" disabled={!baseline || issuing}
                min={0}
                inputMode="decimal"
                value={form.tips_paid_out === '' ? null : Number(form.tips_paid_out)}
                onValueChange={value => setForm(f => ({ ...f, tips_paid_out: value == null ? '' : String(value) }))}
              />
            </FieldRow>
          </div>

          {/* Preview */}
          <div className="space-y-3 rounded-lg border bg-gray-50 p-4">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h3 className="text-sm font-semibold text-gray-900">Computed delta</h3>
              <Button type="button" size="sm" variant="outline" disabled={issuing || previewLoading}
                onClick={() => void fetchPreview(true)}>Refresh correction preview</Button>
              {previewLoading && (
                <span className="text-xs text-gray-500">Calculating…</span>
              )}
            </div>

            {!inputsChanged && (!preview || preview.meta.is_zero_change) && (
              <p className="text-sm italic text-gray-500">
                No changes yet — adjust an input above to see the delta.
              </p>
            )}

            {previewError && (
              <ActionFeedback retryKey={previewErrorFeedbackAttempt} tone="error" message={previewError} />
            )}
            {preview && !/^[0-9a-f]{64}$/.test(preview.meta.review_digest ?? '') && (
              <p role="alert" className="text-sm text-red-700">A verified preview is required. Refresh the correction preview before issuing.</p>
            )}

            {preview?.meta.is_zero_change && (
              <p className="text-sm text-gray-600">
                The corrected inputs match the recorded amounts — nothing to issue.
              </p>
            )}

            {preview && !preview.meta.is_zero_change && deltas && recorded && corrected && (
              <div className="space-y-2 text-sm">
                <p className="text-xs text-gray-600">Recorded amounts include the frozen original and {preview.meta.active_corrective_count ?? 0} active corrections. Arrows show recorded → corrected target.</p>
                <p className="text-xs text-gray-600">Frozen original: gross {formatCurrency(preview.original.gross_pay)} · net {formatCurrency(preview.original.net_pay)}.</p>
                <DeltaLine label="Gross pay" original={recorded.gross_pay} corrected={corrected.gross_pay} delta={deltas.gross_pay} />
                <DeltaLine label="Federal income tax" original={recorded.withholding_tax} corrected={corrected.withholding_tax} delta={deltas.withholding_tax} />
                <DeltaLine label="Social Security" original={recorded.social_security_tax} corrected={corrected.social_security_tax} delta={deltas.social_security_tax} />
                <DeltaLine label="Medicare" original={recorded.medicare_tax} corrected={corrected.medicare_tax} delta={deltas.medicare_tax} />
                <DeltaLine label="Reported tips" original={recorded.reported_tips} corrected={corrected.reported_tips} delta={reportedTipsDelta} />
                <DeltaLine label="Tips paid out" original={recorded.tips_paid_out} corrected={corrected.tips_paid_out} delta={tipsPaidOutDelta} />
                <hr />
                <DeltaLine label="Net pay" original={recorded.net_pay} corrected={corrected.net_pay} delta={deltas.net_pay} bold />
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
          <ActionFeedback retryKey={issueErrorFeedbackAttempt} tone="error" message={issueError} />
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
    <div className="grid grid-cols-1 gap-2 rounded-lg border border-neutral-100 p-2 sm:grid-cols-12 sm:items-center sm:border-0 sm:p-0">
      <Label className="text-sm sm:col-span-5">{label}</Label>
      <div className="sm:col-span-4">{children}</div>
      <div className="text-xs text-gray-500 sm:col-span-3 sm:text-right">
        original {prefix === '$' ? formatCurrency(original ?? 0) : (original ?? 0)}
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
    <div className={`grid grid-cols-[minmax(0,1fr)_auto_auto] gap-2 sm:grid-cols-12 ${bold ? 'font-semibold' : ''}`}>
      <span className="col-span-3 sm:col-span-5">{label}</span>
      <span className="text-right text-gray-600 sm:col-span-3">{formatCurrency(original)}</span>
      <span className="text-center text-gray-400 sm:col-span-1">→</span>
      <span className="text-right sm:col-span-3">{formatCurrency(corrected)}</span>
      <span className={`col-span-3 text-right text-xs sm:col-span-12 ${deltaClass}`}>
        Δ {positive ? '+' : ''}
        {formatCurrency(delta)}
      </span>
    </div>
  );
}
