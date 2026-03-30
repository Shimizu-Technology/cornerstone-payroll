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

interface PayrollItemEditModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  payPeriodId: number;
  item: PayrollItem | null;
  onSaved: (updated: PayrollItem) => void;
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
  withholding_tax_override: string;
  wage_rate_hours: PayrollItemWageRateHours[];
}

export function PayrollItemEditModal({
  open,
  onOpenChange,
  payPeriodId,
  item,
  onSaved,
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
    withholding_tax_override: '',
    wage_rate_hours: [],
  });
  const [saving, setSaving] = useState(false);
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
        withholding_tax_override: item.withholding_tax_override != null ? String(item.withholding_tax_override) : '',
        wage_rate_hours: initialWageRateHours,
      });
      setError(null);
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
        withholding_tax_override: fields.withholding_tax_override.trim() === '' ? null : parseFloat(fields.withholding_tax_override),
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

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
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
                  <p className="text-xs text-gray-400 mt-1">Leave blank to use default rate</p>
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

          {/* Tax Adjustments — not applicable to contractors */}
          {!isContractor && (
            <div>
              <h4 className="text-sm font-medium text-gray-700 mb-2">Tax Adjustments</h4>
              <div className="grid grid-cols-2 gap-3">
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
                    FIT Override
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
                    Leave blank for normal calculation; set to override FIT (e.g. 0 for exempt)
                  </p>
                </div>
              </div>
            </div>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)} disabled={saving}>
            Cancel
          </Button>
          <Button onClick={handleSaveAndRecalculate} disabled={saving}>
            {saving ? 'Saving...' : 'Save & Recalculate'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
