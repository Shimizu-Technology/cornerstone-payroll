import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router';
import { payRunPath } from '@/lib/routes';
import { CalendarClock, UserRoundX, RotateCcw, ShieldAlert, UserMinus } from 'lucide-react';
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
  mode: 'terminate' | 'reactivate' | 'deactivate';
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCompleted: (employee: Employee) => void;
  // Starting date to suggest, such as the pay period start. Never later than today.
  defaultEffectiveDate?: string;
}

function todayIsoDate(): string {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export function EmployeeStatusTransitionDialog({ employee, mode, open, onOpenChange, onCompleted, defaultEffectiveDate }: Props) {
  const initialEffectiveDate = defaultEffectiveDate && defaultEffectiveDate < todayIsoDate() ? defaultEffectiveDate : todayIsoDate();
  const [effectiveDate, setEffectiveDate] = useState(initialEffectiveDate);
  const [lastWorkedOn, setLastWorkedOn] = useState('');
  const [reasonCategory, setReasonCategory] = useState<EmployeeTerminationInput['reason_category']>();
  const [internalNotes, setInternalNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setEffectiveDate(initialEffectiveDate);
    setLastWorkedOn('');
    setReasonCategory(undefined);
    setInternalNotes('');
    setError(null);
  }, [open, mode, setError, initialEffectiveDate]);

  const [runCheck, setRunCheck] = useState<{ date: string; runs: NonNullable<Employee['open_pay_runs']> } | null>(null);
  const [runCheckError, setRunCheckError] = useState(false);
  useEffect(() => {
    if (!open || mode === 'reactivate' || !effectiveDate) return;
    let cancelled = false;
    setRunCheck(null);
    setRunCheckError(false);
    employeesApi.get(employee.id, employee.company_id, effectiveDate).then(response => {
      if (!cancelled) setRunCheck({ date: effectiveDate, runs: response.data.open_pay_runs ?? [] });
    }).catch(() => { if (!cancelled) setRunCheckError(true); });
    return () => { cancelled = true; };
  }, [open, mode, effectiveDate, employee.id, employee.company_id]);

  const latestEventDate = employee.status_history?.map(event => event.effective_date).sort().at(-1);
  const latestDate = [latestEventDate, employee.termination_date].filter((value): value is string => !!value).sort().at(-1);
  const reactivateMin = latestDate ? new Date(new Date(`${latestDate}T00:00:00Z`).getTime() + 86400000).toISOString().slice(0, 10) : employee.hire_date;
  const affectedRuns = runCheck?.date === effectiveDate ? runCheck.runs : [];
  const checkingRuns = mode !== 'reactivate' && runCheck?.date !== effectiveDate;
  const removeRuns = affectedRuns.filter(run => run.action === 'remove');
  const checkRuns = affectedRuns.filter(run => run.action === 'check');
  const approvedRun = removeRuns.find(run => run.status === 'approved');
  const workerLabel = employee.employment_type === 'contractor' ? 'contractor' : 'employee';
  const canSubmit = useMemo(() => {
    if (!effectiveDate || saving || checkingRuns || (mode !== 'reactivate' && approvedRun)) return false;
    if (mode === 'reactivate' && reactivateMin && effectiveDate < reactivateMin) return false;
    if (mode === 'terminate' && lastWorkedOn && lastWorkedOn > effectiveDate) return false;
    if (mode === 'reactivate' && employee.termination_date && effectiveDate <= employee.termination_date) return false;
    return true;
  }, [effectiveDate, employee.termination_date, lastWorkedOn, mode, saving, approvedRun, reactivateMin, checkingRuns]);

  const submit = async () => {
    if (!canSubmit) return;
    setSaving(true);
    setError(null);
    try {
      const response = mode === 'deactivate'
        ? await employeesApi.deactivate(employee.id, { effective_date: effectiveDate, reason_category: reasonCategory, internal_notes: internalNotes.trim() || undefined })
        : mode === 'terminate'
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
              {mode === 'deactivate' ? <UserRoundX className="h-5 w-5" /> : isTermination ? <UserMinus className="h-5 w-5" /> : <RotateCcw className="h-5 w-5" />}
            </div>
            <DialogTitle className="text-xl text-white">
              {mode === 'deactivate' ? `Mark ${employee.first_name} inactive` : isTermination ? `Terminate ${employee.first_name}` : `Reactivate ${employee.first_name}`}
            </DialogTitle>
            <DialogDescription className="text-neutral-200">
              {mode === 'deactivate' ? 'Inactive: not paid until reactivated. Use Terminate when employment has ended.' : isTermination
                ? 'Record when the termination actually took effect. The worker and every prior paycheck remain available for reports and audit history.'
                : employee.status === 'inactive'
                  ? 'Start a new active period for this worker. The inactive period stays in the immutable status timeline.'
                  : 'Start a new active period for this worker. The prior termination stays in the immutable status timeline.'}
            </DialogDescription>
          </DialogHeader>
        </div>

        <div className="space-y-5 px-6 py-6">
          <div className="flex items-start gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-950">
            {isTermination ? <ShieldAlert className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" /> : <CalendarClock className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" />}
            <p>
              {mode === 'deactivate' ? 'The worker is excluded from automatic payroll from this date until reactivated.' : isTermination
                ? 'This date controls automatic payroll eligibility. A final, correction, or adjustment run can still include the worker explicitly when needed.'
                : employee.termination_date
                  ? `The reactivation date must be after the recorded termination on ${employee.termination_date}. It does not alter prior payroll.`
                  : 'Use the first day they are working again. It does not alter prior payroll.'}
            </p>
          </div>

          {checkingRuns && <p role="status">{runCheckError ? 'Unable to check open pay runs. Close and reopen to retry.' : 'Checking open pay runs...'}</p>}
          {mode !== 'reactivate' && ([{ title: 'Remove from these runs', runs: removeRuns, remove: true }, { title: 'Check these runs', runs: checkRuns, remove: false }].map(group => group.runs.length > 0 && <div key={group.title} className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm">
            <p className="font-semibold">{group.title}</p>
            <ul>{group.runs.map(run => <li key={run.id}><Link className="underline" to={payRunPath(employee.company_id, run.id, 'work')}>Pay run #{run.id}: {run.start_date} – {run.end_date} ({run.status})</Link></li>)}</ul>
            {group.remove ? <>
              {approvedRun && <p role="alert">Unapprove pay run #{approvedRun.id} first</p>}
              <p>Remove {employee.first_name} from these runs before approving them. No paychecks are removed automatically.</p>
            </> : <p>{employee.first_name} stays on these runs for days worked before {effectiveDate}. Recalculate if their hours or pay changed.</p>}
          </div>))}
          {error && <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />}

          <div className={`grid gap-4 ${isTermination ? 'sm:grid-cols-2' : ''}`}>
            <div>
              <label htmlFor="employee-status-effective-date" className="mb-1 block text-sm font-medium text-neutral-800">
                {mode === 'deactivate' ? 'Inactive effective date' : isTermination ? 'Termination effective date' : 'Reactivation effective date'} <span className="text-danger-600">*</span>
              </label>
              <Input
                id="employee-status-effective-date"
                type="date"
                required
                min={(mode === 'reactivate' ? reactivateMin : employee.hire_date) || undefined}
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

          {mode !== 'reactivate' && (
            <div>
              <label className="mb-1 block text-sm font-medium text-neutral-800">Reason category <span className="text-xs font-normal text-neutral-500">(optional)</span></label>
              <Select value={reasonCategory || ''} onChange={(event) => setReasonCategory((event.target.value || undefined) as EmployeeTerminationInput['reason_category'])}>
                <option value="">Not recorded</option>
                {mode === 'deactivate' ? <>
                  <option value="leave_of_absence">Leave of absence</option>
                  <option value="seasonal">Seasonal</option>
                  <option value="no_hours_scheduled">No hours scheduled</option>
                </> : <>
                <option value="voluntary">Voluntary resignation</option>
                <option value="involuntary">Involuntary termination</option>
                <option value="layoff">Layoff</option>
                <option value="reduction_in_force">Reduction in force</option>
                <option value="end_of_contract">End of contract</option>
                <option value="retirement">Retirement</option>
                </>}
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
              placeholder={mode === 'deactivate' ? 'Add context for this inactive period.' : isTermination ? 'Add context staff may need later. Avoid unnecessary sensitive detail.' : 'Add any context for this reactivation.'}
            />
            <p className="mt-1 text-xs leading-5 text-neutral-500">Only managers and organization administrators can view these notes.</p>
          </div>
        </div>

        <DialogFooter className="sticky bottom-0 z-10 border-t border-neutral-200 bg-neutral-50/95 px-6 py-4 backdrop-blur-md sm:rounded-b-3xl">
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={saving}>Cancel</Button>
          <Button type="button" variant={isTermination ? 'danger' : 'default'} onClick={submit} disabled={!canSubmit}>
            {saving ? 'Saving history...' : mode === 'deactivate' ? 'Mark inactive' : isTermination ? `Terminate ${workerLabel}` : `Reactivate ${workerLabel}`}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
