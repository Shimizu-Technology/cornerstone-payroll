import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { apiClient } from '@/services/api';
import type { Employee } from '@/types';

type Entry = { id: number; name: string; active: boolean; occupation_code?: string | null };
type Catalog = { departments: Entry[]; roles: Entry[]; codes: Record<string, string> };

export function EmployeeOrganizationPanel({ companyId, isClient, employees, onSaved }: {
  companyId: number;
  isClient: boolean;
  employees: Employee[];
  onSaved: () => void;
}) {
  const prefix = isClient ? '/client' : '/admin';
  const endpoint = `${prefix}/employee_organization`;
  const scope = { companyId };
  const [data, setData] = useState<Catalog>();
  const [selected, setSelected] = useState<number[]>([]);
  const [department, setDepartment] = useState('');
  const [role, setRole] = useState('');
  const [kind, setKind] = useState<'roles' | 'departments'>('roles');
  const [editId, setEditId] = useState('');
  const [name, setName] = useState('');
  const [active, setActive] = useState(true);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const pageIds = employees.map((employee) => employee.id);
  const allOnPageSelected = pageIds.length > 0 && pageIds.every((id) => selected.includes(id));
  const offPageCount = selected.filter((id) => !pageIds.includes(id)).length;

  async function load() {
    setData(await apiClient.get<Catalog>(endpoint, undefined, scope));
  }

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError('');
    setNotice('');
    try {
      await action();
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Could not save changes.');
    } finally {
      setBusy(false);
    }
  }

  function edit(id: string, entry?: Entry) {
    setEditId(id);
    setName(entry?.name ?? '');
    setActive(entry?.active ?? true);
    setCode(entry?.occupation_code ?? '');
  }

  async function saveEntry() {
    if (kind === 'roles') {
      setData(await apiClient.post<Catalog>(`${endpoint}/save_role`, {
        id: editId || undefined, role: { name, active, occupation_code: code || null },
      }, scope));
    } else {
      const body = { department: { name, active } };
      if (editId) await apiClient.patch(`${prefix}/departments/${editId}`, body, scope);
      else await apiClient.post(`${prefix}/departments`, body, scope);
      await load();
    }
    edit('');
    setNotice('Saved.');
    onSaved();
  }

  async function assign() {
    const value = (input: string) => input === 'clear' ? null : Number(input);
    await apiClient.patch(endpoint, {
      employee_ids: selected,
      ...(department ? { department_id: value(department) } : {}),
      ...(role ? { company_job_role_id: value(role) } : {}),
    }, scope);
    setNotice(`Updated ${selected.length} ${selected.length === 1 ? 'employee' : 'employees'}.`);
    setSelected([]);
    setDepartment('');
    setRole('');
    onSaved();
  }

  function assignmentOptions(entries: Entry[]) {
    return [
      { value: '', label: 'Keep current' },
      { value: 'clear', label: 'Clear assignment' },
      ...entries.filter((entry) => entry.active).map((entry) => ({ value: String(entry.id), label: entry.name })),
    ];
  }

  return (
    <section className="mb-6 space-y-3">
      <Button type="button" variant="outline" aria-expanded={!!data} loading={busy && !data}
        onClick={() => { if (data) { setData(undefined); setSelected([]); } else void run(load); }}>
        Roles and departments
      </Button>
      {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
      {notice && <p role="status" className="text-sm">{notice}</p>}
      {data && (
        <fieldset disabled={busy} className="grid gap-5 rounded-lg border p-4 lg:grid-cols-2">
          <form className="space-y-3" onSubmit={(event) => { event.preventDefault(); void run(assign); }}>
            <h2 className="font-semibold">Assign employees</h2>
            {pageIds.length > 0 && (
              <label className="flex min-h-9 items-center gap-2">
                <input type="checkbox" checked={allOnPageSelected} onChange={() => {
                  setSelected((current) => allOnPageSelected
                    ? current.filter((id) => !pageIds.includes(id))
                    : Array.from(new Set([...current, ...pageIds])));
                }} /> Select this page
              </label>
            )}
            <ul className="max-h-56 overflow-y-auto rounded border px-3">
              {employees.map((employee) => (
                <li key={employee.id}>
                  <label className="flex min-h-10 items-center gap-2">
                    <input type="checkbox" checked={selected.includes(employee.id)} onChange={(event) => {
                      const checked = event.target.checked;
                      setSelected((current) => checked ? [...current, employee.id] : current.filter((id) => id !== employee.id));
                    }} />
                    <span>{employee.first_name} {employee.last_name}
                      <span className="block text-xs text-neutral-600">
                        {[employee.job_title, data.departments.find((entry) => entry.id === employee.department_id)?.name].filter(Boolean).join(' · ')}
                      </span>
                    </span>
                  </label>
                </li>
              ))}
              {employees.length === 0 && <li className="p-2 text-sm">No employees on this page.</li>}
            </ul>
            <Select label="Department" value={department} options={assignmentOptions(data.departments)}
              onChange={(event) => setDepartment(event.target.value)} />
            <Select label="Role" value={role} options={assignmentOptions(data.roles)}
              onChange={(event) => setRole(event.target.value)} />
            {offPageCount > 0 && <p className="text-sm">{offPageCount} selected from other pages or filters.</p>}
            {selected.length > 500 && <p className="text-sm">Select up to 500 employees per update.</p>}
            <Button type="submit" disabled={!selected.length || selected.length > 500 || (!department && !role)}>
              Apply to {selected.length} selected
            </Button>
            {selected.length > 0 && <Button type="button" variant="ghost" onClick={() => setSelected([])}>Clear selection</Button>}
          </form>
          <form className="space-y-3" onSubmit={(event) => { event.preventDefault(); void run(saveEntry); }}>
            <h2 className="font-semibold">Manage roles and departments</h2>
            <Select label="List" value={kind} options={[{ value: 'roles', label: 'Roles' }, { value: 'departments', label: 'Departments' }]}
              onChange={(event) => { setKind(event.target.value === 'roles' ? 'roles' : 'departments'); edit(''); }} />
            <Select label={kind === 'roles' ? 'Role to edit' : 'Department to edit'} value={editId}
              options={[{ value: '', label: kind === 'roles' ? 'New role' : 'New department' }, ...data[kind].map((entry) => ({
                value: String(entry.id), label: entry.active ? entry.name : `${entry.name} (inactive)`,
              }))]}
              onChange={(event) => edit(event.target.value, data[kind].find((entry) => String(entry.id) === event.target.value))} />
            <Input label="Name" required maxLength={255} value={name} onChange={(event) => setName(event.target.value)} />
            {kind === 'roles' && <Select label="Default tipped occupation" value={code}
              options={[{ value: '', label: 'None' }, ...Object.entries(data.codes).map(([value, label]) => ({ value, label: `${value} · ${label}` }))]}
              onChange={(event) => setCode(event.target.value)} />}
            <label className="flex min-h-9 items-center gap-2">
              <input type="checkbox" checked={active} onChange={(event) => setActive(event.target.checked)} /> Active
            </label>
            <Button type="submit" disabled={!name.trim()}>Save {kind === 'roles' ? 'role' : 'department'}</Button>
          </form>
        </fieldset>
      )}
    </section>
  );
}
