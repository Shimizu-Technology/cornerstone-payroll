import { useState, useEffect } from 'react';
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
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { payrollItemsApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import type { EmployeeWageRate, PayrollItem, PayrollItemWageRateHours, PayrollAdjustmentTreatment } from '@/types';

interface PayrollAdjustmentField {
  label: string;
  amount: string;
  treatment: PayrollAdjustmentTreatment;
  notes: string;
  active: boolean;
}

const adjustmentTreatmentOptions: Array<{ value: PayrollAdjustmentTreatment; label: string; helper: string }> = [
  { value: 'taxable_addition', label: 'Adds taxable pay', helper: 'Increases gross wages and payroll taxes.' },
  { value: 'non_taxable_addition', label: 'Adds non-taxable reimbursement', helper: 'Increases net pay only.' },
  { value: 'post_tax_deduction', label: 'Deducts after taxes', helper: 'Taxes first, then this lowers the check.' },
  { value: 'pre_tax_deduction', label: 'Deducts before taxes', helper: 'Use only for approved pre-tax deductions confirmed by an accountant or payroll administrator.' },
];

interface PayrollItemEditModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  payPeriodId: number;
  item: PayrollItem | null;
  onSaved: (updated: PayrollItem) => void;
  onRemoved?: (id: number) => void;
  contractorPayType?: 'hourly' | 'flat_fee';
  wageRates?: EmployeeWageRate[];
}

interface EditableFields {
  hours_worked: number;
  overtime_hours: number;
  holiday_hours: number;
  pto_hours: number;
  bonus: number;
  reported_tips: number;
  tips_paid_out: number;
  salary_override: string;
  non_taxable_pay: number;
  additional_withholding_override: string;
  withholding_tax_adjustment: string;
  withholding_tax_override: string;
  wage_rate_hours: PayrollItemWageRateHours[];
  check_date: string;
  check_memo: string;
  payroll_adjustments: PayrollAdjustmentField[];
}

export function PayrollItemEditModal({
  open,
  onOpenChange,
  payPeriodId,
  item,
  onSaved,
  onRemoved,
  contractorPayType,
  wageRates = [],
}: PayrollItemEditModalProps) {
  const [fields, setFields] = useState<EditableFields>({
    hours_worked: 0,
    overtime_hours: 0,
    holiday_hours: 0,
    pto_hours: 0,
    bonus: 0,
    reported_tips: 0,
    tips_paid_out: 0,
    salary_override: '',
    non_taxable_pay: 0,
    additional_withholding_override: '',
    withholding_tax_adjustment: '',
    withholding_tax_override: '',
    wage_rate_hours: [],
    check_date: '',
    check_memo: '',
    payroll_adjustments: [],
  });
  const [saving, setSaving] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [confirmRemove, setConfirmRemove] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (item) {
      const initialWageRateHours = item.wage_rate_hours && item.wage_rate_hours.length > 0
        ? item.wage_rate_hours
        : wageRates.map((rate) => ({
            employee_wage_rate_id: rate.id,
            label: rate.label,
            rate: Number(rate.rate) || 0,
            regular_hours: rate.is_primary ? (item.hours_worked || 0) : 0,
            overtime_hours: 0,
            holiday_hours: 0,
            pto_hours: 0,
            is_primary: rate.is_primary,
            active: rate.active,
          }));

      setFields({
        hours_worked: item.hours_worked || 0,
        overtime_hours: item.overtime_hours || 0,
        holiday_hours: item.holiday_hours || 0,
        pto_hours: item.pto_hours || 0,
        bonus: item.bonus || 0,
        reported_tips: item.reported_tips || 0,
        tips_paid_out: item.tips_paid_out || 0,
        salary_override: item.salary_override != null ? String(item.salary_override) : '',
        non_taxable_pay: item.non_taxable_pay || 0,
        additional_withholding_override: item.additional_withholding_override != null ? String(item.additional_withholding_override) : '',
        withholding_tax_adjustment: item.withholding_tax_adjustment != null ? String(item.withholding_tax_adjustment) : '',
        withholding_tax_override: item.withholding_tax_override != null ? String(item.withholding_tax_override) : '',
        wage_rate_hours: initialWageRateHours,
        check_date: item.check_date || '',
        check_memo: item.check_memo || '',
        payroll_adjustments: (item.payroll_adjustments && item.payroll_adjustments.length > 0)
          ? item.payroll_adjustments.map(adjustment => ({
              label: adjustment.label,
              amount: String(adjustment.amount),
              treatment: adjustment.treatment,
              notes: adjustment.notes || '',
              active: adjustment.active !== false,
            }))
          : [],
      });
      setError(null);
      setConfirmRemove(false);
    }
  }, [item, wageRates]);

  if (!item) return null;

  const isSalary = item.employment_type === 'salary';
  const isContractor = item.employment_type === 'contractor';
  const isContractorHourly = isContractor && contractorPayType === 'hourly';
  const isContractorFlat = isContractor && contractorPayType !== 'hourly';
  const hasMultiRate = (item.employment_type === 'hourly' || isContractorHourly) && fields.wage_rate_hours.length > 1;
  const employeeAdditionalWithholding = Number(item.additional_withholding || 0);

  const handleChange = (field: keyof EditableFields, value: string) => {
    setFields((prev) => ({
      ...prev,
      [field]: value,
    }));
  };

  const handleNumberFieldChange = (
    field: 'hours_worked' | 'overtime_hours' | 'holiday_hours' | 'pto_hours' | 'bonus' | 'reported_tips' | 'tips_paid_out' | 'non_taxable_pay',
    value: number | null
  ) => {
    setFields((prev) => ({
      ...prev,
      [field]: value ?? 0,
    }));
  };

  const handleWageRateHourChange = (
    index: number,
    field: 'regular_hours' | 'overtime_hours' | 'holiday_hours' | 'pto_hours',
    value: string
  ) => {
    const numericValue = parseFloat(value) || 0;
    setFields((prev) => {
      const wageRateHours = [...prev.wage_rate_hours];
      wageRateHours[index] = {
        ...wageRateHours[index],
        [field]: numericValue,
      };

      return {
        ...prev,
        wage_rate_hours: wageRateHours,
        hours_worked: wageRateHours.reduce((sum, entry) => sum + (Number(entry.regular_hours) || 0), 0),
        overtime_hours: wageRateHours.reduce((sum, entry) => sum + (Number(entry.overtime_hours) || 0), 0),
        holiday_hours: wageRateHours.reduce((sum, entry) => sum + (Number(entry.holiday_hours) || 0), 0),
        pto_hours: wageRateHours.reduce((sum, entry) => sum + (Number(entry.pto_hours) || 0), 0),
      };
    });
  };

  const handlePayrollAdjustmentChange = (index: number, patch: Partial<PayrollAdjustmentField>) => {
    setFields((prev) => {
      const updated = [...prev.payroll_adjustments];
      updated[index] = { ...updated[index], ...patch };
      return { ...prev, payroll_adjustments: updated };
    });
  };

  const addPayrollAdjustment = () => {
    setFields((prev) => ({
      ...prev,
      payroll_adjustments: [...prev.payroll_adjustments, { label: '', amount: '0', treatment: 'post_tax_deduction', notes: '', active: true }],
    }));
  };

  const removePayrollAdjustment = (index: number) => {
    setFields((prev) => ({
      ...prev,
      payroll_adjustments: prev.payroll_adjustments.filter((_, i) => i !== index),
    }));
  };

  const handleSaveAndRecalculate = async () => {
    setSaving(true);
    setError(null);
    try {
      const payload: Record<string, unknown> = {
        hours_worked: parseFloat(String(fields.hours_worked)) || 0,
        overtime_hours: parseFloat(String(fields.overtime_hours)) || 0,
        holiday_hours: parseFloat(String(fields.holiday_hours)) || 0,
        pto_hours: parseFloat(String(fields.pto_hours)) || 0,
        bonus: parseFloat(String(fields.bonus)) || 0,
        reported_tips: parseFloat(String(fields.reported_tips)) || 0,
        tips_paid_out: parseFloat(String(fields.tips_paid_out)) || 0,
        non_taxable_pay: parseFloat(String(fields.non_taxable_pay)) || 0,
        additional_withholding_override: fields.additional_withholding_override.trim() === '' ? null : (Number.isFinite(parseFloat(fields.additional_withholding_override)) ? parseFloat(fields.additional_withholding_override) : null),
        withholding_tax_adjustment: fields.withholding_tax_adjustment.trim() === '' ? null : (Number.isFinite(parseFloat(fields.withholding_tax_adjustment)) ? parseFloat(fields.withholding_tax_adjustment) : null),
        withholding_tax_override: fields.withholding_tax_override.trim() === '' ? null : (Number.isFinite(parseFloat(fields.withholding_tax_override)) ? parseFloat(fields.withholding_tax_override) : null),
        check_date: fields.check_date || null,
        check_memo: fields.check_memo || null,
        payroll_adjustments: fields.payroll_adjustments
          .filter(adjustment => adjustment.label.trim() && parseFloat(adjustment.amount) > 0)
          .map(adjustment => ({
            label: adjustment.label.trim(),
            amount: parseFloat(adjustment.amount) || 0,
            treatment: adjustment.treatment,
            notes: adjustment.notes.trim(),
            active: adjustment.active !== false,
          })),
      };

      if (hasMultiRate) {
        payload.wage_rate_hours = fields.wage_rate_hours;
      }

      if (fields.salary_override !== '') {
        payload.salary_override = parseFloat(fields.salary_override) || 0;
      } else {
        payload.salary_override = null;
      }

      await payrollItemsApi.update(payPeriodId, item.id, payload as Partial<PayrollItem>);
      const recalcResult = await payrollItemsApi.recalculate(payPeriodId, item.id);
      onSaved(recalcResult.payroll_item);
      onOpenChange(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save');
    } finally {
      setSaving(false);
    }
  };

  const handleRemoveFromPayroll = async () => {
    if (!confirmRemove) {
      setConfirmRemove(true);
      return;
    }
    setRemoving(true);
    setError(null);
    try {
      await payrollItemsApi.delete(payPeriodId, item.id);
      onRemoved?.(item.id);
      onOpenChange(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to remove');
    } finally {
      setRemoving(false);
      setConfirmRemove(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="dialog-wide w-full max-w-5xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Edit Payroll Item</DialogTitle>
          <DialogDescription>
            {item.employee_name} ({isContractor ? '1099 contractor' : item.employment_type}) — {hasMultiRate ? `${fields.wage_rate_hours.length} pay rates` : `Rate: ${formatCurrency(Number(item.pay_rate))}`}
          </DialogDescription>
        </DialogHeader>

        {error && (
          <div className="p-3 bg-red-50 border border-red-200 text-red-700 rounded-lg text-sm">
            {error}
          </div>
        )}

        <div className="space-y-4 mt-4">
          {/* Current calculated values (read-only) */}
          <div className={`p-3 ${isContractor ? 'bg-emerald-50' : 'bg-gray-50'} rounded-lg text-sm grid grid-cols-3 gap-2`}>
            <div>
              <span className="text-gray-500">Gross:</span>{' '}
              <span className="font-medium">{formatCurrency(item.gross_pay || 0)}</span>
            </div>
            <div>
              <span className="text-gray-500">{isContractor ? 'Tax:' : 'FIT:'}</span>{' '}
              <span className="font-medium">{isContractor ? '$0.00' : formatCurrency(item.withholding_tax || 0)}</span>
            </div>
            <div>
              <span className="text-gray-500">Net:</span>{' '}
              <span className="font-medium text-green-600">{formatCurrency(item.net_pay || 0)}</span>
            </div>
          </div>

          {/* Flat-fee contractor payment override */}
          {isContractorFlat && (
            <div>
              <h4 className="text-sm font-medium text-gray-700 mb-2">Contract Payment</h4>
              <div className="grid grid-cols-1 gap-3">
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    Payment Amount Override
                  </label>
                  <NumericInput
                    placeholder={`Default: ${formatCurrency(Number(item.pay_rate))}/period`}
                    value={fields.salary_override === '' ? null : Number(fields.salary_override)}
                    onValueChange={(value) => handleChange('salary_override', value == null ? '' : String(value))}
                    min={0}
                    fixedDecimalsOnBlur={2}
                  />
                  <p className="text-xs text-gray-400 mt-1">Leave blank to use default rate. Set to 0 to skip payment this period.</p>
                </div>
              </div>
              <p className="text-xs text-amber-600 mt-2">
                No taxes withheld — 1099-NEC issued at year-end for $600+
              </p>
            </div>
          )}

          {/* Hours (for hourly employees AND hourly contractors) */}
          {!isSalary && !isContractorFlat && (
            <div>
              <h4 className="text-sm font-medium text-gray-700 mb-2">Hours</h4>
              {hasMultiRate ? (
                <div className="space-y-3">
                  {fields.wage_rate_hours.map((rateEntry, index) => (
                    <div key={`${rateEntry.label}-${index}`} className="rounded-lg border border-gray-200 p-3">
                      <div className="mb-2 flex items-center justify-between">
                        <div className="text-sm font-medium text-gray-900">{rateEntry.label}</div>
                        <div className="text-xs text-gray-500">{formatCurrency(Number(rateEntry.rate))}/hr</div>
                      </div>
                      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                        <div>
                          <label className="block text-xs text-gray-500 mb-1">Regular</label>
                          <NumericInput
                            value={rateEntry.regular_hours}
                            onValueChange={(value) => handleWageRateHourChange(index, 'regular_hours', String(value ?? 0))}
                            min={0}
                          />
                        </div>
                        <div>
                          <label className="block text-xs text-gray-500 mb-1">Overtime</label>
                          <NumericInput
                            value={rateEntry.overtime_hours}
                            onValueChange={(value) => handleWageRateHourChange(index, 'overtime_hours', String(value ?? 0))}
                            min={0}
                          />
                        </div>
                        <div>
                          <label className="block text-xs text-gray-500 mb-1">Holiday</label>
                          <NumericInput
                            value={rateEntry.holiday_hours}
                            onValueChange={(value) => handleWageRateHourChange(index, 'holiday_hours', String(value ?? 0))}
                            min={0}
                          />
                        </div>
                        <div>
                          <label className="block text-xs text-gray-500 mb-1">PTO</label>
                          <NumericInput
                            value={rateEntry.pto_hours}
                            onValueChange={(value) => handleWageRateHourChange(index, 'pto_hours', String(value ?? 0))}
                            min={0}
                          />
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              ) : (
                <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">Regular</label>
                    <NumericInput
                      value={fields.hours_worked}
                      onValueChange={(value) => handleNumberFieldChange('hours_worked', value)}
                      min={0}
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">Overtime</label>
                    <NumericInput
                      value={fields.overtime_hours}
                      onValueChange={(value) => handleNumberFieldChange('overtime_hours', value)}
                      min={0}
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">Holiday</label>
                    <NumericInput
                      value={fields.holiday_hours}
                      onValueChange={(value) => handleNumberFieldChange('holiday_hours', value)}
                      min={0}
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">PTO</label>
                    <NumericInput
                      value={fields.pto_hours}
                      onValueChange={(value) => handleNumberFieldChange('pto_hours', value)}
                      min={0}
                    />
                  </div>
                </div>
              )}
            </div>
          )}

          {/* Salary Override (for salary employees) */}
          {isSalary && (
            <div>
              <h4 className="text-sm font-medium text-gray-700 mb-2">Salary</h4>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    Salary Override (per period)
                  </label>
                  <NumericInput
                    placeholder="Leave blank for default"
                    value={fields.salary_override === '' ? null : Number(fields.salary_override)}
                    onValueChange={(value) => handleChange('salary_override', value == null ? '' : String(value))}
                    min={0}
                    fixedDecimalsOnBlur={2}
                  />
                  <p className="text-xs text-gray-400 mt-0.5">
                    Override the per-period salary amount for this pay period only
                  </p>
                </div>
                <div>
                  <label className="block text-xs text-gray-500 mb-1">PTO Hours</label>
                  <NumericInput
                    value={fields.pto_hours}
                    onValueChange={(value) => handleNumberFieldChange('pto_hours', value)}
                    min={0}
                  />
                </div>
              </div>
            </div>
          )}

          {/* Additional Earnings */}
          <div>
            <h4 className="text-sm font-medium text-gray-700 mb-2">Additional Earnings</h4>
            <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
              <div>
                <label className="block text-xs text-gray-500 mb-1">Bonus</label>
                <NumericInput
                  value={fields.bonus}
                  onValueChange={(value) => handleNumberFieldChange('bonus', value)}
                  min={0}
                  fixedDecimalsOnBlur={2}
                />
              </div>
              <div>
                <label className="block text-xs text-gray-500 mb-1">Reported Tips</label>
                <NumericInput
                  value={fields.reported_tips}
                  onValueChange={(value) => handleNumberFieldChange('reported_tips', value)}
                  min={0}
                  fixedDecimalsOnBlur={2}
                />
              </div>
              <div>
                <label className="block text-xs text-gray-500 mb-1">Non-Taxable Pay</label>
                <NumericInput
                  value={fields.non_taxable_pay}
                  onValueChange={(value) => handleNumberFieldChange('non_taxable_pay', value)}
                  min={0}
                  fixedDecimalsOnBlur={2}
                />
                <p className="text-xs text-gray-400 mt-0.5">
                  Reimbursements, allotments (not taxed)
                </p>
              </div>
              <div>
                <label className="block text-xs text-gray-500 mb-1">Tips Paid Out</label>
                <NumericInput
                  value={fields.tips_paid_out}
                  onValueChange={(value) => handleNumberFieldChange('tips_paid_out', value)}
                  min={0}
                  fixedDecimalsOnBlur={2}
                />
                <p className="text-xs text-gray-400 mt-0.5">
                  Reduces this check only. Does not reduce taxable wages or reported tips.
                </p>
              </div>
            </div>
          </div>

          {/* Payroll Adjustments */}
          <div className="rounded-lg border border-slate-200 bg-slate-50 p-3">
            <div className="mb-2 flex items-center justify-between gap-3">
              <div>
                <h4 className="text-sm font-medium text-gray-700">Payroll Adjustments</h4>
                <p className="mt-0.5 text-xs text-gray-500">
                  Use these when the adjustment needs a specific tax treatment. These are copied from employee defaults but can be changed for this check.
                </p>
              </div>
              <button
                type="button"
                onClick={addPayrollAdjustment}
                className="shrink-0 text-xs font-medium text-blue-600 hover:text-blue-800"
              >
                + Add Adjustment
              </button>
            </div>
            {fields.payroll_adjustments.length === 0 && (
              <p className="text-xs italic text-gray-400">No payroll adjustments added.</p>
            )}
            <div className="space-y-3">
              {fields.payroll_adjustments.map((adjustment, idx) => {
                const selected = adjustmentTreatmentOptions.find((option) => option.value === adjustment.treatment) || adjustmentTreatmentOptions[0];
                return (
                  <div key={idx} className="rounded-lg border border-slate-200 bg-white p-3">
                    <div className="grid grid-cols-1 gap-2 md:grid-cols-[minmax(0,1fr)_8rem_13rem_auto] md:items-end">
                      <Input
                        placeholder="Label (e.g. Uniform repayment)"
                        value={adjustment.label}
                        onChange={(e) => handlePayrollAdjustmentChange(idx, { label: e.target.value })}
                      />
                      <NumericInput
                        placeholder="Amount"
                        value={adjustment.amount === '' ? null : Number(adjustment.amount)}
                        onValueChange={(value) => handlePayrollAdjustmentChange(idx, { amount: value == null ? '' : String(value) })}
                        min={0}
                        fixedDecimalsOnBlur={2}
                      />
                      <Select
                        value={adjustment.treatment}
                        onChange={(e) => handlePayrollAdjustmentChange(idx, { treatment: e.target.value as PayrollAdjustmentTreatment })}
                      >
                        {adjustmentTreatmentOptions.map((option) => (
                          <option key={option.value} value={option.value}>{option.label}</option>
                        ))}
                      </Select>
                      <button
                        type="button"
                        onClick={() => removePayrollAdjustment(idx)}
                        className="text-sm font-medium text-red-500 hover:text-red-700 md:px-2"
                        title="Remove"
                      >
                        ×
                      </button>
                    </div>
                    <p className="mt-1 text-xs text-slate-500">{selected.helper}</p>
                    <Input
                      className="mt-2"
                      placeholder="Source / notes"
                      value={adjustment.notes}
                      onChange={(e) => handlePayrollAdjustmentChange(idx, { notes: e.target.value })}
                    />
                  </div>
                );
              })}
            </div>
          </div>

          {/* Tax Adjustments — not applicable to contractors */}
          {!isContractor && (
            <div>
              <h4 className="text-sm font-medium text-gray-700 mb-2">Tax Adjustments</h4>
              <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
                <div>
                  <label className="block text-xs text-gray-500 mb-1 min-h-4">
                    W-4 4(c) Extra W/H
                  </label>
                  <NumericInput
                    placeholder={employeeAdditionalWithholding > 0 ? employeeAdditionalWithholding.toFixed(2) : 'Use employee default'}
                    value={fields.additional_withholding_override === '' ? null : Number(fields.additional_withholding_override)}
                    onValueChange={(value) => handleChange('additional_withholding_override', value == null ? '' : String(value))}
                    min={0}
                    fixedDecimalsOnBlur={2}
                  />
                  <p className="text-xs text-gray-400 mt-0.5">
                    Blank uses the employee default of {formatCurrency(employeeAdditionalWithholding)}. Set 0.00 to skip it for this pay period.
                  </p>
                </div>
                <div>
                  <label className="block text-xs text-gray-500 mb-1 min-h-4">
                    FIT Adjustment
                  </label>
                  <NumericInput
                    placeholder="0.00"
                    value={fields.withholding_tax_adjustment === '' ? null : Number(fields.withholding_tax_adjustment)}
                    onValueChange={(value) => handleChange('withholding_tax_adjustment', value == null ? '' : String(value))}
                    fixedDecimalsOnBlur={2}
                  />
                  <p className="text-xs text-gray-400 mt-0.5">
                    One-time adjustment to the calculated FIT tax only. This does not change the W-4 4(c) amount shown to the left.
                  </p>
                </div>
                <div>
                  <label className="block text-xs text-gray-500 mb-1 min-h-4">
                    Final FIT Override
                  </label>
                  <NumericInput
                    placeholder="Auto-calculated"
                    value={fields.withholding_tax_override === '' ? null : Number(fields.withholding_tax_override)}
                    onValueChange={(value) => handleChange('withholding_tax_override', value == null ? '' : String(value))}
                    min={0}
                    fixedDecimalsOnBlur={2}
                  />
                  <p className="text-xs text-gray-400 mt-0.5">
                    Advanced: leave blank for normal calculation; set to force the final FIT tax amount for this pay period.
                  </p>
                </div>
              </div>
            </div>
          )}

          {/* Check Overrides */}
          <div>
            <h4 className="text-sm font-medium text-gray-700 mb-2">Check Overrides</h4>
            <p className="text-xs text-gray-400 mb-2">
              Override the date or memo printed on this person's check. Leave blank to use defaults.
            </p>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="block text-xs text-gray-500 mb-1">Check Date</label>
                <Input
                  type="date"
                  value={fields.check_date}
                  onChange={(e) => handleChange('check_date', e.target.value)}
                />
                <p className="text-xs text-gray-400 mt-0.5">
                  Overrides the pay date shown on this check
                </p>
              </div>
              <div>
                <label className="block text-xs text-gray-500 mb-1">Check Memo</label>
                <Input
                  type="text"
                  placeholder="Default memo"
                  value={fields.check_memo}
                  onChange={(e) => handleChange('check_memo', e.target.value)}
                />
                <p className="text-xs text-gray-400 mt-0.5">
                  Overrides the memo line on this check
                </p>
              </div>
            </div>
          </div>
        </div>

        <DialogFooter className="flex items-center justify-between sm:justify-between">
          <div>
            {confirmRemove ? (
              <div className="flex items-center gap-2">
                <span className="text-sm text-red-600">Remove this employee from payroll?</span>
                <Button variant="destructive" size="sm" onClick={handleRemoveFromPayroll} disabled={removing}>
                  {removing ? 'Removing...' : 'Yes, Remove'}
                </Button>
                <Button variant="outline" size="sm" onClick={() => setConfirmRemove(false)} disabled={removing}>
                  No
                </Button>
              </div>
            ) : (
              <Button
                variant="ghost"
                size="sm"
                className="text-red-600 hover:text-red-700 hover:bg-red-50"
                onClick={handleRemoveFromPayroll}
                disabled={saving}
              >
                Remove from Payroll
              </Button>
            )}
          </div>
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => onOpenChange(false)} disabled={saving}>
              Cancel
            </Button>
            <Button onClick={handleSaveAndRecalculate} disabled={saving}>
              {saving ? 'Saving...' : 'Save & Recalculate'}
            </Button>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
