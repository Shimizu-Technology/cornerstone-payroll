import { useEffect, useMemo, useState } from 'react';
import { CalendarClock, RotateCcw, ShieldAlert, UserMinus } from 'lucide-react';
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
import { employeesApi } from '@/services/api';
import type { Employee, EmployeeTerminationInput } from '@/types';

interface Props {
  employee: Employee;
  mode: 'terminate' | 'reactivate';
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCompleted: (employee: Employee) => void;
}

function todayIsoDate(): string {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export function EmployeeStatusTransitionDialog({ employee, mode, open, onOpenChange, onCompleted }: Props) {
  const [effectiveDate, setEffectiveDate] = useState(todayIsoDate());
  const [lastWorkedOn, setLastWorkedOn] = useState('');
  const [reasonCategory, setReasonCategory] = useState<EmployeeTerminationInput['reason_category']>();
  const [internalNotes, setInternalNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setEffectiveDate(todayIsoDate());
    setLastWorkedOn('');
    setReasonCategory(undefined);
    setInternalNotes('');
    setError(null);
  }, [open, mode]);

  const workerLabel = employee.employment_type === 'contractor' ? 'contractor' : 'employee';
  const canSubmit = useMemo(() => {
    if (!effectiveDate || saving) return false;
    if (mode === 'terminate' && lastWorkedOn && lastWorkedOn > effectiveDate) return false;
    if (mode === 'reactivate' && employee.termination_date && effectiveDate <= employee.termination_date) return false;
    return true;
  }, [effectiveDate, employee.termination_date, lastWorkedOn, mode, saving]);

  const submit = async () => {
    if (!canSubmit) return;
    setSaving(true);
    setError(null);
    try {
      const response = mode === 'terminate'
        ? await employeesApi.terminate(employee.id, {
            effective_date: effectiveDate,
            last_worked_on: lastWorkedOn || undefined,
            reason_category: reasonCategory,
            internal_notes: internalNotes.trim() || undefined,
          })
        : await employeesApi.reactivate(employee.id, {
            effective_date: effectiveDate,
            internal_notes: internalNotes.trim() || undefined,
          });
      onCompleted(response.data);
      onOpenChange(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : `Unable to ${mode} this ${workerLabel}`);
    } finally {
      setSaving(false);
    }
  };

  const isTermination = mode === 'terminate';

  return (
    <Dialog open={open} onOpenChange={(nextOpen) => !saving && onOpenChange(nextOpen)}>
      <DialogContent className="max-h-[calc(100vh-2rem)] max-w-xl overflow-y-auto rounded-3xl p-0">
        <div className={`border-b px-6 py-5 text-white sm:rounded-t-3xl ${isTermination ? 'border-rose-800 bg-rose-950' : 'border-primary-800 bg-primary-950'}`}>
          <DialogHeader>
            <div className="mb-3 flex h-10 w-10 items-center justify-center rounded-2xl bg-white/10 ring-1 ring-white/15">
              {isTermination ? <UserMinus className="h-5 w-5" /> : <RotateCcw className="h-5 w-5" />}
            </div>
            <DialogTitle className="text-xl text-white">
              {isTermination ? `Terminate ${employee.first_name}` : `Reactivate ${employee.first_name}`}
            </DialogTitle>
            <DialogDescription className="text-neutral-200">
              {isTermination
                ? 'Record when the termination actually took effect. The worker and every prior paycheck remain available for reports and audit history.'
                : 'Start a new active period for this worker. The prior termination stays in the immutable status timeline.'}
            </DialogDescription>
          </DialogHeader>
        </div>

        <div className="space-y-5 px-6 py-6">
          <div className="flex items-start gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-950">
            {isTermination ? <ShieldAlert className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" /> : <CalendarClock className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" />}
            <p>
              {isTermination
                ? 'This date controls automatic payroll eligibility. A final, correction, or adjustment run can still include the worker explicitly when needed.'
                : `The reactivation date must be after the recorded termination${employee.termination_date ? ` on ${employee.termination_date}` : ''}. It does not alter prior payroll.`}
            </p>
          </div>

          {error && <div className="rounded-2xl border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800">{error}</div>}

          <div className={`grid gap-4 ${isTermination ? 'sm:grid-cols-2' : ''}`}>
            <div>
              <label className="mb-1 block text-sm font-medium text-neutral-800">
                {isTermination ? 'Termination effective date' : 'Reactivation effective date'} <span className="text-danger-600">*</span>
              </label>
              <Input
                type="date"
                required
                min={(mode === 'reactivate' && employee.termination_date ? employee.termination_date : employee.hire_date) || undefined}
                max={todayIsoDate()}
                value={effectiveDate}
                onChange={(event) => setEffectiveDate(event.target.value)}
              />
            </div>
            {isTermination && (
              <div>
                <label className="mb-1 block text-sm font-medium text-neutral-800">Last day worked <span className="text-xs font-normal text-neutral-500">(optional)</span></label>
                <Input
                  type="date"
                  min={employee.hire_date || undefined}
                  max={effectiveDate}
                  value={lastWorkedOn}
                  onChange={(event) => setLastWorkedOn(event.target.value)}
                  error={lastWorkedOn && lastWorkedOn > effectiveDate ? 'Last day worked cannot be after termination' : undefined}
                />
              </div>
            )}
          </div>

          {isTermination && (
            <div>
              <label className="mb-1 block text-sm font-medium text-neutral-800">Reason category <span className="text-xs font-normal text-neutral-500">(optional)</span></label>
              <Select value={reasonCategory || ''} onChange={(event) => setReasonCategory((event.target.value || undefined) as EmployeeTerminationInput['reason_category'])}>
                <option value="">Not recorded</option>
                <option value="voluntary">Voluntary resignation</option>
                <option value="involuntary">Involuntary termination</option>
                <option value="layoff">Layoff</option>
                <option value="reduction_in_force">Reduction in force</option>
                <option value="end_of_contract">End of contract</option>
                <option value="retirement">Retirement</option>
                <option value="other">Other</option>
              </Select>
            </div>
          )}

          <div>
            <label className="mb-1 block text-sm font-medium text-neutral-800">Internal notes <span className="text-xs font-normal text-neutral-500">(optional, restricted)</span></label>
            <Textarea
              rows={3}
              value={internalNotes}
              onChange={(event) => setInternalNotes(event.target.value)}
              placeholder={isTermination ? 'Add context staff may need later. Avoid unnecessary sensitive detail.' : 'Add any context for this reactivation.'}
            />
            <p className="mt-1 text-xs leading-5 text-neutral-500">Only managers and organization administrators can view these notes.</p>
          </div>
        </div>

        <DialogFooter className="sticky bottom-0 z-10 border-t border-neutral-200 bg-neutral-50/95 px-6 py-4 backdrop-blur-md sm:rounded-b-3xl">
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={saving}>Cancel</Button>
          <Button type="button" variant={isTermination ? 'danger' : 'default'} onClick={submit} disabled={!canSubmit}>
            {saving ? 'Saving history...' : isTermination ? `Terminate ${workerLabel}` : `Reactivate ${workerLabel}`}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
