import { useState } from 'react';
import api from '@/services/api';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { BusyStatus } from '@/components/ui/busy-status';
import { formatCurrency } from '@/lib/utils';
import type { AddBackResult, ExpectedEntries, PayPeriod } from '@/types';
import { AddBackNotice } from './AddBackNotice';
import { addBackSummary } from './addBackText';
import type { AddBackNoticeState } from './usePayRunController';

export function ExpectedEntriesPanel({ payPeriod, disabled, onSaved, onEnterPay, onCalculate, onRestore, onUnapprove, addBackNotice = null }: {
  onUnapprove: () => void | Promise<void>;
  onRestore: (employeeId: number) => Promise<AddBackResult | undefined | void>;
  addBackNotice?: AddBackNoticeState | null;
  payPeriod: PayPeriod; disabled: boolean; onSaved: () => Promise<unknown>; onEnterPay: (id: number) => void; onCalculate: (field: ExpectedEntries['fields'][number], value: number) => Promise<unknown>;
}) {
  const [values, setValues] = useState<Record<number, string>>({});
  const [notes, setNotes] = useState<Record<string, string>>({});
  const [pending, setPending] = useState<{ key: string; message: string } | null>(null);
  const busy = pending !== null;
  const [error, setError] = useState('');
  const data = payPeriod.expected_entries;
  const approved = payPeriod.status === 'approved';
  // Saved add-backs come from the server and survive a refresh; the one just
  // made here shows too if the reload after it failed.
  const saved = data?.added_back || [];
  const fresh = addBackNotice?.source === 'expected_entries' && !saved.some(entry => entry.employee_id === addBackNotice.result.employee_id)
    ? [{ ...addBackNotice.result, hours_entered: addBackNotice.hoursEntered }] : [];
  const notices = [...saved, ...fresh];
  if (!data || payPeriod.correction_status === 'voided' || !['draft', 'calculated', 'approved'].includes(payPeriod.status) || (!data.fields.length && !data.missing_regulars.length && !notices.length)) return null;
  const act = async (key: string, message: string, action: () => Promise<unknown>, reload = true) => {
    setPending({ key, message }); setError('');
    try { await action(); if (reload) await onSaved(); } catch (err) { setError(err instanceof Error ? err.message : 'Could not save entry'); }
    finally { setPending(null); }
  };
  const restore = (employeeId: number) => void act('restore:' + employeeId, 'Adding employee back to this run…', () => onRestore(employeeId), false);
  const resolve = (employee_id: number, payroll_standing_change_id?: number, undo = false) => {
    const body = { employee_id, payroll_standing_change_id, note: notes[payroll_standing_change_id ? 'f' + payroll_standing_change_id : 'e' + employee_id] || '' };
    void act('resolve:' + (payroll_standing_change_id ? 'f' + payroll_standing_change_id : 'e' + employee_id), undo ? 'Undoing this entry…' : 'Saving this entry…', () => undo ? api.delete('/admin/pay_periods/' + payPeriod.id + '/entry_resolutions', { data: body }) : api.post('/admin/pay_periods/' + payPeriod.id + '/entry_resolutions', body));
  };
  const fill = (field: ExpectedEntries['fields'][number]) => {
    const value = Number(values[field.id]);
    if (!Number.isFinite(value) || value <= 0) { setError('Enter a value greater than zero'); return; }
    void act('calculate:' + field.id, 'Saving and calculating payroll… This can take a few seconds.', () => onCalculate(field, value), false);
  };
  // Show what came back next to where the worker's hours go, when they have a row.
  const noticeRow = (employeeId: number) => {
    const field = data.fields.find(entry => entry.employee_id === employeeId);
    if (field) return 'f' + field.id;
    return data.missing_regulars.some(row => row.employee_id === employeeId) ? 'e' + employeeId : null;
  };
  const noticesFor = (row: string) => notices.filter(notice => noticeRow(notice.employee_id) === row)
    .map(notice => <AddBackNotice key={'n' + notice.employee_id} result={notice} hoursEntered={notice.hours_entered} />);
  const announcement = addBackNotice?.source === 'expected_entries' ? addBackSummary(addBackNotice.result, addBackNotice.hoursEntered) : '';
  return <section id="expected-payroll-entries" tabIndex={-1} aria-label="Expected entries" className="space-y-3 [&_button]:max-w-full [&_button]:whitespace-normal rounded-xl border border-neutral-200 bg-white p-4">
    <h2 className="font-semibold">Expected entries</h2>
    <p className="text-sm text-neutral-600">{data.outstanding.length ? 'Resolve these entries before ' + (approved ? 'commit: ' : 'approval: ') + data.outstanding.join('; ') : 'All expected entries are resolved.'}</p>
    {approved && (data.outstanding.length > 0 || data.fields.some(field => field.status === 'missing') || data.missing_regulars.some(row => !row.resolved)) && <div className="flex flex-wrap items-center gap-2 text-sm text-neutral-600"><p>To enter pay, unapprove first.</p><Button variant="outline" disabled={disabled || busy} loading={pending?.key === 'unapprove'} loadingLabel="Unapproving…" onClick={() => void act('unapprove', 'Unapproving payroll…', async () => { await onUnapprove(); }, false)}>Unapprove to enter pay</Button></div>}
    {/* Stays mounted so the add-back result is announced when it arrives. */}
    <p aria-live="polite" aria-atomic="true" className="sr-only" data-testid="add-back-announcement">{announcement}</p>
    {notices.filter(notice => !noticeRow(notice.employee_id)).map(notice => <AddBackNotice key={'n' + notice.employee_id} result={notice} hoursEntered={notice.hours_entered} />)}
    {error && <p role="alert" className="text-danger-700">{error}</p>}
    {data.fields.map(field => <div key={field.id} className="space-y-2 border-t border-neutral-200 pt-3">
      <p className="font-medium">{field.label} · {field.status === 'filled' ? 'Filled: ' + (field.kind === 'owner_pay' ? formatCurrency(Number(field.value)) : field.value + ' h') : field.status === 'excluded' ? 'Excluded this period' : field.status === 'none' ? 'None this period' : 'Missing'}{!field.required && ' (optional)'}</p>
      {field.source_revision && <p className="text-sm text-neutral-600">From client: revision {field.source_revision}</p>}
      {field.help_text && <p className="text-sm">{field.help_text}</p>}
      {field.availability_error && <p role="alert" className="text-sm text-danger-700">Needs attention in Settings: {field.availability_error}</p>}
      {field.note && <p className="text-sm">{field.note}</p>}
      {field.inline_save_error && <p role="alert" className="text-sm text-danger-700">{field.inline_save_error}</p>}
      {noticesFor('f' + field.id)}
      {field.status === 'excluded' && !approved && <Button variant="outline" disabled={disabled || busy} loading={pending?.key === 'restore:' + field.employee_id} loadingLabel="Adding back…" onClick={() => restore(field.employee_id)}>Add back to this run</Button>}
      {field.status === 'missing' && <div className="flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-center">
        {!approved && <div className="flex min-w-0 flex-wrap items-center gap-2 [&>div]:min-w-0 [&>div]:flex-1 sm:flex-1 sm:basis-80"><Input aria-label={(field.kind === 'owner_pay' ? 'Amount: ' : 'Hours: ') + field.label} placeholder={field.kind === 'owner_pay' ? 'Amount ($)' : 'Hours'} type="number" min="0.01" step="0.01" value={values[field.id] || ''} onChange={event => setValues({ ...values, [field.id]: event.target.value })} disabled={disabled || busy || !!field.availability_error || !!field.inline_save_error} />
        <Button disabled={disabled || busy || !!field.availability_error || !!field.inline_save_error} loading={pending?.key === 'calculate:' + field.id} loadingLabel="Saving and calculating…" onClick={() => fill(field)}>Save and calculate</Button></div>}
        {field.allow_none && <div className="flex min-w-0 flex-wrap items-center gap-2 [&>div]:min-w-0 [&>div]:flex-1 sm:flex-1 sm:basis-80"><Input aria-label={'Note for ' + field.label + ' (optional)'} placeholder="Note (optional)" maxLength={500} value={notes['f' + field.id] || ''} onChange={event => setNotes({ ...notes, ['f' + field.id]: event.target.value })} /><Button variant="outline" disabled={disabled || busy} loading={pending?.key === 'resolve:f' + field.id} loadingLabel="Saving…" onClick={() => resolve(field.employee_id, field.id)}>None this period</Button></div>}
      </div>}
      {field.status === 'none' && <Button variant="outline" disabled={disabled || busy} loading={pending?.key === 'resolve:f' + field.id} loadingLabel="Undoing…" onClick={() => resolve(field.employee_id, field.id, true)}>Undo none for {field.label}</Button>}
    </div>)}
    {!!data.missing_regulars.length && <h3 className="font-semibold">Usually paid</h3>}
    {data.missing_regulars.map(row => <div key={row.employee_id} className="flex flex-col gap-3 border-t border-neutral-200 pt-3 sm:flex-row sm:flex-wrap sm:items-center">
      {/* Someone added back with import amounts is paid; staff confirm no hours, not "not paid". */}
      <div className="min-w-0 break-words sm:flex-1 sm:basis-48"><p className="font-medium">{row.label} · {row.resolved ? (row.awaiting_hours && !row.excluded ? 'No hours this period' : 'Not paid this period') : 'Missing'}</p>
      {row.note && <p className="mt-1 text-sm text-neutral-600">{row.note}</p>}</div>
      {notices.some(notice => notice.employee_id === row.employee_id) && noticeRow(row.employee_id) === 'e' + row.employee_id && <div className="basis-full">{noticesFor('e' + row.employee_id)}</div>}
      {row.excluded ? (approved ? null : <Button variant="outline" disabled={disabled || busy} loading={pending?.key === 'restore:' + row.employee_id} loadingLabel="Adding back…" onClick={() => restore(row.employee_id)}>Add back to this run</Button>) : row.resolved ? <Button variant="outline" disabled={disabled || busy} loading={pending?.key === 'resolve:e' + row.employee_id} loadingLabel="Undoing…" onClick={() => resolve(row.employee_id, undefined, true)}>{row.awaiting_hours ? 'Undo no hours for ' : 'Undo not paid for '}{row.label}</Button> : <>
        {!approved && <Button disabled={disabled || busy} onClick={() => onEnterPay(row.employee_id)}>Enter pay for {row.label}</Button>}
        <div className="flex min-w-0 flex-wrap items-center gap-2 [&>div]:min-w-0 [&>div]:flex-1 sm:flex-1 sm:basis-80"><Input aria-label={'Note for ' + row.label + ' (optional)'} placeholder="Note (optional)" maxLength={500} value={notes['e' + row.employee_id] || ''} onChange={event => setNotes({ ...notes, ['e' + row.employee_id]: event.target.value })} />
        <Button variant="outline" disabled={disabled || busy} loading={pending?.key === 'resolve:e' + row.employee_id} loadingLabel="Saving…" onClick={() => resolve(row.employee_id)}>{row.awaiting_hours ? 'No hours this period' : 'Not paid this period'}</Button></div>
      </>}
    </div>)}
    <BusyStatus busy={busy} reserveMessage="Saving and calculating payroll… This can take a few seconds.">{pending?.message || 'Saving this entry…'}</BusyStatus>
  </section>;
}
