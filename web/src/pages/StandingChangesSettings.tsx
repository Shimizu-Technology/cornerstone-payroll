import { useEffect, useRef, useState } from 'react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { FIELD_LABEL } from '@/components/ui/field-styles';
import { useCompany } from '@/contexts/CompanyContext';
import { useSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import { canWriteCompany } from '@/lib/company-write-access';
import api from '@/services/api';

type DefaultRow = { label?: string; help_text?: string; required?: boolean; allow_none?: boolean; id?: number; kind: 'owner_pay' | 'extra_hours'; employee_id: number; employee_wage_rate_id: number | null; position: number; active: boolean; availability_error?: string };
type Settings = { regular_pay_rule?: { lookback: number; threshold: number }; defaults: DefaultRow[]; employees: { id: number; name: string; status: string; variable_salary: boolean; hourly: boolean; wage_rates: { id: number; label: string; rate: string }[] }[] };
const root = '/admin/payroll_standing_changes';
const blank = (): DefaultRow => ({ kind: 'owner_pay', employee_id: 0, employee_wage_rate_id: null, position: 0, active: true, required: true });

export default function StandingChangesSettings() {
  const { activeCompany, activeCompanyId } = useCompany();
  const scope = useRef(activeCompanyId).current;
  const hasAccess = useSelectedCompanyCapability('manage_client_configuration');
  const canEdit = scope === activeCompanyId && hasAccess && canWriteCompany(activeCompany, 'manage_client_configuration');
  const [loading, setLoading] = useState(true);
  const [loadAttempt, setLoadAttempt] = useState(0);
  const [data, setData] = useState<Settings | null>(null);
  const [draft, setDraft] = useState<DefaultRow>(blank);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [rule, setRule] = useState({ lookback: 4, threshold: 3 });
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let active = true;
    setLoading(true); setError(null);
    api.get<Settings>(root).then(value => { if (active) { setData(value); if (value.regular_pay_rule) setRule(value.regular_pay_rule); } }).catch(err => { if (active) setError(err instanceof Error ? err.message : 'Could not load defaults'); }).finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [loadAttempt]);
  const save = async (row: DefaultRow) => {
    if (!canEdit || busy) return;
    if (!Number.isInteger(row.position)) { setError('Order must be a whole number.'); return; }
    setBusy(true); setError(null); setSuccess(null);
    try {
      const result = row.id ? await api.patch<Settings>(`${root}/${row.id}`, { standing_change: row }) : await api.post<Settings>(root, { standing_change: row });
      setData(result); setDraft(blank()); setSuccess('Every-period changes saved. Staff enter amounts in Expected entries on the pay run.');
    } catch (err) { setError(err instanceof Error ? err.message : 'Could not save default'); }
    finally { setBusy(false); }
  };
  return <>
    <Header title="Standing Changes" description="Default rows for this client’s pay period files" />
    <main className="mx-auto max-w-4xl space-y-5 p-4 sm:p-6">
      <h2 className="text-lg font-semibold">Changes {activeCompany?.name || 'this client'} sends every period</h2>
      <p className="text-sm text-neutral-600">Staff enter a new amount or hours on the pay run each period, or choose None this period. Saving these defaults does not change a sent revision.</p>
      {!canEdit && <p role="status" className="text-sm text-neutral-700">These defaults are read-only for your current client access.</p>}
      {error && <p role="alert" className="rounded-lg bg-danger-50 p-3 text-sm text-danger-700">{error}</p>}
      {success && <p role="status" className="rounded-lg bg-success-50 p-3 text-sm text-success-800">{success}</p>}
      {!data ? loading ? <p role="status">Loading defaults…</p> : <Button type="button" variant="outline" onClick={() => setLoadAttempt(attempt => attempt + 1)}>Try loading defaults again</Button> : <>
        <form className="space-y-3 rounded-lg border border-neutral-200 p-4" onSubmit={event => {
          event.preventDefault(); if (!canEdit || busy) return;
          if (!Number.isInteger(rule.lookback) || !Number.isInteger(rule.threshold) || rule.lookback < 1 || rule.lookback > 24 || rule.threshold < 1 || rule.threshold > rule.lookback) {
            setError('Use whole numbers: last regular runs from 1 to 24, and paid in at least from 1 up to that number.'); return;
          }
          setBusy(true); setError(null);
          void api.patch<Settings>(root + '/rule', { regular_pay_lookback: rule.lookback, regular_pay_threshold: rule.threshold })
            .then(setData).catch(err => setError(err instanceof Error ? err.message : 'Could not save rule')).finally(() => setBusy(false));
        }}>
          <h3 className="font-semibold">Missing regulars</h3>
          <p className="text-sm">Check active employees paid in at least this many recent committed regular runs.</p>
          <div className="grid gap-3 sm:grid-cols-2"><label className="block space-y-1.5"><span className={FIELD_LABEL}>Paid in at least</span><NumericInput inputMode="numeric" min={1} value={rule.threshold} restoreOnEmpty disabled={!canEdit || busy} onValueChange={threshold => setRule({ ...rule, threshold: threshold ?? rule.threshold })} /></label>
          <label className="block space-y-1.5"><span className={FIELD_LABEL}>Last regular runs</span><NumericInput inputMode="numeric" min={1} value={rule.lookback} restoreOnEmpty disabled={!canEdit || busy} onValueChange={lookback => setRule({ ...rule, lookback: lookback ?? rule.lookback })} /></label></div>
          <Button disabled={!canEdit || busy}>Save missing-regular rule</Button>
        </form>
        <ul className="space-y-3">{data.defaults.filter(row => row.active).map(row => {
          const employee = data.employees.find(item => item.id === row.employee_id);
          const rate = employee?.wage_rates.find(item => item.id === row.employee_wage_rate_id);
          return <li key={row.id} className="space-y-2 rounded-lg border border-neutral-200 p-4">
            <p className="font-medium">{row.label || (row.kind === 'owner_pay' ? 'Owner pay' : 'Extra hours')} · {employee?.name || 'Missing employee'}</p>
            {rate && <p className="text-sm">{rate.label} · ${rate.rate}/hr</p>}
            {row.availability_error && <p role="alert" className="text-sm text-danger-700">Needs attention in Settings: {row.availability_error}</p>}
            <div className="flex flex-wrap gap-2"><Button type="button" variant="outline" disabled={!canEdit || busy} onClick={() => setDraft(row)}>Edit default for {employee?.name}</Button><Button type="button" variant="outline" disabled={!canEdit || busy} onClick={() => void save({ ...row, active: false })}>Remove default for {employee?.name}</Button></div>
          </li>;
        })}</ul>
        {data.defaults.every(row => !row.active) && <p className="text-sm text-neutral-600">No every-period changes configured.</p>}
        <form className="space-y-3 rounded-lg border border-neutral-200 bg-neutral-50 p-4" onSubmit={event => { event.preventDefault(); void save(draft); }}>
          <h3 className="font-semibold">{draft.id ? 'Edit default' : 'Add an every-period change'}</h3>
          <Input label="Entry label" maxLength={200} value={draft.label || ''} onChange={event => setDraft({ ...draft, label: event.target.value })} disabled={!canEdit || busy} />
          <Input label="Help text" maxLength={1000} value={draft.help_text || ''} onChange={event => setDraft({ ...draft, help_text: event.target.value })} disabled={!canEdit || busy} />
          <label className="flex min-h-11 items-center gap-2"><input type="checkbox" checked={draft.required !== false} disabled={!canEdit || busy} onChange={event => setDraft({ ...draft, required: event.target.checked })} />Required each period</label>
          <label className="flex min-h-11 items-center gap-2"><input type="checkbox" checked={draft.allow_none !== false} disabled={!canEdit || busy} onChange={event => setDraft({ ...draft, allow_none: event.target.checked })} />Allow None this period</label>
          <fieldset disabled={!canEdit || busy} className="grid min-w-0 gap-3 sm:grid-cols-2">
            <Select label="Change" value={draft.kind} onChange={event => setDraft({ ...draft, kind: event.target.value as DefaultRow['kind'], employee_id: 0, employee_wage_rate_id: null })}><option value="owner_pay">Owner pay</option><option value="extra_hours">Extra hours</option></Select>
            <Select label="Employee" value={draft.employee_id || ''} onChange={event => { const employee = data.employees.find(row => row.id === Number(event.target.value)); setDraft({ ...draft, employee_id: Number(event.target.value), kind: employee?.hourly ? 'extra_hours' : 'owner_pay', employee_wage_rate_id: null }); }}>
              <option value="">Choose employee</option>{data.employees.filter(employee => employee.status === 'active' && (employee.variable_salary || (employee.hourly && employee.wage_rates.length > 0))).map(employee => <option key={employee.id} value={employee.id}>{employee.name}</option>)}
            </Select>
            {draft.kind === 'extra_hours' && <Select label="Saved job and rate" value={draft.employee_wage_rate_id || ''} onChange={event => setDraft({ ...draft, employee_wage_rate_id: Number(event.target.value) || null })}><option value="">Choose saved job</option>{data.employees.find(employee => employee.id === draft.employee_id)?.wage_rates.map(rate => <option key={rate.id} value={rate.id}>{rate.label} · ${rate.rate}/hr</option>)}</Select>}
            <label className="block space-y-1.5"><span className={FIELD_LABEL}>Order</span><NumericInput inputMode="numeric" min={0} value={draft.position} notifyEmptyOnChange onValueChange={position => setDraft({ ...draft, position: position ?? 0 })} /></label>
          </fieldset>
          <div className="flex flex-wrap gap-2"><Button type="submit" disabled={!canEdit || busy || !draft.employee_id || (draft.kind === 'extra_hours' && !draft.employee_wage_rate_id)}>{busy ? 'Saving…' : 'Save default'}</Button>{draft.id && <Button type="button" variant="outline" onClick={() => setDraft(blank())}>Cancel edit</Button>}</div>
        </form>
      </>}
    </main>
  </>;
}
