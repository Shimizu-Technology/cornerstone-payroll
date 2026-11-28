import { useState, type FormEvent } from 'react';
import { Alert } from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { formatDate, parseDay } from '@/lib/display-date';
import { clientEmployeeLifecycleApi, lifecycleErrorCode, type LifecycleEditContext } from '@/services/clientEmployeeLifecycle';
import type { Employee } from '@/types';
import { EmployeeReadinessCard } from './EmployeeReadinessCard';

const terminationReasons = [
  { value: 'voluntary', label: 'Voluntary resignation' },
  { value: 'involuntary', label: 'Involuntary termination' },
  { value: 'layoff', label: 'Layoff' },
  { value: 'reduction_in_force', label: 'Reduction in force' },
  { value: 'end_of_contract', label: 'End of contract' },
  { value: 'retirement', label: 'Retirement' },
  { value: 'other', label: 'Other' },
];

type Transition = 'terminate' | 'rehire';
type StatusUpdate = (employee: Employee) => void;

export function ClientEmployeeStatusActions({ employee, context, onSaved }: {
  employee: Employee;
  context?: LifecycleEditContext | null;
  onSaved: StatusUpdate;
}) {
  const [open, setOpen] = useState(false);
  const [result, setResult] = useState<{ message: string; warnings?: string[] }>();
  const transition = employee.status === 'active' ? 'terminate' : employee.status === 'terminated' ? 'rehire' : null;
  if (!result && (!context || context.own_record || !transition)) return null;

  return (
    <div className="space-y-3">
      {result && <Alert tone="success">{result.message}</Alert>}
      {result?.warnings?.map((message) => <Alert key={message}>{message}</Alert>)}
      {context && !context.own_record && transition && <Button type="button" variant="outline" className="min-h-11" onClick={() => setOpen(true)}>
        {transition === 'terminate' ? 'Terminate' : 'Rehire'}
      </Button>}
      {open && transition && context && <StatusDialog
        employee={employee}
        context={context}
        transition={transition}
        onClose={() => setOpen(false)}
        onSaved={(data, feedback) => {
          setResult(feedback);
          setOpen(false);
          onSaved(data);
        }}
      />}
    </div>
  );
}

function nextDate(value?: string) {
  const date = parseDay(value);
  if (!date) return '';
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString().slice(0, 10);
}

function StatusDialog({ employee, context, transition, onClose, onSaved }: {
  employee: Employee;
  context: LifecycleEditContext;
  transition: Transition;
  onClose: () => void;
  onSaved: (employee: Employee, result: { message: string; warnings?: string[] }) => void;
}) {
  const terminating = transition === 'terminate';
  const [lastWorkedOn, setLastWorkedOn] = useState(context.today);
  const [effectiveDate, setEffectiveDate] = useState('');
  const [reason, setReason] = useState('');
  const [finalPayNotes, setFinalPayNotes] = useState('');
  const [notes, setNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const minDate = terminating ? employee.hire_date || '' : nextDate(employee.termination_date);
  const date = effectiveDate || (terminating ? lastWorkedOn : context.today);
  const label = terminating ? 'Terminate' : 'Rehire';
  const name = `${employee.first_name} ${employee.last_name}`;
  const needsReapproval = terminating && context.approved_runs.some((run) => run.start_date < date && date <= run.end_date);
  const needsUnapproval = terminating && context.approved_runs.some((run) => date <= run.start_date);
  const paidAfterTermination = terminating && context.last_committed_period_end && date < context.last_committed_period_end;
  const validDate = Boolean(parseDay(date)) && date <= context.today && date >= minDate;
  const valid = validDate && (!terminating || (Boolean(lastWorkedOn && reason) && lastWorkedOn <= date));

  async function confirm(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving || !valid) return;
    setError('');
    setSaving(true);
    try {
      const response = terminating
        ? await clientEmployeeLifecycleApi.terminate(employee.id, {
          effective_date: date, last_worked_on: lastWorkedOn, reason_category: reason,
          final_pay_notes: finalPayNotes.trim() || undefined, notes: notes.trim() || undefined,
        })
        : await clientEmployeeLifecycleApi.rehire(employee.id, { effective_date: date, notes: notes.trim() || undefined });
      onSaved(response.data, response);
    } catch (caught) {
      setError(lifecycleErrorCode(caught) === 'lifecycle_mode_changed'
        ? 'Your company’s employee settings changed. Reload the page before trying again.'
        : caught instanceof Error ? caught.message : 'Could not save the change. Try again.');
      setSaving(false);
    }
  }

  return (
    <Dialog open onOpenChange={(next) => { if (!next && !saving) onClose(); }}>
      <DialogContent>
        <DialogHeader className="text-left">
          <DialogTitle>{label} {name}</DialogTitle>
          <DialogDescription>{terminating ? 'Record the employee’s last day and any final pay details.' : 'Choose the date this employee returned to work.'}</DialogDescription>
        </DialogHeader>
        <form onSubmit={confirm} className="mt-4 min-w-0 space-y-4">
          {terminating && <Input label="Last day worked" type="date" value={lastWorkedOn} max={context.today} required onChange={(event) => setLastWorkedOn(event.target.value)} />}
          <Input
            label={terminating ? 'Termination date' : 'Rehire date'}
            type="date"
            value={date}
            min={(terminating && lastWorkedOn > minDate ? lastWorkedOn : minDate) || undefined}
            max={context.today}
            required
            onChange={(event) => setEffectiveDate(event.target.value)}
          />
          {!validDate && <p className="text-sm text-danger-700">
            {minDate > context.today ? 'The rehire date must be after the termination date and cannot be in the future.' : 'Choose a date within the allowed range.'}
          </p>}
          {terminating && <>
            <Select label="Reason" value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Select a reason" options={terminationReasons} required />
            <label className="block text-sm font-medium">Final pay and unused PTO payout (optional)
              <Textarea className="mt-1 min-h-20 text-base" value={finalPayNotes} maxLength={2000} onChange={(event) => setFinalPayNotes(event.target.value)} />
            </label>
          </>}
          <label className="block text-sm font-medium">Additional note (optional)
            <Textarea className="mt-1 min-h-20 text-base" value={notes} maxLength={2000} onChange={(event) => setNotes(event.target.value)} />
          </label>
          {terminating && date && <p className="text-sm text-neutral-700">
            {name} remains eligible for final pay for work through {formatDate(date)}. Regular payroll excludes them after that date.
            Existing employee app access becomes read-only for {context.former_access_years} {context.former_access_years === 1 ? 'year' : 'years'} from termination.
          </p>}
          {paidAfterTermination && <Alert>Payroll was already finalized for a period ending after this date. Cornerstone will review the payment for a possible correction.</Alert>}
          {needsReapproval && <Alert>This date falls within an approved payroll. Cornerstone will reopen and recalculate it, then ask you to approve the updated payroll again.</Alert>}
          {needsUnapproval && <Alert>Cornerstone needs to reopen an approved payroll before you can save this termination date.</Alert>}
          {!terminating && context.rehire_readiness && <EmployeeReadinessCard readiness={context.rehire_readiness} preview />}
          {error && <Alert tone="error">{error}</Alert>}
          <DialogFooter className="gap-2">
            <Button type="button" variant="outline" className="min-h-11" onClick={onClose} disabled={saving}>Cancel</Button>
            <Button type="submit" variant={terminating ? 'danger' : 'default'} className="min-h-11" disabled={saving || !valid || needsUnapproval}>
              {saving ? 'Saving…' : label}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
