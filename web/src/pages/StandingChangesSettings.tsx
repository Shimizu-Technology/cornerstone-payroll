import { useEffect, useRef, useState } from 'react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { Input } from '@/components/ui/input';
import { useCompany } from '@/contexts/CompanyContext';
import { useSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import { canWriteCompany } from '@/lib/company-write-access';
import api from '@/services/api';

type DefaultRow = { id?: number; kind: 'owner_pay' | 'extra_hours'; employee_id: number; employee_wage_rate_id: number | null; position: number; active: boolean; availability_error?: string };
type Settings = { defaults: DefaultRow[]; employees: { id: number; name: string; status: string; variable_salary: boolean; hourly: boolean; wage_rates: { id: number; label: string; rate: string }[] }[] };
const root = '/admin/payroll_standing_changes';
const blank = (): DefaultRow => ({ kind: 'owner_pay', employee_id: 0, employee_wage_rate_id: null, position: 0, active: true });

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
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let active = true;
    setLoading(true); setError(null);
    api.get<Settings>(root).then(value => { if (active) setData(value); }).catch(err => { if (active) setError(err instanceof Error ? err.message : 'Could not load defaults'); }).finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [loadAttempt]);
  const save = async (row: DefaultRow) => {
    if (!canEdit || busy) return;
    setBusy(true); setError(null); setSuccess(null);
    try {
      const result = row.id ? await api.patch<Settings>(`${root}/${row.id}`, { standing_change: row }) : await api.post<Settings>(root, { standing_change: row });
      setData(result); setDraft(blank()); setSuccess('Every-period changes saved. Amounts will be entered by the client each period.');
    } catch (err) { setError(err instanceof Error ? err.message : 'Could not save default'); }
    finally { setBusy(false); }
  };
  return <>
    <Header title="Standing Changes" description="Default rows for this client’s pay period files" />
    <main className="mx-auto max-w-4xl space-y-5 p-4 sm:p-6">
      <h2 className="text-lg font-semibold">Changes {activeCompany?.name || 'this client'} sends every period</h2>
      <p className="text-sm text-neutral-600">The client enters a new amount or hours each period, or chooses Not this period. Saving these defaults does not change a sent revision.</p>
      {!canEdit && <p role="status" className="text-sm text-neutral-700">These defaults are read-only for your current client access.</p>}
      {error && <p role="alert" className="rounded-lg bg-danger-50 p-3 text-sm text-danger-700">{error}</p>}
      {success && <p role="status" className="rounded-lg bg-success-50 p-3 text-sm text-success-800">{success}</p>}
      {!data ? loading ? <p role="status">Loading defaults…</p> : <Button type="button" variant="outline" onClick={() => setLoadAttempt(attempt => attempt + 1)}>Try loading defaults again</Button> : <>
        <ul className="space-y-3">{data.defaults.filter(row => row.active).map(row => {
          const employee = data.employees.find(item => item.id === row.employee_id);
          const rate = employee?.wage_rates.find(item => item.id === row.employee_wage_rate_id);
          return <li key={row.id} className="space-y-2 rounded-lg border border-neutral-200 p-4">
            <p className="font-medium">{row.kind === 'owner_pay' ? 'Owner pay' : 'Extra hours'} · {employee?.name || 'Missing employee'}</p>
            {rate && <p className="text-sm">{rate.label} · ${rate.rate}/hr</p>}
            {row.availability_error && <p role="alert" className="text-sm text-danger-700">{row.availability_error}</p>}
            <div className="flex flex-wrap gap-2"><Button type="button" variant="outline" disabled={!canEdit || busy} onClick={() => setDraft(row)}>Edit default for {employee?.name}</Button><Button type="button" variant="outline" disabled={!canEdit || busy} onClick={() => void save({ ...row, active: false })}>Remove default for {employee?.name}</Button></div>
          </li>;
        })}</ul>
        {data.defaults.every(row => !row.active) && <p className="text-sm text-neutral-600">No every-period changes configured.</p>}
        <form className="space-y-3 rounded-lg border border-neutral-200 bg-neutral-50 p-4" onSubmit={event => { event.preventDefault(); void save(draft); }}>
          <h3 className="font-semibold">{draft.id ? 'Edit default' : 'Add an every-period change'}</h3>
          <fieldset disabled={!canEdit || busy} className="grid min-w-0 gap-3 sm:grid-cols-2">
            <Select label="Change" value={draft.kind} onChange={event => setDraft({ ...draft, kind: event.target.value as DefaultRow['kind'], employee_id: 0, employee_wage_rate_id: null })}><option value="owner_pay">Owner pay</option><option value="extra_hours">Extra hours</option></Select>
            <Select label="Employee" value={draft.employee_id || ''} onChange={event => setDraft({ ...draft, employee_id: Number(event.target.value), employee_wage_rate_id: null })}>
              <option value="">Choose employee</option>{data.employees.filter(employee => employee.status === 'active' && (draft.kind === 'owner_pay' ? employee.variable_salary : employee.hourly)).map(employee => <option key={employee.id} value={employee.id}>{employee.name}</option>)}
            </Select>
            {draft.kind === 'extra_hours' && <Select label="Saved job and rate" value={draft.employee_wage_rate_id || ''} onChange={event => setDraft({ ...draft, employee_wage_rate_id: Number(event.target.value) || null })}><option value="">Choose saved job</option>{data.employees.find(employee => employee.id === draft.employee_id)?.wage_rates.map(rate => <option key={rate.id} value={rate.id}>{rate.label} · ${rate.rate}/hr</option>)}</Select>}
            <Input label="Order" type="number" min={0} value={draft.position} onChange={event => setDraft({ ...draft, position: Number(event.target.value) })} />
          </fieldset>
          <div className="flex flex-wrap gap-2"><Button type="submit" disabled={!canEdit || busy || !draft.employee_id || (draft.kind === 'extra_hours' && !draft.employee_wage_rate_id)}>{busy ? 'Saving…' : 'Save default'}</Button>{draft.id && <Button type="button" variant="outline" onClick={() => setDraft(blank())}>Cancel edit</Button>}</div>
        </form>
      </>}
    </main>
  </>;
}
