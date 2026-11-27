import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactElement } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { LabeledTextarea } from '@/components/payroll-submissions/LabeledTextarea';
import { acceptStringForSlot, DEFAULT_MOSA_DESCRIPTOR } from '@/lib/importSources';
import { CHANGE_KINDS, clientPayrollSubmissionsApi, type ChangeKind, type ChangeRow, type PeriodDetail, type PickerEmployee, type SubmissionRevision } from '@/services/payrollSubmissions';
import type { PayrollIntakeFileSlot } from '@/services/api';

type DraftRow = ChangeRow & { key: string };
const blankRow = (kind: ChangeKind): DraftRow => ({ key: crypto.randomUUID(), kind, ...(kind === 'new_hire' || kind === 'wage_change' ? { wage_unit: 'hourly' } : {}) });

function rowFields(row: ChangeRow): ChangeRow {
  const { kind, employee_id, employee_ids, standing_change_id, skipped, employee_wage_rate_id, hours, amount, basis, name, starting_wage, new_wage, wage_unit, start_date, effective_date, deduction_action, description, note } = row;
  return Object.fromEntries(Object.entries({ kind, employee_id, employee_ids, standing_change_id, skipped, employee_wage_rate_id, hours, amount, basis, name, starting_wage, new_wage, wage_unit, start_date, effective_date, deduction_action, description, note })
    .filter(([, value]) => value !== undefined && value !== '')) as unknown as ChangeRow;
}

async function fileIdentity(file: File | null): Promise<unknown> {
  if (!file) return null;
  const bytes = await new Promise<ArrayBuffer>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as ArrayBuffer);
    reader.onerror = () => reject(new Error('Could not read the selected file. Choose it again.'));
    reader.readAsArrayBuffer(file);
  });
  const hash = await crypto.subtle.digest('SHA-256', new Uint8Array(bytes));
  return [file.name, file.size, Array.from(new Uint8Array(hash), byte => byte.toString(16).padStart(2, '0')).join('')];
}

function FieldError({ messages }: { messages?: string[] }): ReactElement | null {
  if (!messages?.length) return null;
  return <p role="alert" className="mt-1 text-sm text-danger-700">{messages.join(' ')}</p>;
}

export function SubmissionForm({ period, current, onSent, onCancel }: {
  period: PeriodDetail; current?: SubmissionRevision; onSent: (detail: PeriodDetail, outcome: string) => void; onCancel?: () => void;
}): ReactElement {
  const descriptor = period.intake_descriptor ?? DEFAULT_MOSA_DESCRIPTOR;
  const portalSlots = descriptor.files.filter((slot): slot is PayrollIntakeFileSlot & { portal_role: string } => Boolean(slot.portal_role));
  const linkableSlot = portalSlots.find(slot => slot.supports_link) || null;
  const linkableRole = linkableSlot?.portal_role || 'changes_workbook';
  const [employees, setEmployees] = useState<PickerEmployee[]>([]);
  const [employeeState, setEmployeeState] = useState<'loading' | 'ready' | 'error'>('loading');
  const [slotFiles, setSlotFiles] = useState<Record<string, File | null>>({});
  const [attachments, setAttachments] = useState<File[]>([]);
  const [excelSupporting, setExcelSupporting] = useState(false);
  const attachmentInput = useRef<HTMLInputElement>(null);
  const carryable = current?.documents.filter(d => d.document) || [];
  const [keep, setKeep] = useState<number[]>(carryable.map(d => d.document!.id));
  const [noChanges, setNoChanges] = useState(current?.no_changes ?? false);
  const [rows, setRows] = useState<DraftRow[]>(() => {
    const defaults = (period.standing_changes || []).filter(row => !row.availability_error);
    const previous = (current?.changes || []).filter(row => !row.availability_error);
    return [...defaults.map(row => ({ ...previous.find(item => item.standing_change_id === row.standing_change_id && item.kind === row.kind && item.employee_id === row.employee_id && item.employee_wage_rate_id === row.employee_wage_rate_id), ...row })),
      // Configured answers carry forward only through currently available fields.
      ...previous.filter(row => !row.standing_change_id)]
      .map(row => ({ ...row, skipped: row.allow_none === false ? undefined : row.skipped, key: crypto.randomUUID() }));
  });
  const [workbookChoice, setWorkbookChoice] = useState<'attach' | 'link' | 'none' | ''>(
    current?.workbook_choice || (current?.documents.some(d => d.role === linkableRole) ? 'attach' : current?.changes_link_url ? 'link' : '')
  );
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

  const setSlotFile = (portalRole: string, file: File | null): void => {
    setSlotFiles(currentFiles => ({ ...currentFiles, [portalRole]: file }));
  };
  const keptDocumentFor = (portalRole: string) => carryable.find(d => d.role === portalRole && keep.includes(d.document!.id));
  const workbook = linkableSlot ? (slotFiles[linkableRole] || null) : null;
  const hasNewWorkbook = Boolean(linkableSlot && workbookChoice === 'attach' && workbook);
  const keptWorkbook = linkableSlot ? keptDocumentFor(linkableRole) : undefined;
  const update = (key: string, patch: Partial<ChangeRow>): void => setRows(list => list.map(row => row.key === key ? { ...row, ...patch } : row));
  const employeeSelect = (row: DraftRow, label: string): ReactElement => (
    <Select label={label} value={row.employee_id ? String(row.employee_id) : ''} disabled={!!row.standing_change_id} onChange={e => update(row.key, { employee_id: e.target.value ? Number(e.target.value) : undefined, employee_wage_rate_id: undefined })}>
      <option value="">Choose employee</option>
      {employees.filter(employee => row.kind === 'owner_pay' ? employee.variable_salary !== false : row.kind === 'extra_hours' ? employee.hourly !== false : true).map(employee => <option key={employee.id} value={employee.id}>{employee.name}</option>)}
    </Select>
  );

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (busy) return;
    setError(null); setDetails({});
    for (const slot of portalSlots) {
      if (slot.supports_link) continue;
      if (slot.required && !slot.waivable && !slotFiles[slot.portal_role] && !keptDocumentFor(slot.portal_role)) {
        const message = slot.portal_role === 'revel_payroll'
          ? 'Attach the Revel payroll PDF'
          : `Attach the ${slot.portal_label || slot.label}`;
        setDetails({ [slot.portal_role]: [message] });
        return;
      }
    }
    if (linkableSlot) {
      if (!workbookChoice) { setDetails({ workbook_choice: ['Choose a workbook, a link, or no tips or loans this period'] }); return; }
      if (workbookChoice === 'attach' && !workbook && !keptWorkbook) {
        const message = linkableRole === 'changes_workbook'
          ? 'Attach the tips & loans workbook'
          : `Attach the ${linkableSlot.portal_label || linkableSlot.label}`;
        setDetails({ [linkableRole]: [message] });
        return;
      }
      if (workbookChoice === 'link') {
        try { const url = new URL(link.trim()); if (url.protocol !== 'https:' || !url.hostname || link.trim().length > 2000) throw new Error(); }
        catch { setDetails({ changes_link_url: ['Enter a full https:// link'] }); return; }
      }
    }
    if (!noChanges && !rows.some(row => !row.skipped)) { setDetails({ changes: ['List the changes this period or choose "No changes this period"'] }); return; }
    if (linkableSlot && !hasNewWorkbook && attachments.some(file => /\.xlsx?$/i.test(file.name)) && !excelSupporting) { setDetails({ attachment: ['Use the Excel file as the tips & loans workbook or confirm it is supporting material.'] }); return; }
    const sentWorkbook = linkableSlot && workbookChoice === 'attach' ? workbook : null;
    const sentLink = linkableSlot && workbookChoice === 'link' ? link.trim() : '';
    const keepIds = keep.filter(id => {
      const doc = carryable.find(d => d.document?.id === id);
      if (!doc) return false;
      if (linkableSlot && doc.role === linkableRole && (workbook || workbookChoice !== 'attach')) return false;
      if (doc.role !== linkableRole && slotFiles[doc.role]) return false;
      return true;
    });
    const changes = rows.filter(row => (!noChanges || row.standing_change_id) && (!row.standing_change_id || row.required || row.skipped || row.amount || row.hours)).map(rowFields);
    if (rows.some(row => row.standing_change_id && ((row.skipped && row.allow_none === false) || (row.required && !row.skipped && !row.amount && !row.hours)))) { setDetails({ changes: ['Complete each required payroll entry or choose None this period where allowed.'] }); return; }
    const invalid = changes.find(row => !row.skipped && ((row.kind === 'owner_pay' && (!row.employee_id || !/^\d+(\.\d{1,2})?$/.test(row.amount || '') || Number(row.amount) <= 0 || Number(row.amount) > 10_000_000)) || (row.kind === 'extra_hours' && (!row.employee_id || !row.employee_wage_rate_id || !/^\d+(\.\d{1,2})?$/.test(row.hours || '') || Number(row.hours) <= 0 || Number(row.hours) > 1000))));
    if (invalid) { setDetails({ changes: ['Choose an employee and enter a positive amount or hours, with a saved job for extra hours. Skip any every-period row you do not need.'] }); return; }
    setBusy(true);
    try {
      const slotIdentities = await Promise.all(portalSlots.map(async (slot) => [
        slot.portal_role,
        await fileIdentity(slot.supports_link ? sentWorkbook : (slotFiles[slot.portal_role] || null)),
      ]));
      const identity = JSON.stringify([slotIdentities, await Promise.all(attachments.map(fileIdentity)), keepIds, linkableSlot ? workbookChoice : null, excelSupporting, noChanges, changes, sentLink, notes, current?.revision]);
      if (retry.current?.identity !== identity) retry.current = { identity, key: crypto.randomUUID() };
      const form = new FormData();
      portalSlots.forEach((slot) => {
        const chosen = slot.supports_link ? sentWorkbook : (slotFiles[slot.portal_role] || null);
        if (chosen) form.append(slot.portal_role, chosen);
      });
      attachments.forEach(file => form.append('attachments[]', file));
      keepIds.forEach(id => form.append('keep_document_ids[]', String(id)));
      if (linkableSlot) {
        form.append('workbook_choice', workbookChoice);
        form.append('excel_attachments_supporting', String(excelSupporting));
      }
      form.append('no_changes', String(noChanges));
      form.append('changes', JSON.stringify(changes));
      if (sentLink) form.append('changes_link_url', sentLink);
      if (notes.trim()) form.append('notes', notes.trim());
      if (current) form.append('based_on_revision', String(current.revision));
      form.append('idempotency_key', retry.current.key);
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

      {portalSlots.map((slot, index) => {
        const label = slot.portal_label || slot.label;
        const hint = slot.portal_hint || slot.hint;
        const kept = keptDocumentFor(slot.portal_role);
        const chosen = slotFiles[slot.portal_role] || null;
        if (slot.supports_link) {
          return (
            <fieldset key={slot.portal_role} className="min-w-0 space-y-3">
              <legend className="text-sm font-semibold text-neutral-900">{index + 1}. {label}</legend>
              {hint && <p className="text-sm text-neutral-600">{hint}</p>}
              {(['attach', 'link', 'none'] as const).map(choice => <label key={choice} className="flex min-h-11 items-center gap-2 text-sm font-medium">
                <input type="radio" name="workbook-choice" checked={workbookChoice === choice} onChange={() => setWorkbookChoice(choice)} />
                {{ attach: 'Attach the workbook', link: 'Send a link instead', none: slot.waivable || 'No tips or loans this period' }[choice]}
              </label>)}
              <FieldError messages={details.workbook_choice} />
              {workbookChoice === 'attach' && <div className="space-y-2">
                {kept && !chosen && <p className="text-sm text-neutral-700">Keeping {kept.file_name} from revision {current?.revision}. Choose a file to replace it.</p>}
                {chosen && <p className="break-all text-sm text-neutral-700">Selected: {chosen.name}</p>}
                <input aria-label={label} type="file" accept={acceptStringForSlot(slot)} onChange={e => setSlotFile(slot.portal_role, e.target.files?.[0] || null)} className="block w-full text-sm file:mr-3 file:min-h-11 file:rounded-md file:border file:border-neutral-300 file:bg-white file:px-3 file:font-medium" />
                <FieldError messages={details[slot.portal_role]} />
              </div>}
              {workbookChoice === 'link' && <div>
                <Input label="Workbook link (https://)" type="url" value={link} onChange={e => setLink(e.target.value)} />
                <FieldError messages={details.changes_link_url} />
              </div>}
            </fieldset>
          );
        }
        return (
          <fieldset key={slot.portal_role} className="min-w-0 space-y-2">
            <legend className="text-sm font-semibold text-neutral-900">
              {index + 1}. {label}{' '}
              <span className="font-normal text-neutral-600">({slot.required && !slot.waivable ? 'required' : 'optional'})</span>
            </legend>
            {hint && <p className="text-sm text-neutral-600">{hint}</p>}
            {kept && !chosen && <p className="text-sm text-neutral-700">Keeping {kept.file_name} from revision {current?.revision}. Choose a file to replace it.</p>}
            {chosen && <p className="break-all text-sm text-neutral-700">Selected: {chosen.name}</p>}
            <input aria-label={label} type="file" accept={acceptStringForSlot(slot, true)} onChange={e => setSlotFile(slot.portal_role, e.target.files?.[0] || null)} className="block w-full text-sm file:mr-3 file:min-h-11 file:rounded-md file:border file:border-neutral-300 file:bg-white file:px-3 file:font-medium" />
            <FieldError messages={details[slot.portal_role]} />
          </fieldset>
        );
      })}

      {rows.some(row => row.standing_change_id) && <fieldset className="min-w-0 space-y-3">
        <legend className="text-sm font-semibold text-neutral-900">Payroll entries this period</legend>
        <p className="text-sm text-neutral-600">Enter this period’s pay and hours. Cornerstone reviews these before payroll.</p>
        {rows.filter(row => row.standing_change_id).map(row => <div key={row.key} className="min-w-0 space-y-2 rounded-lg border border-neutral-200 p-3">
          <p className="break-words font-semibold">{row.label || row.employee_name}{row.required ? ' (required)' : ' (optional)'}</p>
          {row.help_text && <p className="break-words text-sm text-neutral-600">{row.help_text}</p>}
          <Input label={(row.kind === 'owner_pay' ? 'Amount ($): ' : 'Hours: ') + (row.label || row.employee_name)} inputMode="decimal" aria-required={row.required} disabled={row.skipped} value={(row.kind === 'owner_pay' ? row.amount : row.hours) || ''} onChange={e => update(row.key, row.kind === 'owner_pay' ? { amount: e.target.value } : { hours: e.target.value })} />
          {row.allow_none !== false && <label className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" checked={!!row.skipped} onChange={e => update(row.key, { skipped: e.target.checked })} />None this period: {row.label || row.employee_name}</label>}
        </div>)}
      </fieldset>}
      <fieldset className="min-w-0 space-y-3">
        <legend className="text-sm font-semibold text-neutral-900">Other changes this period</legend>
        <label className="flex min-h-11 items-center gap-2 text-sm font-medium">
          <input type="checkbox" className="h-5 w-5" checked={noChanges} onChange={e => setNoChanges(e.target.checked)} />
          No changes this period
        </label>
        <p className="text-sm text-neutral-600">This choice does not change your payroll entries above.</p>
        {!noChanges && <>
          <p className="text-sm text-neutral-600">Only list what is different from the Revel report. Cornerstone reviews every change before it reaches payroll.</p>
          {employeeState === 'loading' && <p role="status" className="text-sm text-neutral-600">Loading employees…</p>}
          {employeeState === 'error' && <div role="alert" className="flex flex-col gap-2 rounded-lg border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800 sm:flex-row sm:items-center sm:justify-between">
            <span>The employee list did not load, so employees cannot be chosen yet.</span>
            <Button type="button" size="sm" variant="outline" onClick={() => void loadEmployees()}>Try again</Button>
          </div>}
          <ul className="space-y-3">
            {rows.filter(row => !row.standing_change_id).map((row, index) => {
              const meta = CHANGE_KINDS.find(k => k.kind === row.kind)!;
              return <li key={row.key} className="rounded-lg border border-neutral-200 bg-neutral-50 p-3">
                <div className="mb-2 flex items-start justify-between gap-2"><p className="font-semibold text-neutral-900">{index + 1}. {meta.label}</p>
                  {!row.standing_change_id && <Button type="button" size="sm" variant="ghost" onClick={() => setRows(list => list.filter(r => r.key !== row.key))} aria-label={`Remove change ${index + 1}, ${meta.label}`}><Trash2 className="h-4 w-4" aria-hidden /></Button>}</div>
                {row.standing_change_id && <div className="mb-3"><p className="text-xs font-semibold text-neutral-700">Every period · {row.employee_name}</p><label className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" checked={!!row.skipped} onChange={e => update(row.key, { skipped: e.target.checked })} />Not this period</label></div>}
                {row.availability_error && !row.skipped && <p role="alert" className="mb-2 text-sm text-danger-700">{row.availability_error}</p>}
                <p className="mb-2 text-xs text-neutral-600">{meta.hint}</p>
                <fieldset disabled={row.skipped} className="grid min-w-0 gap-3 sm:grid-cols-2">
                  {['owner_pay', 'extra_hours', 'paid_leave', 'wage_change', 'deduction', 'direct_deposit_addition'].includes(row.kind) && employeeSelect(row, 'Employee')}
                  {(row.kind === 'extra_hours' || row.kind === 'paid_leave') && <Input label="Hours" inputMode="decimal" value={row.hours || ''} onChange={e => update(row.key, { hours: e.target.value })} />}
                  {row.kind === 'extra_hours' && <Select label="Saved job and rate" value={row.employee_wage_rate_id || ''} disabled={!!row.standing_change_id} onChange={e => update(row.key, { employee_wage_rate_id: Number(e.target.value) || undefined })}>
                    <option value="">Choose saved job</option>
                    {employees.find(employee => employee.id === row.employee_id)?.wage_rates?.map(rate => <option key={rate.id} value={rate.id}>{rate.label} · ${rate.rate}/hr</option>)}
                  </Select>}
                  {row.kind === 'owner_pay' && <>
                    <Input label="Amount ($)" inputMode="decimal" value={row.amount || ''} onChange={e => update(row.key, { amount: e.target.value })} />
                    {row.last_period_amount && <p className="self-end py-3 text-sm text-neutral-600">Last period: {Number(row.last_period_amount).toLocaleString('en-US', { style: 'currency', currency: 'USD' })}</p>}
                    {!row.employee_id && row.basis && <p className="text-sm text-warning-800">Previous revision: ${row.amount} {row.basis}. Choose one owner and enter that person’s own amount.</p>}
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
                </fieldset>
              </li>;
            })}
          </ul>
          <div className="flex flex-col gap-2 sm:flex-row sm:items-end">
            <div className="sm:w-72"><Select label="Add a change" value={addKind} onChange={e => setAddKind(e.target.value as ChangeKind)}>{CHANGE_KINDS.map(k => <option key={k.kind} value={k.kind}>{k.label}</option>)}</Select></div>
            <Button type="button" variant="outline" onClick={() => setRows(list => [...list, blankRow(addKind)])}><Plus className="mr-1 h-4 w-4" aria-hidden />Add change</Button>
          </div>


        </>}
      </fieldset>

      <FieldError messages={changeErrors} />
      <LabeledTextarea label="Notes for Cornerstone (optional)" value={notes} onChange={e => setNotes(e.target.value)} rows={3} />
      <FieldError messages={details.notes} />

      <fieldset className="min-w-0 space-y-2">
        <legend className="text-sm font-semibold text-neutral-900">Other files <span className="font-normal text-neutral-600">(optional: new-hire documents, timesheets)</span></legend>
        {carryable.filter(d => d.role === 'attachment').map(d => (
          <label key={d.document!.id} className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" className="h-5 w-5" checked={keep.includes(d.document!.id)} onChange={e => setKeep(list => e.target.checked ? [...list, d.document!.id] : list.filter(id => id !== d.document!.id))} /><span className="break-words [overflow-wrap:anywhere]">Keep {d.file_name}</span></label>
        ))}
        <input ref={attachmentInput} aria-label="Other files" type="file" multiple onChange={e => { setAttachments(Array.from(e.target.files || [])); setExcelSupporting(false); }} className="block w-full text-sm file:mr-3 file:min-h-11 file:rounded-md file:border file:border-neutral-300 file:bg-white file:px-3 file:font-medium" />
        {linkableSlot && !hasNewWorkbook && attachments.filter(file => /\.xlsx?$/i.test(file.name)).map((file, index) => <div key={`${file.name}-${index}`} className="space-y-2 rounded-lg border border-warning-200 bg-warning-50 p-3">
          <p className="break-words text-sm font-semibold [overflow-wrap:anywhere]">{file.name}: Is this the tips &amp; loans workbook?</p>
          <Button type="button" variant="outline" className="h-auto min-h-11 max-w-full text-left" onClick={() => { setSlotFile(linkableRole, file); setWorkbookChoice('attach'); setAttachments(list => list.filter(item => item !== file)); if (attachmentInput.current) attachmentInput.current.value = '';  }}><span className="min-w-0 whitespace-normal [overflow-wrap:anywhere]">{keptWorkbook ? `Use this as the tips & loans workbook (replaces the one from revision ${current?.revision})` : 'Yes, move to workbook slot'}</span></Button>

        </div>)}
        {linkableSlot && !hasNewWorkbook && attachments.some(file => /\.xlsx?$/i.test(file.name)) && <label className="flex min-h-11 items-start gap-2 text-sm"><input type="checkbox" className="mt-1 shrink-0" checked={excelSupporting} onChange={e => setExcelSupporting(e.target.checked)} /><span className="min-w-0">These Excel files are supporting material, not the tips &amp; loans workbook</span></label>}
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
