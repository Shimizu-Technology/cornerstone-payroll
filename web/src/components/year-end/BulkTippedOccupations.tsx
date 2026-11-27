import { useState } from 'react';
import { TippedOccupationCodeSelect } from '@/components/employees/TippedOccupationCodeSelect';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import type { YearEndWarning } from '@/lib/year-end';
import { tippedOccupationsApi } from '@/services/api';
import { useStillMounted } from './useStillMounted';

export function BulkTippedOccupations({ companyId, year, employees, onSaved }: {
  companyId: number;
  year: number;
  employees: YearEndWarning['employees'];
  onSaved: (message: string) => Promise<void>;
}) {
  const [codes, setCodes] = useState<Record<string, string>>();
  const [selected, setSelected] = useState<number[]>([]);
  const [code, setCode] = useState('');
  const [useRoleCode, setUseRoleCode] = useState(false);
  const [overrides, setOverrides] = useState<Record<number, string>>({});
  const [date, setDate] = useState(`${year}-01-01`);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const stillMounted = useStillMounted();
  const ids = employees.map((employee) => employee.employee_id);
  const targets = ids.filter((id) => selected.includes(id));
  const missingRoleCodes = employees.filter(({ employee_id: id, job_role }) =>
    selected.includes(id) && !overrides[id] && !job_role?.occupation_code);
  const allSelected = targets.length === ids.length;

  async function open() {
    setBusy(true);
    setError('');
    try {
      const result = await tippedOccupationsApi.catalog(companyId);
      if (stillMounted()) setCodes(result.codes);
    } catch (err) {
      if (stillMounted()) setError(err instanceof Error ? err.message : 'Could not load Treasury occupation codes.');
    } finally {
      if (stillMounted()) setBusy(false);
    }
  }

  async function apply() {
    const employeesLabel = `${targets.length} ${targets.length === 1 ? 'employee' : 'employees'}`;
    if (!codes || (!useRoleCode && !codes[code])) return;
    if (useRoleCode && missingRoleCodes.length > 0) return;
    const expectedRoleCodes = Object.fromEntries(employees.flatMap(({ employee_id: id, job_role }) =>
      targets.includes(id) && !overrides[id] && job_role?.occupation_code ? [[id, job_role.occupation_code]] : []));
    const choice = useRoleCode ? 'each employee’s role code or override' : `${code} · ${codes[code]}`;
    if (!window.confirm(`Set ${choice} for ${employeesLabel} starting ${date}? Each code stays in effect unless a later entry is already scheduled.`)) return;

    setBusy(true);
    setError('');
    try {
      const result = await tippedOccupationsApi.bulkSet(companyId, {
        tax_year: year, employee_ids: targets, effective_from: date,
        ...(useRoleCode ? { use_role_code: true, overrides, expected_role_codes: expectedRoleCodes } : { occupation_code: code }),
      });
      if (stillMounted()) {
        setSelected([]);
        setOverrides({});
        setCodes(undefined);
        const capped = result.capped_count;
        const note = capped > 0 ? ` For ${capped} ${capped === 1 ? 'employee' : 'employees'}, the code ends the day before the next scheduled entry.` : '';
        await onSaved(`Saved the tipped occupation code for ${employeesLabel}.${note}`);
      }
    } catch (err) {
      if (stillMounted()) setError(err instanceof Error ? err.message : 'Could not save occupation codes.');
    } finally {
      if (stillMounted()) setBusy(false);
    }
  }

  return (
    <div className="mt-3 space-y-2">
      {codes ? (
        <form className="min-w-0 rounded-lg border border-neutral-200 p-3" onSubmit={(event) => {
          event.preventDefault();
          if (!busy && targets.length > 0) void apply();
        }}>
          <fieldset disabled={busy} className="min-w-0 space-y-3">
            <legend className="px-1 text-sm font-semibold">Set a code for multiple employees</legend>
            <label className="flex min-h-9 items-center gap-2 font-medium">
              <input type="checkbox" checked={allSelected} onChange={() => setSelected(allSelected ? [] : ids)} />
              Select all {ids.length} employees
            </label>
            <label className="flex min-h-9 items-center gap-2">
              <input type="checkbox" checked={useRoleCode} onChange={(event) => setUseRoleCode(event.target.checked)} />
              Use each employee's role code
            </label>
            <ul className="max-h-52 overflow-y-auto rounded border border-neutral-200 px-2">
              {employees.map(({ employee_id: id, name, job_role }) => (
                <li key={id}>
                  <label className="flex min-h-9 items-center gap-2">
                    <input type="checkbox" checked={selected.includes(id)}
                      onChange={() => setSelected((current) => current.includes(id) ? current.filter((entry) => entry !== id) : [...current, id])} />
                    {name ?? `Employee ${id}`}
                  </label>
                  {useRoleCode && selected.includes(id) && (
                    <div className="mb-2 min-w-0 space-y-1 text-sm">
                      <p className="break-words">{job_role?.name ?? 'No role'} · {job_role?.occupation_code
                        ? `${job_role.occupation_code} · ${codes[job_role.occupation_code] ?? ''}` : 'No role code'}</p>
                      <label className="block min-w-0">
                        Override for {name ?? `employee ${id}`}
                        <select className="block w-full min-w-0 max-w-full truncate rounded border p-2" value={overrides[id] ?? ''}
                          onChange={(event) => setOverrides({ ...overrides, [id]: event.target.value })}>
                          <option value="">Use role code</option>
                          {Object.entries(codes).map(([value, label]) => <option key={value} value={value}>{value} · {label}</option>)}
                        </select>
                      </label>
                    </div>
                  )}
                </li>
              ))}
            </ul>
            {useRoleCode && missingRoleCodes.length > 0 && (
              <p role="status" className="break-words text-sm">Choose an override for {missingRoleCodes.map(({ name, employee_id }) => name ?? `employee ${employee_id}`).join(', ')}.</p>
            )}
            {!useRoleCode && <TippedOccupationCodeSelect codes={codes} value={code} onChange={setCode} />}
            <Input type="date" label="Effective start date" value={date} required min={`${year}-01-01`} max={`${year}-12-31`}
              onChange={(event) => setDate(event.target.value)} />
            <div className="flex flex-wrap gap-2">
              <Button type="submit" size="sm" loading={busy} disabled={(useRoleCode ? missingRoleCodes.length > 0 : !code) || targets.length === 0}>Apply to {targets.length} selected</Button>
              <Button type="button" variant="outline" size="sm" onClick={() => { setCodes(undefined); setSelected([]); setOverrides({}); setError(''); }}>Cancel</Button>
            </div>
          </fieldset>
        </form>
      ) : (
        <Button type="button" variant="outline" size="sm" loading={busy} onClick={() => void open()}>Set tipped occupation codes</Button>
      )}
      {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
    </div>
  );
}
