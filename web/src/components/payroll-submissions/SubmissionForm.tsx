import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactElement } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { LabeledTextarea } from '@/components/payroll-submissions/LabeledTextarea';
import { CHANGE_KINDS, clientPayrollSubmissionsApi, type ChangeKind, type ChangeRow, type PeriodDetail, type PickerEmployee, type SubmissionRevision } from '@/services/payrollSubmissions';

type DraftRow = ChangeRow & { key: string };
const blankRow = (kind: ChangeKind): DraftRow => ({ key: crypto.randomUUID(), kind, ...(kind === 'owner_pay' ? { basis: undefined, employee_ids: [] } : {}), ...(kind === 'new_hire' || kind === 'wage_change' ? { wage_unit: 'hourly' } : {}) });

function rowFields(row: ChangeRow): ChangeRow {
  const { kind, employee_id, employee_ids, hours, amount, basis, name, starting_wage, new_wage, wage_unit, start_date, effective_date, deduction_action, description, note } = row;
  return Object.fromEntries(Object.entries({ kind, employee_id, employee_ids, hours, amount, basis, name, starting_wage, new_wage, wage_unit, start_date, effective_date, deduction_action, description, note })
    .filter(([, value]) => value !== undefined && value !== '')) as unknown as ChangeRow;
}

function FieldError({ messages }: { messages?: string[] }): ReactElement | null {
  if (!messages?.length) return null;
  return <p role="alert" className="mt-1 text-sm text-danger-700">{messages.join(' ')}</p>;
}

export function SubmissionForm({ period, current, onSent, onCancel }: {
  period: PeriodDetail; current?: SubmissionRevision; onSent: (detail: PeriodDetail, outcome: string) => void; onCancel?: () => void;
}): ReactElement {
  const [employees, setEmployees] = useState<PickerEmployee[]>([]);
  const [employeeState, setEmployeeState] = useState<'loading' | 'ready' | 'error'>('loading');
  const [revel, setRevel] = useState<File | null>(null);
  const [workbook, setWorkbook] = useState<File | null>(null);
  const [attachments, setAttachments] = useState<File[]>([]);
  const carryable = current?.documents.filter(d => d.document) || [];
  const [keep, setKeep] = useState<number[]>(carryable.map(d => d.document!.id));
  const [noChanges, setNoChanges] = useState(current?.no_changes ?? false);
  const [rows, setRows] = useState<DraftRow[]>((current?.changes || []).map(row => ({ ...row, key: crypto.randomUUID() })));
  const [workbookChoice, setWorkbookChoice] = useState<'attach' | 'link' | 'none' | ''>(current?.workbook_choice || (current?.documents.some(d => d.role === 'changes_workbook') ? 'attach' : current?.changes_link_url ? 'link' : ''));
  const [link, setLink] = useState(current?.changes_link_url || '');
  const [notes, setNotes] = useState(current?.notes || '');
  const [addKind, setAddKind] = useState<ChangeKind>('extra_hours');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [details, setDetails] = useState<Record<string, string[]>>({});
  const retry = useRef<{ identity: string; key: string } | null>(null);

  const loadEmployees = useCallback(async (): Promise<void> => {
    setEmployeeState('loading');
    try {
      setEmployees(await clientPayrollSubmissionsApi.employees());
      setEmployeeState('ready');
    } catch {
      setEmployeeState('error');
    }
  }, []);
  useEffect(() => { void loadEmployees(); }, [loadEmployees]);

  const keptRevel = carryable.find(d => d.role === 'revel_payroll' && keep.includes(d.document!.id));
  const keptWorkbook = carryable.find(d => d.role === 'changes_workbook' && keep.includes(d.document!.id));
  const update = (key: string, patch: Partial<ChangeRow>): void => setRows(list => list.map(row => row.key === key ? { ...row, ...patch } : row));
  const employeeSelect = (row: DraftRow, label: string): ReactElement => (
    <Select label={label} value={row.employee_id ? String(row.employee_id) : ''} onChange={e => update(row.key, { employee_id: e.target.value ? Number(e.target.value) : undefined })}>
      <option value="">Choose employee</option>
      {employees.map(employee => <option key={employee.id} value={employee.id}>{employee.name}</option>)}
    </Select>
  );

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    setError(null); setDetails({});
    if (!revel && !keptRevel) { setDetails({ revel_payroll: ['Attach the Revel payroll PDF'] }); return; }
    if (!workbookChoice) { setDetails({ workbook_choice: ['Choose a workbook, a link, or no tips or loans this period'] }); return; }
    if (workbookChoice === 'attach' && !workbook && !keptWorkbook) { setDetails({ changes_workbook: ['Attach the tips & loans workbook'] }); return; }
    if (workbookChoice === 'link') {
      try { const url = new URL(link.trim()); if (url.protocol !== 'https:' || !url.hostname || link.trim().length > 2000) throw new Error(); }
      catch { setDetails({ changes_link_url: ['Enter a full https:// link'] }); return; }
    }
    const sentWorkbook = workbookChoice === 'attach' ? workbook : null;
    const sentLink = workbookChoice === 'link' ? link.trim() : '';
    const keepIds = keep.filter(id => {
      const doc = carryable.find(d => d.document?.id === id);
      if (!doc) return false;
      if (doc.role === 'revel_payroll' && revel) return false;
      if (doc.role === 'changes_workbook' && (workbook || workbookChoice !== 'attach')) return false;
      return true;
    });
    const changes = noChanges ? [] : rows.map(rowFields);
    const identity = JSON.stringify([revel?.name, revel?.size, revel?.lastModified, sentWorkbook?.name, sentWorkbook?.size, attachments.map(f => [f.name, f.size, f.lastModified]), keepIds, workbookChoice, noChanges, changes, sentLink, notes, current?.revision]);
    if (retry.current?.identity !== identity) retry.current = { identity, key: crypto.randomUUID() };
    const form = new FormData();
    if (revel) form.append('revel_payroll', revel);
    if (sentWorkbook) form.append('changes_workbook', sentWorkbook);
    attachments.forEach(file => form.append('attachments[]', file));
    keepIds.forEach(id => form.append('keep_document_ids[]', String(id)));
    form.append('workbook_choice', workbookChoice);
    form.append('no_changes', String(noChanges));
    form.append('changes', JSON.stringify(changes));
    if (sentLink) form.append('changes_link_url', sentLink);
    if (notes.trim()) form.append('notes', notes.trim());
    if (current) form.append('based_on_revision', String(current.revision));
    form.append('idempotency_key', retry.current.key);
    setBusy(true);
    try {
      const response = await clientPayrollSubmissionsApi.submit(period.ref, form);
      retry.current = null;
      onSent(response.data, response.outcome);
    } catch (err) {
      const data = (err as { data?: { details?: Record<string, string[]> } }).data;
      setDetails(data?.details || {});
      setError(err instanceof Error ? err.message : 'Your files were not sent. Try again.');
    } finally { setBusy(false); }
  };

  const changeErrors = Object.entries(details).filter(([key]) => key.startsWith('changes')).flatMap(([, messages]) => messages);
  return (
    <form onSubmit={submit} className="space-y-5" aria-labelledby="send-files-title" noValidate>
      <h3 id="send-files-title" className="text-lg font-semibold text-neutral-950">{current ? `Send an update (becomes revision ${current.revision + 1})` : 'Send this period’s payroll files'}</h3>
      {current && <p className="text-sm text-neutral-700">Your update is saved as a new revision. Revision {current.revision} stays on this page, marked superseded.</p>}

      <fieldset className="space-y-2">
        <legend className="text-sm font-semibold text-neutral-900">1. Revel hours report (PDF) <span className="font-normal text-neutral-600">(required)</span></legend>
        <p className="text-sm text-neutral-600">Hours worked, including overtime, from Revel.</p>
        {keptRevel && !revel && <p className="text-sm text-neutral-700">Keeping {keptRevel.file_name} from revision {current?.revision}. Choose a file to replace it.</p>}
        <input aria-label="Revel hours report (PDF)" type="file" accept="application/pdf,.pdf" onChange={e => setRevel(e.target.files?.[0] || null)} className="block w-full text-sm file:mr-3 file:min-h-11 file:rounded-md file:border file:border-neutral-300 file:bg-white file:px-3 file:font-medium" />
        <FieldError messages={details.revel_payroll} />
      </fieldset>

      <fieldset className="space-y-3">
        <legend className="text-sm font-semibold text-neutral-900">2. Tips &amp; loans workbook (Excel)</legend>
        <p className="text-sm text-neutral-600">Tips to report and loan deductions for this payroll.</p>
        {(['attach', 'link', 'none'] as const).map(choice => <label key={choice} className="flex min-h-11 items-center gap-2 text-sm font-medium">
          <input type="radio" name="workbook-choice" checked={workbookChoice === choice} onChange={() => setWorkbookChoice(choice)} />
          {{ attach: 'Attach the workbook', link: 'Send a link instead', none: 'No tips or loans this period' }[choice]}
        </label>)}
        <FieldError messages={details.workbook_choice} />
        {workbookChoice === 'attach' && <div className="space-y-2">
          {keptWorkbook && !workbook && <p className="text-sm text-neutral-700">Keeping {keptWorkbook.file_name} from revision {current?.revision}. Choose a file to replace it.</p>}
          {workbook && <p className="break-all text-sm text-neutral-700">Selected: {workbook.name}</p>}
          <input aria-label="Tips & loans workbook (Excel)" type="file" accept=".xlsx,.xls" onChange={e => setWorkbook(e.target.files?.[0] || null)} className="block w-full text-sm file:mr-3 file:min-h-11 file:rounded-md file:border file:border-neutral-300 file:bg-white file:px-3 file:font-medium" />
          <FieldError messages={details.changes_workbook} />
        </div>}
        {workbookChoice === 'link' && <div>
          <Input label="Workbook link (https://)" type="url" value={link} onChange={e => setLink(e.target.value)} />
          <FieldError messages={details.changes_link_url} />
        </div>}
      </fieldset>

      <fieldset className="space-y-3">
        <legend className="text-sm font-semibold text-neutral-900">Changes this period</legend>
        <label className="flex min-h-11 items-center gap-2 text-sm font-medium">
          <input type="checkbox" className="h-5 w-5" checked={noChanges} onChange={e => setNoChanges(e.target.checked)} />
          No changes this period
        </label>
        {!noChanges && <>
          <p className="text-sm text-neutral-600">Only list what is different from the Revel report. Cornerstone reviews every change before it reaches payroll.</p>
          {employeeState === 'loading' && <p role="status" className="text-sm text-neutral-600">Loading employees…</p>}
          {employeeState === 'error' && <div role="alert" className="flex flex-col gap-2 rounded-lg border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800 sm:flex-row sm:items-center sm:justify-between">
            <span>The employee list did not load, so employees cannot be chosen yet.</span>
            <Button type="button" size="sm" variant="outline" onClick={() => void loadEmployees()}>Try again</Button>
          </div>}
          <ul className="space-y-3">
            {rows.map((row, index) => {
              const meta = CHANGE_KINDS.find(k => k.kind === row.kind)!;
              return <li key={row.key} className="rounded-lg border border-neutral-200 bg-neutral-50 p-3">
                <div className="mb-2 flex items-start justify-between gap-2"><p className="font-semibold text-neutral-900">{index + 1}. {meta.label}</p>
                  <Button type="button" size="sm" variant="ghost" onClick={() => setRows(list => list.filter(r => r.key !== row.key))} aria-label={`Remove change ${index + 1}, ${meta.label}`}><Trash2 className="h-4 w-4" aria-hidden /></Button></div>
                <p className="mb-2 text-xs text-neutral-600">{meta.hint}</p>
                <div className="grid gap-3 sm:grid-cols-2">
                  {['extra_hours', 'paid_leave', 'wage_change', 'deduction', 'direct_deposit_addition'].includes(row.kind) && employeeSelect(row, 'Employee')}
                  {(row.kind === 'extra_hours' || row.kind === 'paid_leave') && <Input label="Hours" inputMode="decimal" value={row.hours || ''} onChange={e => update(row.key, { hours: e.target.value })} />}
                  {row.kind === 'owner_pay' && <>
                    <Input label="Amount ($)" inputMode="decimal" value={row.amount || ''} onChange={e => update(row.key, { amount: e.target.value })} />
                    <fieldset className="text-sm"><legend className="text-xs font-medium text-neutral-600">This amount is</legend>
                      <div className="mt-1 flex gap-4">{(['total', 'each'] as const).map(basis => <label key={basis} className="flex min-h-11 items-center gap-2"><input type="radio" name={`basis-${row.key}`} checked={row.basis === basis} onChange={() => update(row.key, { basis })} />{basis === 'total' ? 'Total for all owners' : 'For each owner'}</label>)}</div>
                    </fieldset>
                  </>}
                  {row.kind === 'new_hire' && <>
                    <Input label="Name" value={row.name || ''} onChange={e => update(row.key, { name: e.target.value })} />
                    <Input label="Starting wage ($)" inputMode="decimal" value={row.starting_wage || ''} onChange={e => update(row.key, { starting_wage: e.target.value })} />
                    <Select label="Wage type" value={row.wage_unit || 'hourly'} onChange={e => update(row.key, { wage_unit: e.target.value as 'hourly' | 'salary' })}><option value="hourly">Hourly</option><option value="salary">Salary</option></Select>
                    <Input label="Start date (optional)" type="date" value={row.start_date || ''} onChange={e => update(row.key, { start_date: e.target.value })} />
                  </>}
                  {row.kind === 'wage_change' && <>
                    <Input label="New wage ($)" inputMode="decimal" value={row.new_wage || ''} onChange={e => update(row.key, { new_wage: e.target.value })} />
                    <Select label="Wage type" value={row.wage_unit || 'hourly'} onChange={e => update(row.key, { wage_unit: e.target.value as 'hourly' | 'salary' })}><option value="hourly">Hourly</option><option value="salary">Salary</option></Select>
                    <Input label="Effective date (optional)" type="date" value={row.effective_date || ''} onChange={e => update(row.key, { effective_date: e.target.value })} />
                  </>}
                  {row.kind === 'deduction' && <>
                    <Select label="Action" value={row.deduction_action || ''} onChange={e => update(row.key, { deduction_action: (e.target.value || undefined) as ChangeRow['deduction_action'] })}><option value="">Choose</option><option value="start">Start</option><option value="continue">Continue</option><option value="stop">Stop</option></Select>
                    <Input label="Deduction" placeholder="e.g. Auto insurance" value={row.description || ''} onChange={e => update(row.key, { description: e.target.value })} />
                    <Input label="Amount per paycheck ($, optional)" inputMode="decimal" value={row.amount || ''} onChange={e => update(row.key, { amount: e.target.value })} />
                  </>}
                  <div className="sm:col-span-2"><Input label="Note (optional)" value={row.note || ''} onChange={e => update(row.key, { note: e.target.value })} /></div>
                </div>
                <FieldError messages={details[`changes.${index + 1}`]} />
              </li>;
            })}
          </ul>
          <div className="flex flex-col gap-2 sm:flex-row sm:items-end">
            <div className="sm:w-72"><Select label="Add a change" value={addKind} onChange={e => setAddKind(e.target.value as ChangeKind)}>{CHANGE_KINDS.map(k => <option key={k.kind} value={k.kind}>{k.label}</option>)}</Select></div>
            <Button type="button" variant="outline" onClick={() => setRows(list => [...list, blankRow(addKind)])}><Plus className="mr-1 h-4 w-4" aria-hidden />Add change</Button>
          </div>
          {changeErrors.length > 0 && !Object.keys(details).some(key => key.startsWith('changes.')) && <FieldError messages={changeErrors} />}

        </>}
      </fieldset>

      <LabeledTextarea label="Notes for Cornerstone (optional)" value={notes} onChange={e => setNotes(e.target.value)} rows={3} />
      <FieldError messages={details.notes} />

      <fieldset className="space-y-2">
        <legend className="text-sm font-semibold text-neutral-900">Other files <span className="font-normal text-neutral-600">(optional: new-hire documents, timesheets)</span></legend>
        {carryable.filter(d => d.role === 'attachment').map(d => (
          <label key={d.document!.id} className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" className="h-5 w-5" checked={keep.includes(d.document!.id)} onChange={e => setKeep(list => e.target.checked ? [...list, d.document!.id] : list.filter(id => id !== d.document!.id))} /><span className="break-words [overflow-wrap:anywhere]">Keep {d.file_name}</span></label>
        ))}
        <input aria-label="Other files" type="file" multiple onChange={e => setAttachments(Array.from(e.target.files || []))} className="block w-full text-sm file:mr-3 file:min-h-11 file:rounded-md file:border file:border-neutral-300 file:bg-white file:px-3 file:font-medium" />
        {!workbook && !keptWorkbook && !(workbookChoice === 'link' && link.trim()) && attachments.filter(file => /\.xlsx?$/i.test(file.name)).map((file, index) => <div key={`${file.name}-${index}`} className="space-y-2 rounded-lg border border-warning-200 bg-warning-50 p-3">
          <p className="break-all text-sm font-semibold">{file.name}: Is this the tips &amp; loans workbook?</p>
          <Button type="button" variant="outline" onClick={() => { setWorkbook(file); setWorkbookChoice('attach'); setAttachments(list => list.filter(item => item !== file)); }}>Yes, move to workbook slot</Button>
          <p className="text-sm">If it is another file, choose a workbook option above before sending.</p>
        </div>)}
        {attachments.length > 0 && <ul className="text-sm text-neutral-700">{attachments.map((file, index) => <li className="break-all" key={`${file.name}-${index}`}>{file.name}</li>)}</ul>}
        <FieldError messages={[...(details.attachment || []), ...(details.files || []), ...(details.keep_document_ids || [])]} />
      </fieldset>

      {error && <p role="alert" className="rounded-lg border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800">{error}</p>}
      <div className="flex flex-col gap-2 sm:flex-row">
        <Button type="submit" disabled={busy}>{busy ? 'Sending…' : current ? 'Send update' : 'Send to Cornerstone'}</Button>
        {onCancel && <Button type="button" variant="outline" onClick={onCancel} disabled={busy}>Cancel</Button>}
      </div>
    </form>
  );
}
