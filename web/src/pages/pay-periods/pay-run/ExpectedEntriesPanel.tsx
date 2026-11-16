import { useState } from 'react';
import api from '@/services/api';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { formatCurrency } from '@/lib/utils';
import type { ExpectedEntries, PayPeriod } from '@/types';

export function ExpectedEntriesPanel({ payPeriod, disabled, onSaved, onEnterPay }: {
  payPeriod: PayPeriod; disabled: boolean; onSaved: () => Promise<unknown>; onEnterPay: (id: number) => void;
}) {
  const [values, setValues] = useState<Record<number, string>>({});
  const [notes, setNotes] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const data = payPeriod.expected_entries;
  if (!data || !['draft', 'calculated'].includes(payPeriod.status) || (!data.fields.length && !data.missing_regulars.length)) return null;
  const act = async (action: () => Promise<unknown>) => {
    setBusy(true); setError('');
    try { await action(); await onSaved(); } catch (err) { setError(err instanceof Error ? err.message : 'Could not save entry'); }
    finally { setBusy(false); }
  };
  const resolve = (employee_id: number, payroll_standing_change_id?: number, undo = false) => {
    const body = { employee_id, payroll_standing_change_id, note: notes[payroll_standing_change_id ? 'f' + payroll_standing_change_id : 'e' + employee_id] || '' };
    void act(() => undo ? api.delete('/admin/pay_periods/' + payPeriod.id + '/entry_resolutions', { data: body }) : api.post('/admin/pay_periods/' + payPeriod.id + '/entry_resolutions', body));
  };
  const fill = (field: ExpectedEntries['fields'][number]) => {
    const value = Number(values[field.id]);
    if (!Number.isFinite(value) || value <= 0) { setError('Enter a value greater than zero'); return; }
    void act(async () => {
      const payload = field.kind === 'owner_pay' ? { salary_overrides: { [field.employee_id]: value } } :
        { hours: { [field.employee_id]: { wage_rates: [...(field.saved_wage_rate_hours || []).filter(row => row.employee_wage_rate_id !== field.employee_wage_rate_id), { employee_wage_rate_id: field.employee_wage_rate_id, rate: Number(field.wage_rate), label: field.wage_rate_label, regular_hours: value, overtime_hours: 0, holiday_hours: 0, pto_hours: 0 }] } } };
      const result = await api.post<{ results?: { errors?: { error: string }[] } }>('/admin/pay_periods/' + payPeriod.id + '/run_payroll', { employee_ids: [field.employee_id], ...payload });
      if (result.results?.errors?.length) throw new Error(result.results.errors.map(row => row.error).join('; '));
    });
  };
  return <section aria-label="Expected entries" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4">
    <h2 className="font-semibold">Expected entries</h2>
    <p className="text-sm text-neutral-600">{data.outstanding.length ? 'Resolve these entries before approval: ' + data.outstanding.join('; ') : 'All expected entries are resolved.'}</p>
    {error && <p role="alert" className="text-danger-700">{error}</p>}
    {data.fields.map(field => <div key={field.id} className="space-y-2 border-t border-neutral-200 pt-3">
      <p className="font-medium">{field.label} · {field.status === 'filled' ? 'Filled: ' + (field.kind === 'owner_pay' ? formatCurrency(Number(field.value)) : field.value + ' h') : field.status === 'none' ? 'None this period' : 'Missing'}{!field.required && ' (optional)'}</p>
      {field.help_text && <p className="text-sm">{field.help_text}</p>}
      {field.availability_error && <p role="alert" className="text-sm text-danger-700">Needs attention: {field.availability_error}</p>}
      {field.note && <p className="text-sm">{field.note}</p>}
      {field.status === 'missing' && <div className="flex flex-wrap items-end gap-2">
        <Input label={(field.kind === 'owner_pay' ? 'Amount: ' : 'Hours: ') + field.label} type="number" min="0.01" step="0.01" value={values[field.id] || ''} onChange={event => setValues({ ...values, [field.id]: event.target.value })} disabled={disabled || busy || !!field.availability_error} />
        <Button disabled={disabled || busy || !!field.availability_error} onClick={() => fill(field)}>Save and calculate</Button>
        {field.allow_none && <><Input label={'Note for ' + field.label + ' (optional)'} maxLength={500} value={notes['f' + field.id] || ''} onChange={event => setNotes({ ...notes, ['f' + field.id]: event.target.value })} /><Button variant="outline" disabled={disabled || busy} onClick={() => resolve(field.employee_id, field.id)}>None this period</Button></>}
      </div>}
      {field.status === 'none' && <Button variant="outline" disabled={disabled || busy} onClick={() => resolve(field.employee_id, field.id, true)}>Undo none for {field.label}</Button>}
    </div>)}
    {!!data.missing_regulars.length && <h3 className="font-semibold">Usually paid</h3>}
    {data.missing_regulars.map(row => <div key={row.employee_id} className="flex flex-wrap items-end gap-2 border-t border-neutral-200 pt-3">
      <p>{row.label} · {row.resolved ? 'Not paid this period' : 'Missing'}</p>
      {row.note && <p className="text-sm">{row.note}</p>}
      {row.resolved ? <Button variant="outline" disabled={disabled || busy} onClick={() => resolve(row.employee_id, undefined, true)}>Undo not paid for {row.label}</Button> : <>
        <Button disabled={disabled || busy} onClick={() => onEnterPay(row.employee_id)}>Enter pay for {row.label}</Button>
        <Input label={'Note for ' + row.label + ' (optional)'} maxLength={500} value={notes['e' + row.employee_id] || ''} onChange={event => setNotes({ ...notes, ['e' + row.employee_id]: event.target.value })} />
        <Button variant="outline" disabled={disabled || busy} onClick={() => resolve(row.employee_id)}>Not paid this period</Button>
      </>}
    </div>)}
  </section>;
}
