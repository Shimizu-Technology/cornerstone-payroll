import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { useOptionalSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import { tippedOccupationsApi, type TippedOccupation } from '@/services/api';
import { TippedOccupationCodeSelect } from './TippedOccupationCodeSelect';

export function EmployeeTippedOccupations({ employeeId, companyId, readOnly }: {
  employeeId: number;
  companyId: number;
  readOnly: boolean;
}) {
  const canWrite = useOptionalSelectedCompanyCapability('manage_client_configuration', companyId) && !readOnly;
  const [history, setHistory] = useState<Awaited<ReturnType<typeof tippedOccupationsApi.history>>>();
  const [editing, setEditing] = useState<TippedOccupation | 'add'>();
  const [code, setCode] = useState('');
  const [startDate, setStartDate] = useState('');
  const [endDate, setEndDate] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');

  useEffect(() => {
    let active = true;
    tippedOccupationsApi.history(employeeId, companyId).then(
      (result) => { if (active) setHistory(result); },
      (err: unknown) => { if (active) setError(err instanceof Error ? err.message : 'Could not load occupation history.'); },
    );
    return () => { active = false; };
  }, [employeeId, companyId]);

  function openEditor(row: TippedOccupation | 'add') {
    setEditing(row);
    setCode('');
    setStartDate('');
    setEndDate('');
    setError('');
    setMessage('');
  }

  async function save(action: () => ReturnType<typeof tippedOccupationsApi.history>, success: string) {
    setSaving(true);
    setError('');
    setMessage('');
    try {
      setHistory(await action());
      setEditing(undefined);
      setMessage(success);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save the occupation code.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Card id="tipped-occupations">
      <CardHeader><CardTitle>Tipped occupation codes · W-2 Box 14b</CardTitle></CardHeader>
      <CardContent className="space-y-4">
        {!history && !error && <p role="status">Loading occupation history…</p>}
        {history?.data.length === 0 && <p>No tipped occupation codes on file.</p>}
        {history && (
          <ul className="divide-y divide-neutral-200">
            {history.data.map((row) => (
              <li key={row.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                <div>
                  <p className="font-medium">{row.occupation_code} · {history.codes[row.occupation_code] ?? 'Unlisted code'}</p>
                  <p className="text-sm text-neutral-600">{row.effective_from} to {row.effective_to ?? 'ongoing'}</p>
                </div>
                {canWrite && <div className="flex gap-2">
                  <Button size="sm" variant="outline" disabled={saving} onClick={() => openEditor(row)}>Change</Button>
                  <Button size="sm" variant="outline" disabled={saving} onClick={() => {
                    if (window.confirm(`Remove code ${row.occupation_code} starting ${row.effective_from} from this employee’s history?`)) {
                      void save(() => tippedOccupationsApi.remove(employeeId, row.id, companyId), 'Occupation code removed.');
                    }
                  }}>Remove</Button>
                </div>}
              </li>
            ))}
          </ul>
        )}
        {canWrite && history && !editing && <Button size="sm" onClick={() => openEditor('add')}>Add occupation code</Button>}
        {canWrite && history && editing && (
          <form className="space-y-3" onSubmit={(event) => {
            event.preventDefault();
            if (saving) return;
            void save(() => tippedOccupationsApi.save(employeeId, companyId, {
              occupation_code: code, effective_from: startDate,
              ...(editing === 'add' ? { effective_to: endDate || undefined } : { replace_id: editing.id }),
            }), 'Occupation code saved.');
          }}>
            <fieldset className="space-y-3" disabled={saving}>
              <legend className="font-medium">{editing === 'add' ? 'Add occupation code' : `Change code ${editing.occupation_code} starting ${editing.effective_from}`}</legend>
              {editing !== 'add' && <p className="text-sm text-neutral-600">The old code ends the day before the new code starts.</p>}
              <TippedOccupationCodeSelect codes={history.codes} value={code} onChange={setCode} />
              <div className="grid gap-3 sm:grid-cols-2">
                <Input type="date" label="Effective start date" required value={startDate} onChange={(event) => setStartDate(event.target.value)} />
                {editing === 'add' && <Input type="date" label="Effective end date (optional)" min={startDate} value={endDate} onChange={(event) => setEndDate(event.target.value)} />}
              </div>
              <div className="flex flex-wrap gap-2">
                <Button type="submit" size="sm" loading={saving}>Save occupation code</Button>
                <Button type="button" size="sm" variant="outline" onClick={() => { setEditing(undefined); setError(''); }}>Cancel</Button>
              </div>
            </fieldset>
          </form>
        )}
        {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
        {message && <p role="status" className="text-sm">{message}</p>}
      </CardContent>
    </Card>
  );
}
