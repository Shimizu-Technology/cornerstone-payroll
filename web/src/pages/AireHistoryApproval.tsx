import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { useCompany } from '@/contexts/CompanyContext';
import { useAuth } from '@/contexts/AuthContext';
import { timeTrackingSourcesApi } from '@/services/api';
import { aireHistoryApprovalApi, type HistoryApprovalSummary, type HistoryEntry, type MappingSelection } from '@/services/aireHistoryApproval';

const hours = (value: string) => Number(value).toFixed(2);
const panel = 'rounded-xl border border-neutral-200 bg-white p-4 sm:p-6';
const cell = 'border-b border-neutral-100 px-3 py-2 text-left align-top';

export function AireHistoryApproval() {
  const { activeCompanyId } = useCompany();
  const { user } = useAuth();
  if (!user || !['super_admin', 'admin', 'org_admin', 'accountant'].includes(user.role)) return <p className="p-6" role="alert">Organization admin or assigned payroll accountant access required.</p>;
  if (!activeCompanyId) return <p className="p-6">Select a client to review AIRE history.</p>;
  return <HistorySummary key={`${user.id}:${activeCompanyId}`} companyId={activeCompanyId} />;
}

function HistorySummary({ companyId }: { companyId: number }) {
  const [summary, setSummary] = useState<HistoryApprovalSummary | null>(null);
  const [sourceId, setSourceId] = useState<number | null>(null);
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState('');
  const [attested, setAttested] = useState(false);
  const [matches, setMatches] = useState<MappingSelection[]>([]);
  const [confirmed, setConfirmed] = useState<string[]>([]);
  const [solo, setSolo] = useState<Record<number, string>>({});
  const [dirty, setDirty] = useState(false);
  const [stale, setStale] = useState(false);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    timeTrackingSourcesApi.list().then(async (response) => {
      const source = response.time_tracking_sources.find((record) => record.active && record.source_type === 'aire_services');
      if (!source) throw new Error('No active AIRE connection is configured for this client. Ask your payroll administrator to prepare it.');
      if (!mounted.current) return;
      setSourceId(source.id);
      const result = await aireHistoryApprovalApi.preview(source.id, companyId);
      if (mounted.current) { setSummary(result); setMatches(result.mappings.map(({ source_user_uuid, employee_id }) => ({ source_user_uuid, employee_id }))); }
    }).catch((failure) => { if (mounted.current) setError(failure instanceof Error ? failure.message : 'Could not fetch AIRE history.'); })
      .finally(() => { if (mounted.current) setBusy(false); });
    return () => { mounted.current = false; };
  }, [companyId]);

  async function refresh() {
    if (!sourceId || busy) return;
    setBusy(true); setError(''); setAttested(false); setConfirmed([]); setSolo({}); setStale(true);
    try {
      const result = await aireHistoryApprovalApi.preview(sourceId, companyId, matches);
      if (mounted.current) { setSummary(result); setMatches(result.mappings.map(({ source_user_uuid, employee_id }) => ({ source_user_uuid, employee_id }))); setDirty(false); setStale(false); }
    } catch (failure) { if (mounted.current) setError(failure instanceof Error ? failure.message : 'Could not refresh history.'); }
    finally { if (mounted.current) setBusy(false); }
  }

  async function approve() {
    if (!summary || !sourceId || busy || !attested || dirty || stale) return;
    setBusy(true); setError('');
    try {
      const result = await aireHistoryApprovalApi.approve(sourceId, companyId, {
        review_id: summary.review_id, digest: summary.digest, attestation: summary.attestation, confirmed_mapping_uuids: confirmed,
        solo_choices: Object.entries(solo).filter(([, rate]) => rate).map(([employee, rate]) => ({ employee_id: Number(employee), employee_wage_rate_id: Number(rate) })),
      });
      if (mounted.current) setSummary(result);
    } catch (failure) {
      if (mounted.current) { setError(failure instanceof Error ? failure.message : 'History approval failed. Nothing was applied.'); setAttested(false); setStale(true); }
    } finally { if (mounted.current) setBusy(false); }
  }

  const missingConfirmations = summary?.mappings.some((row) => row.confirmation_required && !confirmed.includes(row.source_user_uuid));
  return <>
    <Header title="Review AIRE history" description="Review the history once, then approve its accounting coverage. Calendar publication and connected payroll activation are separate operator steps." />
    <main className="mx-auto max-w-6xl space-y-5 p-4 sm:p-6">
      <Link className="text-sm text-primary-700 underline" to="/app/time-account-connection">My AIRE account connection</Link>
      {error && <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50 p-4 text-danger-800">{error}</div>}
      {busy && <p role="status" className="text-neutral-600">{summary ? 'Checking fresh AIRE and Payroll evidence. Please keep this page open…' : 'Fetching authenticated AIRE history and committed Payroll registers…'}</p>}
      {!summary && !busy && sourceId && <Button onClick={refresh}>Retry history summary</Button>}
      {summary && <>
        <section className={panel} aria-labelledby="coverage-title">
          <h2 id="coverage-title" className="text-lg font-semibold">{summary.source_name} · history through {summary.through_work_date}</h2>
          <p className="mt-2 text-sm text-neutral-600">Hours already represented in manual payroll are recorded as history. Owed hours stay owed; pending items receive no new payment. This approval does not change time approvals or assert that checks were handed out.</p>
          <div className="mt-4 overflow-x-auto"><table className="w-full text-sm"><caption className="sr-only">History dispositions</caption><thead><tr><th className={cell}>Accounting treatment</th><th className={cell}>Entries</th><th className={cell}>Hours</th></tr></thead><tbody>
            {summary.dispositions.map((row) => <tr key={row.type}><td className={cell}>{row.label}</td><td className={cell}>{row.count}</td><td className={`${cell} tabular-nums`}>{hours(row.hours)}</td></tr>)}
          </tbody></table></div>
        </section>
        <section className={panel} aria-labelledby="mapping-title">
          <h2 id="mapping-title" className="text-lg font-semibold">Employee matches</h2>
          <p className="mt-1 text-sm text-neutral-600">Saved matches are checked against the authenticated AIRE directory. Confirm any suggested match that is not exact.</p>
          <div className="mt-3 space-y-3">{summary.mappings.map((row) => <div className="grid gap-2 border-b border-neutral-100 pb-3 sm:grid-cols-2" key={row.source_user_uuid}>
            <span className="break-words text-sm">{row.source_name}{row.existing ? ' · confirmed match' : ' · suggested match'}</span>
            <div><Select aria-label={`Payroll employee for ${row.source_name}`} disabled={busy || row.existing || !!summary.approved_at} value={matches.find((item) => item.source_user_uuid === row.source_user_uuid)?.employee_id || ''} onChange={(event) => {
              setMatches((previous) => previous.map((item) => item.source_user_uuid === row.source_user_uuid ? { ...item, employee_id: Number(event.target.value) || null } : item)); setDirty(true); setAttested(false); setConfirmed([]);
            }}><option value="">Choose a Payroll employee</option>{row.options.map((option) => <option value={option.id} key={option.id}>{option.name}</option>)}</Select>
              {row.confirmation_required && !dirty && <label className="mt-2 flex gap-2 text-sm"><input type="checkbox" disabled={busy || !!summary.approved_at} checked={confirmed.includes(row.source_user_uuid)} onChange={(event) => setConfirmed((previous) => event.target.checked ? [...previous, row.source_user_uuid] : previous.filter((uuid) => uuid !== row.source_user_uuid))} />I confirm {row.source_name} is {row.employee_name || 'the selected employee'}.</label>}
            </div>
          </div>)}</div>
          {dirty && <Button className="mt-3" onClick={refresh} disabled={busy}>Update summary with these matches</Button>}
        </section>
        <section className={panel} aria-labelledby="rounding-title">
          <h2 id="rounding-title" className="text-lg font-semibold">Rounding differences</h2>
          <p className="mt-1 text-sm text-neutral-600">Paid minus source, separately for each employee, run and pay category. Each acknowledged difference must be within ±0.05 hours.</p>
          {!summary.rounding_variances.length ? <p className="mt-3 text-sm">No rounding differences.</p> : <div className="mt-3 overflow-x-auto"><table className="w-full text-sm"><caption className="sr-only">Signed historical rounding differences</caption><thead><tr>{['Employee', 'Run', 'Category', 'Source h', 'Paid h', 'Signed difference h'].map((label) => <th key={label} className={cell}>{label}</th>)}</tr></thead><tbody>{summary.rounding_variances.map((row, index) => <tr key={index} className={row.within_limit ? '' : 'bg-danger-50'}><td className={cell}>{row.employee}</td><td className={cell}>{row.run_id}</td><td className={cell}>{row.source_category?.name} · {row.category}</td><td className={cell}>{hours(row.source_total)}</td><td className={cell}>{hours(row.paid_total)}</td><td className={cell}>{Number(row.signed_difference) > 0 ? '+' : ''}{hours(row.signed_difference)}</td></tr>)}</tbody></table></div>}
        </section>
        <EntryList key={`${summary.review_id}:owed`} title="Owed hours — remain owed" entries={summary.owed} />
        <EntryList key={`${summary.review_id}:pending`} title="Pending accounting review — no payment authorized" entries={summary.pending_review} />
        <section className={panel} aria-labelledby="solo-title">
          <h2 id="solo-title" className="text-lg font-semibold">Solo earning treatment</h2>
          <p className="mt-1 text-sm text-neutral-600">Chels/Mark must choose an earning component and rate before Solo hours can import. You can approve history while this decision remains open.</p>
          {!summary.solo_decisions.length && <p className="mt-3 text-sm">No Solo entries in this history scope. Any future Solo import still needs an explicit earning choice.</p>}
          {summary.solo_decisions.map((row, index) => <div className="mt-3" key={row.employee_id || index}><Select label={`${row.employee || 'Unmatched employee'} · ${hours(row.hours)} Solo h`} value={solo[row.employee_id || 0] || ''} disabled={busy || !row.employee_id || !!summary.approved_at} onChange={(event) => setSolo((previous) => ({ ...previous, [row.employee_id!]: event.target.value }))}>
            <option value="">Decision still open — block Solo import</option>{row.options.map((option) => <option key={option.id} value={option.id}>{option.label} · ${Number(option.rate).toFixed(2)}/h</option>)}
          </Select></div>)}
        </section>
        {summary.blockers.length > 0 && <section role="alert" className={`${panel} border-danger-200`}><h2 className="font-semibold">Resolve these evidence changes before history can be approved</h2><ul className="mt-2 list-disc space-y-1 pl-5 text-sm">{summary.blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul></section>}
        <section className={panel}>
          {summary.approved_at ? <div role="status"><h2 className="font-semibold text-success-700">History approved</h2><p className="mt-2 text-sm">Approved by {summary.approved_by} at {new Date(summary.approved_at).toLocaleString()}. This approval did not change connected mode; no calendar was published.</p></div> : <>
            <label className="flex items-start gap-3 text-sm leading-6"><input className="mt-1.5" type="checkbox" checked={attested} onChange={(event) => setAttested(event.target.checked)} disabled={busy || dirty || stale || !summary.history_coverage_verified} />{summary.attestation}</label>
            <div className="mt-4 flex flex-wrap gap-3"><Button onClick={approve} disabled={busy || !attested || dirty || stale || !summary.history_coverage_verified || missingConfirmations}>Approve history</Button><Button variant="outline" onClick={refresh} disabled={busy}>Refresh summary</Button></div>
            <p className="mt-3 break-all text-xs text-neutral-500">Summary reference: {summary.digest}</p>
          </>}
        </section>
      </>}
    </main>
  </>;
}

function EntryList({ title, entries }: { title: string; entries: HistoryEntry[] }) {
  const [page, setPage] = useState(0);
  const size = 25;
  return <section className={panel}><h2 className="text-lg font-semibold">{title}</h2><p className="mt-1 text-sm text-neutral-600">{entries.length} entries · {hours(String(entries.reduce((sum, row) => sum + Number(row.hours), 0)))} hours</p>
    {entries.length > 0 && <><div className="mt-3 overflow-x-auto"><table className="w-full text-sm"><caption className="sr-only">{title}</caption><thead><tr>{['Entry', 'Employee', 'Work date', 'Category', 'Hours', 'Source approval'].map((label) => <th className={cell} key={label}>{label}</th>)}</tr></thead><tbody>{entries.slice(page * size, (page + 1) * size).map((row) => <tr key={row.id}><td className={cell}>{row.id}</td><td className={cell}>{row.employee || 'Missing owner'}</td><td className={cell}>{row.work_date}</td><td className={cell}>{row.category || 'Unclassified'}</td><td className={cell}>{hours(row.hours)}</td><td className={cell}>{row.approval_status || 'Undetermined'}</td></tr>)}</tbody></table></div>
      {entries.length > size && <div className="mt-3 flex items-center gap-3"><Button variant="outline" disabled={page === 0} onClick={() => setPage((value) => value - 1)} aria-label={`Previous ${title}`}>Previous</Button><span className="text-sm">{page + 1} / {Math.ceil(entries.length / size)}</span><Button variant="outline" disabled={(page + 1) * size >= entries.length} onClick={() => setPage((value) => value + 1)} aria-label={`Next ${title}`}>Next</Button></div>}
    </>}
  </section>;
}
