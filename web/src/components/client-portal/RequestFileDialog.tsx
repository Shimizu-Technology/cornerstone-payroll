import { useEffect, useMemo, useRef, useState, type FormEvent, type ReactElement } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { LabeledTextarea } from '@/components/payroll-submissions/LabeledTextarea';
import { adminPortalFileRequestsApi, type ClientPortalThread } from '@/services/api';
import { adminPayrollSubmissionsApi, type PeriodSummary, type PickerEmployee } from '@/services/payrollSubmissions';
import { CATEGORY_LABELS } from './portalFiles';

const REQUEST_CATEGORIES = ['payroll_source', 'employee_onboarding', 'tax_notice', 'direct_deposit', 'identity', 'insurance', 'misc'];
const EMPTY = { title: '', category: 'payroll_source', employeeId: '', periodRef: '', dueOn: '', body: '' };

// Staff ask the client for one specific file. With a pay period, the request
// goes in that period's conversation so it stays with the payroll it affects.
export function RequestFileDialog({ open, onOpenChange, threadId, threadSubject, onCreated }: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  threadId: number | null;
  threadSubject?: string | null;
  onCreated: (thread: ClientPortalThread) => void;
}): ReactElement {
  const [form, setForm] = useState(EMPTY);
  const [employeeSearch, setEmployeeSearch] = useState('');
  const [employees, setEmployees] = useState<PickerEmployee[] | null>(null);
  const [periods, setPeriods] = useState<PeriodSummary[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [loadAttempt, setLoadAttempt] = useState(0);
  const retry = useRef<{ identity: string; key: string } | null>(null);

  useEffect(() => {
    if (!open) return;
    let active = true;
    setLoadError(null);
    Promise.all([adminPayrollSubmissionsApi.employees(), adminPayrollSubmissionsApi.list()])
      .then(([people, periodList]) => { if (active) { setEmployees(people); setPeriods(periodList.data); } })
      .catch(() => { if (active) setLoadError('Could not load employees and pay periods. You can still send the request, or try again.'); });
    return () => { active = false; };
  }, [open, loadAttempt]);

  const shownEmployees = useMemo(() => {
    const term = employeeSearch.trim().toLowerCase();
    const list = employees ?? [];
    const matches = term ? list.filter(employee => employee.name.toLowerCase().includes(term)) : list;
    const selected = list.find(employee => String(employee.id) === form.employeeId);
    return selected && !matches.includes(selected) ? [selected, ...matches] : matches;
  }, [employees, employeeSearch, form.employeeId]);

  const set = (field: keyof typeof EMPTY, value: string): void => setForm(current => ({ ...current, [field]: value }));

  const submit = async (event: FormEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault();
    if (!form.title.trim()) { setError('Say which file you need.'); return; }
    const payload = {
      title: form.title.trim(), category: form.category,
      employee_id: form.employeeId ? Number(form.employeeId) : undefined,
      payroll_submission_period_ref: form.periodRef || undefined,
      due_on: form.dueOn || undefined, body: form.body.trim() || undefined,
      thread_id: form.periodRef ? undefined : threadId ?? undefined,
    };
    const identity = JSON.stringify(payload);
    if (retry.current?.identity !== identity) retry.current = { identity, key: crypto.randomUUID() };
    setBusy(true); setError(null);
    try {
      const response = await adminPortalFileRequestsApi.create({ ...payload, idempotency_key: retry.current.key });
      retry.current = null;
      setForm(EMPTY); setEmployeeSearch('');
      onOpenChange(false);
      window.dispatchEvent(new Event('portal-work-changed'));
      onCreated(response.thread);
    } catch (err) {
      setError(`${err instanceof Error ? err.message : 'The request was not sent.'} Your details are kept, so you can try again.`);
    } finally { setBusy(false); }
  };

  const destination = form.periodRef
    ? 'It will go in that pay period’s conversation.'
    : threadId ? `It will go in “${threadSubject || 'this conversation'}”.` : 'It will start a new conversation.';

  return (
    // While a request is being created the dialog stays open, so its retry
    // key survives a lost response and a resend cannot make a duplicate.
    <Dialog open={open} onOpenChange={next => { if (!busy) onOpenChange(next); }}>
      <DialogContent className="max-h-[min(90vh,90dvh)] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Request a file</DialogTitle>
          <DialogDescription>The client sees the request, uploads the file in it, and you accept it or ask again. {destination}</DialogDescription>
        </DialogHeader>
        <form onSubmit={event => void submit(event)} className="space-y-4">
          <Input label="File needed" value={form.title} onChange={event => set('title', event.target.value)} maxLength={200} placeholder="For example: Riley’s paper timesheet" required />
          <label className="block text-xs font-medium text-neutral-600">Type of file
            <Select value={form.category} onChange={event => set('category', event.target.value)}>
              {REQUEST_CATEGORIES.map(category => <option key={category} value={category}>{CATEGORY_LABELS[category]}</option>)}
            </Select>
          </label>
          <fieldset className="space-y-2">
            <legend className="text-xs font-medium text-neutral-600">Employee (optional)</legend>
            <Input label="Find an employee" type="search" value={employeeSearch} onChange={event => setEmployeeSearch(event.target.value)} placeholder="Type a name" />
            <Select aria-label="Employee" value={form.employeeId} onChange={event => set('employeeId', event.target.value)} disabled={!employees}>
              <option value="">{employees ? 'No specific employee' : 'Loading employees…'}</option>
              {shownEmployees.map(employee => <option key={employee.id} value={employee.id}>{employee.name}</option>)}
            </Select>
          </fieldset>
          <label className="block text-xs font-medium text-neutral-600">Pay period (optional)
            <Select value={form.periodRef} onChange={event => set('periodRef', event.target.value)} disabled={!periods}>
              <option value="">{periods ? 'Not tied to a pay period' : 'Loading pay periods…'}</option>
              {(periods ?? []).map(period => <option key={period.ref} value={period.ref}>{period.label} · {period.status_label}</option>)}
            </Select>
          </label>
          <Input label="Needed by (optional)" type="date" value={form.dueOn} onChange={event => set('dueOn', event.target.value)} />
          <LabeledTextarea label="Message to the client (optional)" rows={3} maxLength={5000} value={form.body} onChange={event => set('body', event.target.value)} />
          {loadError && <div role="alert" className="flex flex-wrap items-center gap-2 text-sm text-danger-700"><span>{loadError}</span><Button type="button" size="sm" variant="outline" onClick={() => setLoadAttempt(value => value + 1)}>Try again</Button></div>}
          {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
          <DialogFooter>
            <Button type="button" variant="outline" disabled={busy} onClick={() => onOpenChange(false)}>Cancel</Button>
            <Button type="submit" disabled={busy}>{busy ? 'Sending…' : 'Send request'}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
