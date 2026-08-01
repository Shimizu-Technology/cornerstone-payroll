import { useEffect, useMemo, useState } from 'react';
import { ArrowRight, LockKeyhole, ShieldCheck } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { ApiError, employeesApi } from '@/services/api';
import type {
  ContractorPayType,
  ContractorType,
  Employee,
  EmployeeClassificationTransition,
  EmploymentType,
  FilingStatus,
  PayFrequency,
} from '@/types';

interface EmployeeClassificationTransitionDialogProps {
  employee: Employee;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onTransitioned: (employee: Employee) => void;
}

interface TransitionForm {
  employment_type: EmploymentType;
  effective_date: string;
  reason: string;
  pay_rate: string;
  pay_frequency: PayFrequency;
  salary_type: 'annual' | 'per_period' | 'variable';
  filing_status: FilingStatus;
  contractor_type: ContractorType;
  contractor_pay_type: ContractorPayType;
  business_name: string;
  contractor_ein: string;
}

function todayIsoDate(): string {
  const date = new Date();
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function initialTransitionForm(employee: Employee): TransitionForm {
  return {
    employment_type: employee.employment_type === 'contractor' ? 'hourly' : 'contractor',
    effective_date: todayIsoDate(),
    reason: '',
    pay_rate: String(employee.pay_rate || ''),
    pay_frequency: employee.pay_frequency,
    salary_type: 'annual',
    filing_status: 'single',
    contractor_type: 'individual',
    contractor_pay_type: 'flat_fee',
    business_name: '',
    contractor_ein: '',
  };
}

export function EmployeeClassificationTransitionDialog({
  employee,
  open,
  onOpenChange,
  onTransitioned,
}: EmployeeClassificationTransitionDialogProps) {
  const [form, setForm] = useState<TransitionForm>(() => initialTransitionForm(employee));
  const [error, setError] = useState<string | null>(null);
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]>>({});
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setForm(initialTransitionForm(employee));
    setError(null);
    setFieldErrors({});
  }, [employee, open]);

  const movingToW2 = form.employment_type !== 'contractor';
  const targetLabel = movingToW2
    ? form.employment_type === 'salary' ? 'W-2 salaried employee' : 'W-2 hourly employee'
    : '1099 contractor';
  const canSubmit = useMemo(() => {
    const payRate = Number(form.pay_rate);
    const variableSalary = form.employment_type === 'salary' && form.salary_type === 'variable';
    return form.effective_date.length > 0
      && form.reason.trim().length >= 10
      && Number.isFinite(payRate)
      && (variableSalary ? payRate >= 0 : payRate > 0)
      && !saving;
  }, [form.effective_date, form.employment_type, form.pay_rate, form.reason, form.salary_type, saving]);

  const update = <K extends keyof TransitionForm>(key: K, value: TransitionForm[K]) => {
    setForm((current) => ({ ...current, [key]: value }));
    setFieldErrors((current) => {
      if (!current[key]) return current;
      const next = { ...current };
      delete next[key];
      return next;
    });
  };

  const submit = async () => {
    if (!canSubmit) return;

    setSaving(true);
    setError(null);
    setFieldErrors({});

    const payload: EmployeeClassificationTransition = {
      employment_type: form.employment_type,
      effective_date: form.effective_date,
      reason: form.reason.trim(),
      pay_rate: Number(form.pay_rate),
      pay_frequency: form.pay_frequency,
      ...(movingToW2
        ? {
            salary_type: form.salary_type,
            filing_status: form.filing_status,
          }
        : {
            contractor_type: form.contractor_type,
            contractor_pay_type: form.contractor_pay_type,
            business_name: form.business_name.trim() || undefined,
            contractor_ein: form.contractor_ein.trim() || undefined,
          }),
    };

    try {
      const response = await employeesApi.transitionTaxClassification(employee.id, payload);
      onTransitioned(response.data);
      onOpenChange(false);
    } catch (err) {
      if (err instanceof ApiError && err.details) {
        setFieldErrors(err.details);
        setError('Complete the missing filing information on the current record, then try again.');
      } else {
        setError(err instanceof Error ? err.message : 'Unable to create the new worker record');
      }
    } finally {
      setSaving(false);
    }
  };

  const fieldError = (field: string) => fieldErrors[field]?.[0];

  return (
    <Dialog open={open} onOpenChange={(nextOpen) => !saving && onOpenChange(nextOpen)}>
      <DialogContent className="max-w-2xl rounded-3xl p-0">
        <div className="border-b border-neutral-200 bg-neutral-950 px-6 py-5 text-white sm:rounded-t-3xl">
          <DialogHeader>
            <div className="mb-3 flex h-10 w-10 items-center justify-center rounded-2xl bg-white/10 ring-1 ring-white/15">
              <ShieldCheck className="h-5 w-5" />
            </div>
            <DialogTitle className="text-xl text-white">Create a new tax-classification record</DialogTitle>
            <DialogDescription className="max-w-xl text-neutral-300">
              {employee.first_name}’s existing payroll history will remain untouched. The current record closes and a linked {targetLabel} record begins on the effective date.
            </DialogDescription>
          </DialogHeader>
        </div>

        <div className="space-y-5 px-6 py-6">
          <div className="flex items-start gap-3 rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-amber-950">
            <LockKeyhole className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" />
            <p className="text-sm leading-6">
              This creates a separate filing record. It does not recalculate, move, or rewrite any prior paycheck. Resolve payroll dated on or after the effective date before continuing.
            </p>
          </div>

          {error && (
            <div className="rounded-2xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800">
              {error}
            </div>
          )}

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <label className="mb-1 block text-sm font-medium text-neutral-800">New classification</label>
              {employee.employment_type === 'contractor' ? (
                <Select
                  value={form.employment_type}
                  onChange={(event) => update('employment_type', event.target.value as EmploymentType)}
                >
                  <option value="hourly">W-2 hourly employee</option>
                  <option value="salary">W-2 salaried employee</option>
                </Select>
              ) : (
                <Input value="1099 contractor" disabled />
              )}
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-neutral-800">Effective date</label>
              <Input
                type="date"
                max={todayIsoDate()}
                value={form.effective_date}
                onChange={(event) => update('effective_date', event.target.value)}
                error={fieldError('effective_date')}
              />
            </div>
          </div>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <label className="mb-1 block text-sm font-medium text-neutral-800">
                {form.employment_type === 'salary' && form.salary_type === 'annual'
                  ? 'Annual salary'
                  : form.employment_type === 'contractor' && form.contractor_pay_type === 'flat_fee'
                    ? 'Flat fee per period'
                    : 'Hourly rate'}
              </label>
              <Input
                type="number"
                min="0"
                step="0.01"
                value={form.pay_rate}
                onChange={(event) => update('pay_rate', event.target.value)}
                error={fieldError('pay_rate')}
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-neutral-800">Pay frequency</label>
              <Select
                value={form.pay_frequency}
                onChange={(event) => update('pay_frequency', event.target.value as PayFrequency)}
              >
                <option value="weekly">Weekly</option>
                <option value="biweekly">Biweekly</option>
                <option value="semimonthly">Semimonthly</option>
                <option value="monthly">Monthly</option>
              </Select>
            </div>
          </div>

          {form.employment_type === 'salary' && (
            <div>
              <label className="mb-1 block text-sm font-medium text-neutral-800">Salary structure</label>
              <Select
                value={form.salary_type}
                onChange={(event) => update('salary_type', event.target.value as TransitionForm['salary_type'])}
              >
                <option value="annual">Fixed annual salary</option>
                <option value="per_period">Fixed per pay period</option>
                <option value="variable">Variable each pay period</option>
              </Select>
            </div>
          )}

          {movingToW2 ? (
            <div>
              <label className="mb-1 block text-sm font-medium text-neutral-800">W-4 filing status</label>
              <Select
                value={form.filing_status}
                onChange={(event) => update('filing_status', event.target.value as FilingStatus)}
              >
                <option value="single">Single</option>
                <option value="married">Married filing jointly</option>
                <option value="married_separate">Married filing separately</option>
                <option value="head_of_household">Head of household</option>
              </Select>
              <p className="mt-1 text-xs leading-5 text-neutral-500">Confirm this against the worker’s current W-4 before running payroll.</p>
            </div>
          ) : (
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div>
                <label className="mb-1 block text-sm font-medium text-neutral-800">Contractor type</label>
                <Select
                  value={form.contractor_type}
                  onChange={(event) => update('contractor_type', event.target.value as ContractorType)}
                >
                  <option value="individual">Individual</option>
                  <option value="business">Business</option>
                </Select>
              </div>
              <div>
                <label className="mb-1 block text-sm font-medium text-neutral-800">Pay structure</label>
                <Select
                  value={form.contractor_pay_type}
                  onChange={(event) => update('contractor_pay_type', event.target.value as ContractorPayType)}
                >
                  <option value="flat_fee">Flat fee per period</option>
                  <option value="hourly">Hourly rate</option>
                </Select>
              </div>
              {form.contractor_type === 'business' && (
                <>
                  <div>
                    <label className="mb-1 block text-sm font-medium text-neutral-800">Business name</label>
                    <Input value={form.business_name} onChange={(event) => update('business_name', event.target.value)} />
                  </div>
                  <div>
                    <label className="mb-1 block text-sm font-medium text-neutral-800">EIN</label>
                    <Input value={form.contractor_ein} onChange={(event) => update('contractor_ein', event.target.value)} />
                  </div>
                </>
              )}
              <p className="text-xs leading-5 text-neutral-500 sm:col-span-2">The new contractor record starts with W-9 not on file so staff must verify a new W-9 before year-end reporting.</p>
            </div>
          )}

          <div>
            <label className="mb-1 block text-sm font-medium text-neutral-800">Reason for transition</label>
            <Textarea
              value={form.reason}
              onChange={(event) => update('reason', event.target.value)}
              placeholder="Describe the confirmed business reason and effective date source."
              rows={3}
            />
            <p className="mt-1 text-xs text-neutral-500">At least 10 characters. This explanation is stored in the audit log.</p>
          </div>
        </div>

        <DialogFooter className="border-t border-neutral-200 bg-neutral-50 px-6 py-4 sm:rounded-b-3xl">
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={saving}>
            Cancel
          </Button>
          <Button type="button" onClick={submit} disabled={!canSubmit}>
            {saving ? 'Creating record...' : 'Create linked record'}
            {!saving && <ArrowRight className="ml-2 h-4 w-4" />}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
