import { useCallback, useEffect, useRef, useState } from 'react';
import { Link2, Unlink } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { clientProfitabilityApi, type LinkQueueData, type TaxClientEntry, type TaxStaffEntry } from '@/services/clientProfitability';
import { formatDate, hours } from './format';
import { SelectField } from './SelectField';
const INTERNAL = 'internal';
const NO_PAYROLL = 'no_payroll';

function matchText(match: string): string {
  if (match === 'exact') return 'same name';
  if (match === 'internal') return 'Tax marks this as internal time';
  return 'similar name';
}

function ClientCard({ entry, data, onSaved }: { entry: TaxClientEntry; data: LinkQueueData; onSaved: () => void }) {
  const [editing, setEditing] = useState(entry.link === null && !entry.handled_automatically);
  const [choice, setChoice] = useState(() => {
    if (entry.link) return entry.link.disposition === 'internal' ? INTERNAL : String(entry.link.company_id);
    if (entry.suggestion) return entry.suggestion.disposition === 'internal' ? INTERNAL : String(entry.suggestion.company_id);
    return '';
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save(value: string) {
    if (!value) { setError('Choose a Payroll client or Internal / overhead.'); return; }
    setBusy(true);
    setError(null);
    try {
      await clientProfitabilityApi.linkClient(entry.tax_client_id, value === INTERNAL
        ? { disposition: 'internal', tax_client_name: entry.name }
        : { disposition: 'company', company_id: Number(value), tax_client_name: entry.name });
      setEditing(false);
      onSaved();
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : 'Couldn’t save this link.');
    } finally {
      setBusy(false);
    }
  }

  async function unlink() {
    setBusy(true);
    try {
      await clientProfitabilityApi.unlinkClient(entry.tax_client_id);
      onSaved();
    } catch (unlinkError) {
      setError(unlinkError instanceof Error ? unlinkError.message : 'Couldn’t remove this link.');
    } finally {
      setBusy(false);
    }
  }

  const linkedTo = entry.link?.disposition === 'internal' ? 'Internal / overhead' : entry.link?.company_name;
  return (
    <li className="rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="text-base font-semibold text-neutral-950">{entry.name}</h3>
        <p className="text-sm text-neutral-600">{hours(entry.hours)} hours{entry.last_worked_on ? ` · last worked ${formatDate(entry.last_worked_on)}` : ''}</p>
      </div>
      {!editing ? (
        <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
          <p className="text-sm text-neutral-800">
            {entry.handled_automatically && !entry.link ? 'Counted as internal / overhead (Tax marks it as Cornerstone’s own time).' : <>Linked to <strong>{linkedTo}</strong></>}
          </p>
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => setEditing(true)} disabled={busy} className="min-h-11 sm:min-h-11">Change</Button>
            {entry.link && <Button variant="ghost" onClick={() => void unlink()} disabled={busy} className="min-h-11 sm:min-h-11"><Unlink className="mr-2 h-4 w-4" aria-hidden="true" />Unlink</Button>}
          </div>
        </div>
      ) : (
        <div className="mt-3 space-y-3">
          {entry.suggestion && !entry.link && (
            <div className="flex flex-wrap items-center justify-between gap-2 rounded-xl bg-primary-50 px-3 py-2">
              <p className="text-sm text-primary-950">Suggested: <strong>{entry.suggestion.label}</strong> <span className="text-primary-800">({matchText(entry.suggestion.match)})</span></p>
              <Button onClick={() => void save(entry.suggestion?.disposition === 'internal' ? INTERNAL : String(entry.suggestion?.company_id))} disabled={busy} className="min-h-11 sm:min-h-11">
                Use suggestion
              </Button>
            </div>
          )}
          <div className="grid gap-2 sm:grid-cols-[1fr_auto] sm:items-end">
            <SelectField label="Count these hours for" value={choice} onChange={(event) => setChoice(event.target.value)}>
              <option value="">Choose…</option>
              <option value={INTERNAL}>Internal / overhead (not a client)</option>
              {data.companies.map((company) => <option key={company.id} value={company.id}>{company.name}</option>)}
            </SelectField>
            <Button variant="secondary" onClick={() => void save(choice)} disabled={busy} className="min-h-11 sm:min-h-11"><Link2 className="mr-2 h-4 w-4" aria-hidden="true" />Save link</Button>
          </div>
        </div>
      )}
      {error && <p role="alert" className="mt-2 text-sm text-red-800">{error}</p>}
    </li>
  );
}

function StaffCard({ entry, data, onSaved }: { entry: TaxStaffEntry; data: LinkQueueData; onSaved: () => void }) {
  const [editing, setEditing] = useState(entry.link === null);
  const [choice, setChoice] = useState(() => {
    if (entry.link) return entry.link.disposition === 'no_payroll' ? NO_PAYROLL : String(entry.link.employee_id);
    return entry.suggestion?.employee_id ? String(entry.suggestion.employee_id) : '';
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save(value: string) {
    if (!value) { setError('Choose an employee or “Not on payroll”.'); return; }
    setBusy(true);
    setError(null);
    try {
      await clientProfitabilityApi.linkStaff(entry.tax_user_id, value === NO_PAYROLL
        ? { disposition: 'no_payroll', email: entry.email }
        : { disposition: 'employee', employee_id: Number(value), email: entry.email });
      setEditing(false);
      onSaved();
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : 'Couldn’t save this link.');
    } finally {
      setBusy(false);
    }
  }

  async function unlink() {
    setBusy(true);
    try {
      await clientProfitabilityApi.unlinkStaff(entry.tax_user_id);
      onSaved();
    } catch (unlinkError) {
      setError(unlinkError instanceof Error ? unlinkError.message : 'Couldn’t remove this link.');
    } finally {
      setBusy(false);
    }
  }

  const name = entry.email ?? `Tax user #${entry.tax_user_id}`;
  return (
    <li className="rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="break-all text-base font-semibold text-neutral-950">{name}</h3>
        <p className="text-sm text-neutral-600">{hours(entry.hours)} hours</p>
      </div>
      {!editing && entry.link ? (
        <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
          <p className="text-sm text-neutral-800">
            {entry.link.disposition === 'no_payroll' ? 'Not on payroll: hours are shown with no cost.' : <>Paid as <strong>{entry.link.employee_name}</strong></>}
            {!entry.link.in_practice_company && <span className="block text-amber-800">This employee isn’t in the staff payroll client chosen in Setup.</span>}
          </p>
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => setEditing(true)} disabled={busy} className="min-h-11 sm:min-h-11">Change</Button>
            <Button variant="ghost" onClick={() => void unlink()} disabled={busy} className="min-h-11 sm:min-h-11"><Unlink className="mr-2 h-4 w-4" aria-hidden="true" />Unlink</Button>
          </div>
        </div>
      ) : (
        <div className="mt-3 space-y-3">
          {entry.suggestion && !entry.link && (
            <div className="flex flex-wrap items-center justify-between gap-2 rounded-xl bg-primary-50 px-3 py-2">
              <p className="text-sm text-primary-950">Suggested: <strong>{entry.suggestion.label}</strong> <span className="text-primary-800">({entry.suggestion.match === 'exact' ? 'same email' : 'same first name'})</span></p>
              <Button onClick={() => void save(String(entry.suggestion?.employee_id))} disabled={busy} className="min-h-11 sm:min-h-11">Use suggestion</Button>
            </div>
          )}
          <div className="grid gap-2 sm:grid-cols-[1fr_auto] sm:items-end">
            <SelectField label="Their pay comes from" value={choice} onChange={(event) => setChoice(event.target.value)}>
              <option value="">Choose…</option>
              <option value={NO_PAYROLL}>Not on payroll (no cost)</option>
              {data.employees.map((employee) => <option key={employee.id} value={employee.id}>{employee.name}{employee.status !== 'active' ? ` (${employee.status})` : ''}</option>)}
            </SelectField>
            <Button variant="secondary" onClick={() => void save(choice)} disabled={busy} className="min-h-11 sm:min-h-11"><Link2 className="mr-2 h-4 w-4" aria-hidden="true" />Save link</Button>
          </div>
          {data.employees.length === 0 && <p className="text-sm text-amber-800">Choose the staff payroll client in Setup to see employees here.</p>}
        </div>
      )}
      {error && <p role="alert" className="mt-2 text-sm text-red-800">{error}</p>}
    </li>
  );
}

interface LinkQueueProps {
  /** Tells the page a link changed; the page then bumps reloadKey. */
  onChanged: () => void;
  /** Bumped by the page when data changes (a link saved, a refresh from Tax finished). */
  reloadKey: number;
}

export function LinkQueue({ onChanged, reloadKey }: LinkQueueProps) {
  const [data, setData] = useState<LinkQueueData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showLinked, setShowLinked] = useState(false);

  // Several cards can save at once; only the newest reload may update the
  // queue, so an older response can't bring back a link that was changed.
  const latestRequest = useRef(0);
  const load = useCallback(() => {
    const request = latestRequest.current + 1;
    latestRequest.current = request;
    void clientProfitabilityApi.links().then((next) => {
      if (request !== latestRequest.current) return;
      setData(next);
      setError(null);
    }).catch((loadError: unknown) => {
      if (request !== latestRequest.current) return;
      setError(loadError instanceof Error ? loadError.message : 'Couldn’t load Tax clients and staff.');
    });
  }, []);
  // Loads on mount and whenever the page invalidates the data, through the
  // same request guard as every other reload.
  useEffect(load, [load, reloadKey]);

  const saved = useCallback(() => { onChanged(); }, [onChanged]);

  if (error) {
    return (
      <div role="alert" className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-900">
        <span>{error}</span>
        <Button variant="outline" onClick={load} className="min-h-11 sm:min-h-11">Try again</Button>
      </div>
    );
  }
  if (!data) return <p role="status" className="text-sm text-neutral-600">Loading Tax clients and staff…</p>;
  if (data.clients.length === 0 && data.staff.length === 0) {
    return <p className="rounded-2xl border border-neutral-200 bg-white p-6 text-sm text-neutral-600">No hours have been pulled from Tax yet. Refresh hours in Setup first.</p>;
  }

  const needsClient = data.clients.filter((entry) => entry.link === null && !entry.handled_automatically);
  const linkedClients = data.clients.filter((entry) => entry.link !== null || entry.handled_automatically);
  const needsStaff = data.staff.filter((entry) => entry.link === null);
  const linkedStaff = data.staff.filter((entry) => entry.link !== null);

  return (
    <div className="space-y-8">
      <p className="text-sm leading-6 text-neutral-600">
        Tell Payroll which client and which employee each Tax record is. Links are saved and reused for every period; change them any time. Hours that aren’t linked still show in the report under “Not linked yet”.
      </p>
      <label className="flex min-h-11 items-center gap-3 text-sm font-medium text-neutral-800">
        <input type="checkbox" className="h-5 w-5 rounded border-neutral-300" checked={showLinked} onChange={(event) => setShowLinked(event.target.checked)} />
        Also show records that are already linked
      </label>

      <section aria-labelledby="link-clients-heading">
        <h2 id="link-clients-heading" className="text-lg font-semibold text-neutral-950">Tax clients <span className="text-sm font-normal text-neutral-600">· {needsClient.length} to link</span></h2>
        {needsClient.length === 0 && !showLinked && <p className="mt-2 text-sm text-emerald-800">Every Tax client with hours is linked.</p>}
        <ul className="mt-3 space-y-3">
          {[...needsClient, ...(showLinked ? linkedClients : [])].map((entry) => (
            <ClientCard key={`${entry.tax_client_id}-${entry.link?.company_id ?? entry.link?.disposition ?? 'none'}`} entry={entry} data={data} onSaved={saved} />
          ))}
        </ul>
      </section>

      <section aria-labelledby="link-staff-heading">
        <h2 id="link-staff-heading" className="text-lg font-semibold text-neutral-950">Staff <span className="text-sm font-normal text-neutral-600">· {needsStaff.length} to link</span></h2>
        {needsStaff.length === 0 && !showLinked && <p className="mt-2 text-sm text-emerald-800">Everyone with hours is linked.</p>}
        <ul className="mt-3 space-y-3">
          {[...needsStaff, ...(showLinked ? linkedStaff : [])].map((entry) => (
            <StaffCard key={`${entry.tax_user_id}-${entry.link?.employee_id ?? entry.link?.disposition ?? 'none'}`} entry={entry} data={data} onSaved={saved} />
          ))}
        </ul>
      </section>
    </div>
  );
}
