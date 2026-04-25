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
import { payrollItemsApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import type { EmployeeWageRate, PayrollItem, PayrollItemWageRateHours } from '@/types';

interface CustomEarningField {
  label: string;
  amount: string;
}

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
  salary_override: string;
  non_taxable_pay: number;
  additional_withholding: number;
  withholding_tax_adjustment: string;
  withholding_tax_override: string;
  wage_rate_hours: PayrollItemWageRateHours[];
  check_date: string;
  check_memo: string;
  custom_earnings: CustomEarningField[];
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
    salary_override: '',
    non_taxable_pay: 0,
    additional_withholding: 0,
    withholding_tax_adjustment: '',
    withholding_tax_override: '',
    wage_rate_hours: [],
    check_date: '',
    check_memo: '',
    custom_earnings: [],
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
        salary_override: item.salary_override != null ? String(item.salary_override) : '',
        non_taxable_pay: item.non_taxable_pay || 0,
        additional_withholding: item.additional_withholding || 0,
        withholding_tax_adjustment: item.withholding_tax_adjustment != null ? String(item.withholding_tax_adjustment) : '',
        withholding_tax_override: item.withholding_tax_override != null ? String(item.withholding_tax_override) : '',
        wage_rate_hours: initialWageRateHours,
        check_date: item.check_date || '',
        check_memo: item.check_memo || '',
        custom_earnings: (item.custom_earnings && item.custom_earnings.length > 0)
          ? item.custom_earnings.map(ce => ({ label: ce.label, amount: String(ce.amount) }))
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

  const handleChange = (field: keyof EditableFields, value: string) => {
    setFields((prev) => ({
      ...prev,
      [field]: value,
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

  const handleCustomEarningChange = (index: number, field: 'label' | 'amount', value: string) => {
    setFields((prev) => {
      const updated = [...prev.custom_earnings];
      updated[index] = { ...updated[index], [field]: value };
      return { ...prev, custom_earnings: updated };
    });
  };

  const addCustomEarning = () => {
    setFields((prev) => ({
      ...prev,
      custom_earnings: [...prev.custom_earnings, { label: '', amount: '0' }],
    }));
  };

  const removeCustomEarning = (index: number) => {
    setFields((prev) => ({
      ...prev,
      custom_earnings: prev.custom_earnings.filter((_, i) => i !== index),
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
        non_taxable_pay: parseFloat(String(fields.non_taxable_pay)) || 0,
        additional_withholding: parseFloat(String(fields.additional_withholding)) || 0,
        withholding_tax_adjustment: fields.withholding_tax_adjustment.trim() === '' ? null : (Number.isFinite(parseFloat(fields.withholding_tax_adjustment)) ? parseFloat(fields.withholding_tax_adjustment) : null),
        withholding_tax_override: fields.withholding_tax_override.trim() === '' ? null : (Number.isFinite(parseFloat(fields.withholding_tax_override)) ? parseFloat(fields.withholding_tax_override) : null),
        check_date: fields.check_date || null,
        check_memo: fields.check_memo || null,
        custom_earnings: fields.custom_earnings
          .filter(ce => ce.label.trim() && parseFloat(ce.amount) > 0)
          .map(ce => ({ label: ce.label.trim(), amount: parseFloat(ce.amount) || 0 })),
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
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Edit Payroll Item</DialogTitle>
          <DialogDescription>
            {item.employee_name} ({isContractor ? '1099 contractor' : item.employment_type}) — {hasMultiRate ? `${fields.wage_rate_hours.length} pay rates` : `Rate: $${Number(item.pay_rate).toFixed(2)}`}
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
                  <Input
                    type="number"
                    step="0.01"
                    min="0"
                    placeholder={`Default: ${formatCurrency(Number(item.pay_rate))}/period`}
                    value={fields.salary_override}
                    onChange={(e) => handleChange('salary_override', e.target.value)}
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
                        <div className="text-xs text-gray-500">${Number(rateEntry.rate).toFixed(2)}/hr</div>
                      </div>
                      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                        <div>
                          <label className="block text-xs text-gray-500 mb-1">Regular</label>
                          <Input
                            type="number"
                            step="0.5"
                            min="0"
                            value={rateEntry.regular_hours}
                            onChange={(e) => handleWageRateHourChange(index, 'regular_hours', e.target.value)}
                          />
                        </div>
                        <div>
                          <label className="block text-xs text-gray-500 mb-1">Overtime</label>
                          <Input
                            type="number"
                            step="0.5"
                            min="0"
                            value={rateEntry.overtime_hours}
                            onChange={(e) => handleWageRateHourChange(index, 'overtime_hours', e.target.value)}
                          />
                        </div>
                        <div>
                          <label className="block text-xs text-gray-500 mb-1">Holiday</label>
                          <Input
                            type="number"
                            step="0.5"
                            min="0"
                            value={rateEntry.holiday_hours}
                            onChange={(e) => handleWageRateHourChange(index, 'holiday_hours', e.target.value)}
                          />
                        </div>
                        <div>
                          <label className="block text-xs text-gray-500 mb-1">PTO</label>
                          <Input
                            type="number"
                            step="0.5"
                            min="0"
                            value={rateEntry.pto_hours}
                            onChange={(e) => handleWageRateHourChange(index, 'pto_hours', e.target.value)}
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
                    <Input
                      type="number"
                      step="0.5"
                      min="0"
                      value={fields.hours_worked}
                      onChange={(e) => handleChange('hours_worked', e.target.value)}
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">Overtime</label>
                    <Input
                      type="number"
                      step="0.5"
                      min="0"
                      value={fields.overtime_hours}
                      onChange={(e) => handleChange('overtime_hours', e.target.value)}
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">Holiday</label>
                    <Input
                      type="number"
                      step="0.5"
                      min="0"
                      value={fields.holiday_hours}
                      onChange={(e) => handleChange('holiday_hours', e.target.value)}
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">PTO</label>
                    <Input
                      type="number"
                      step="0.5"
                      min="0"
                      value={fields.pto_hours}
                      onChange={(e) => handleChange('pto_hours', e.target.value)}
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
                  <Input
                    type="number"
                    step="0.01"
                    min="0"
                    placeholder="Leave blank for default"
                    value={fields.salary_override}
                    onChange={(e) => handleChange('salary_override', e.target.value)}
                  />
                  <p className="text-xs text-gray-400 mt-0.5">
                    Override the per-period salary amount for this pay period only
                  </p>
                </div>
                <div>
                  <label className="block text-xs text-gray-500 mb-1">PTO Hours</label>
                  <Input
                    type="number"
                    step="0.5"
                    min="0"
                    value={fields.pto_hours}
                    onChange={(e) => handleChange('pto_hours', e.target.value)}
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
                <Input
                  type="number"
                  step="0.01"
                  min="0"
                  value={fields.bonus}
                  onChange={(e) => handleChange('bonus', e.target.value)}
                />
              </div>
              <div>
                <label className="block text-xs text-gray-500 mb-1">Reported Tips</label>
                <Input
                  type="number"
                  step="0.01"
                  min="0"
                  value={fields.reported_tips}
                  onChange={(e) => handleChange('reported_tips', e.target.value)}
                />
              </div>
              <div>
                <label className="block text-xs text-gray-500 mb-1">Non-Taxable Pay</label>
                <Input
                  type="number"
                  step="0.01"
                  min="0"
                  value={fields.non_taxable_pay}
                  onChange={(e) => handleChange('non_taxable_pay', e.target.value)}
                />
                <p className="text-xs text-gray-400 mt-0.5">
                  Reimbursements, allotments (not taxed)
                </p>
              </div>
            </div>
          </div>

          {/* Custom Earnings (Stipends, etc.) */}
          <div>
            <div className="flex items-center justify-between mb-2">
              <h4 className="text-sm font-medium text-gray-700">Custom Earnings</h4>
              <button
                type="button"
                onClick={addCustomEarning}
                className="text-xs text-blue-600 hover:text-blue-800 font-medium"
              >
                + Add Custom Earning
              </button>
            </div>
            <p className="text-xs text-gray-400 mb-2">
              Named taxable earnings (e.g. Chief Stipend, Asst Chief Stipend). Shows on check/stub by name.
            </p>
            {fields.custom_earnings.length === 0 && (
              <p className="text-xs text-gray-400 italic">No custom earnings added.</p>
            )}
            {fields.custom_earnings.map((ce, idx) => (
              <div key={idx} className="flex items-center gap-2 mb-2">
                <Input
                  placeholder="Label (e.g. Chief Stipend)"
                  value={ce.label}
                  onChange={(e) => handleCustomEarningChange(idx, 'label', e.target.value)}
                  className="flex-1"
                />
                <Input
                  type="number"
                  step="0.01"
                  min="0"
                  placeholder="Amount"
                  value={ce.amount}
                  onChange={(e) => handleCustomEarningChange(idx, 'amount', e.target.value)}
                  className="w-28"
                />
                <button
                  type="button"
                  onClick={() => removeCustomEarning(idx)}
                  className="text-red-500 hover:text-red-700 text-sm font-medium px-2"
                  title="Remove"
                >
                  ×
                </button>
              </div>
            ))}
          </div>

          {/* Tax Adjustments — not applicable to contractors */}
          {!isContractor && (
            <div>
              <h4 className="text-sm font-medium text-gray-700 mb-2">Tax Adjustments</h4>
              <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    Additional Withholding (W-4 4c)
                  </label>
                  <Input
                    type="number"
                    step="0.01"
                    min="0"
                    value={fields.additional_withholding}
                    onChange={(e) => handleChange('additional_withholding', e.target.value)}
                  />
                  <p className="text-xs text-gray-400 mt-0.5">
                    Extra $ withheld each pay period per W-4
                  </p>
                </div>
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    FIT Adjustment
                  </label>
                  <Input
                    type="number"
                    step="0.01"
                    placeholder="0.00"
                    value={fields.withholding_tax_adjustment}
                    onChange={(e) => handleChange('withholding_tax_adjustment', e.target.value)}
                  />
                  <p className="text-xs text-gray-400 mt-0.5">
                    One-time adjustment to the normal W-4 FIT for this pay period. Use negative values to reduce withholding.
                  </p>
                </div>
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    Final FIT Override
                  </label>
                  <Input
                    type="number"
                    step="0.01"
                    min="0"
                    placeholder="Auto-calculated"
                    value={fields.withholding_tax_override}
                    onChange={(e) => handleChange('withholding_tax_override', e.target.value)}
                  />
                  <p className="text-xs text-gray-400 mt-0.5">
                    Advanced: leave blank for normal calculation; set to force the final FIT amount for this pay period.
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
