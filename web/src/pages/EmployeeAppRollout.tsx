import { useCallback, useEffect, useId, useState, type FormEvent, type ReactNode } from 'react';
import { Link } from 'react-router';
import { Header } from '@/components/layout/Header';
import { EmployeeAppTurnOnStep } from '@/components/employee-app/EmployeeAppTurnOnStep';
import { InviteDeliveryField } from '@/components/employee-app/InviteDeliveryField';
import { PrintedInvites } from '@/components/employee-app/PrintedInvites';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { useCompany } from '@/contexts/CompanyContext';
import { employeeAppRolloutPath, employeeAppSettingsPath, employeeContactDetailsPath, employeePath } from '@/lib/routes';
import { useSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import {
  employeeAppOff, employeeAppRolloutApi, formatEmployeeAppDate, inviteEmailMessages,
  type EmployeeAppRollout as Rollout, type InviteDelivery, type PrintedInvite, type RolloutCount, type WaveOutcome,
} from '@/services/employee-app-rollout-api';

const counts: [RolloutCount, string][] = [
  ['ready_to_invite', 'Ready to invite by email'],
  ['invited', 'Invited'],
  ['active', 'Active'],
  ['needs_contact_details', 'Need contact details'],
  ['locked', 'Locked'],
  ['former', 'Former'],
];
const textLink = 'inline-flex min-h-11 items-center text-sm font-semibold text-primary-800 underline underline-offset-2 [overflow-wrap:anywhere]';

export function EmployeeAppRollout({ audience }: { audience: 'admin' | 'client' }) {
  const { activeCompany } = useCompany();
  const canManageSettings = useSelectedCompanyCapability('manage_client_administration');
  if (!activeCompany) return <WorkspaceLoader label="Loading client" />;
  return <CompanyRollout key={`${activeCompany.id}:${audience}`} companyId={activeCompany.id} companyName={activeCompany.name} audience={audience}
    showSettings={audience === 'client' || canManageSettings} />;
}

function CompanyRollout({ companyId, companyName, audience, showSettings }: {
  companyId: number;
  companyName: string;
  audience: 'admin' | 'client';
  showSettings: boolean;
}) {
  const [rollout, setRollout] = useState<Rollout | null>(null);
  const [loadError, setLoadError] = useState('');
  const [attempt, setAttempt] = useState(0);
  const getRollout = useCallback(() => employeeAppRolloutApi(companyId, audience).get(), [companyId, audience]);

  useEffect(() => {
    let current = true;
    void getRollout().then(({ data }) => {
      if (current) { setRollout(data); setLoadError(''); }
    }).catch(() => {
      if (current) setLoadError('Could not load the company rollout. Try again.');
    });
    return () => { current = false; };
  }, [getRollout, attempt]);

  function recordPath(employeeId: number) {
    return employeePath(companyId, employeeId, 'overview', { returnTo: employeeAppRolloutPath(companyId) });
  }

  return (
    <div>
      <Header title={audience === 'client' ? 'Employee app' : 'Employee app rollout'} mobileSticky={false} actions={showSettings && (
        <Link className={textLink} to={employeeAppSettingsPath(companyId)}>Branding and Help settings</Link>
      )} />
      <div className="mx-auto max-w-6xl space-y-5 p-4 sm:p-6 lg:p-8">
        {loadError && <div className="flex flex-wrap items-center gap-2"><p role="alert" className="text-sm text-danger-700">{loadError}</p><Button type="button" variant="outline" onClick={() => setAttempt((value) => value + 1)}>Try again</Button></div>}
        {!rollout && !loadError && <WorkspaceLoader label="Loading rollout" />}
        {rollout && <>
          {!rollout.enabled && (
            <div role="status" className="space-y-1 rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-800">
              <p className="font-semibold text-neutral-900">{employeeAppOff}</p>
              <p>
                {audience === 'client' && 'Cornerstone turns the app on. '}
                You can add missing emails and mobile numbers now so invites are ready.
              </p>
              {audience === 'admin' && <p><EmployeeAppTurnOnStep companyId={companyId} audience="admin" /></p>}
            </div>
          )}
          <dl aria-label="Rollout counts" className="grid grid-cols-2 gap-2.5 sm:grid-cols-3 xl:grid-cols-6">
            {counts.map(([key, label]) => (
              <div key={key} className="flex flex-col gap-1 rounded-xl border border-neutral-200 bg-white p-3 sm:p-4">
                <dt className="text-sm font-medium text-neutral-700">{label}</dt>
                <dd className="order-first text-2xl font-semibold tabular-nums text-neutral-950">{rollout.counts[key]}</dd>
              </div>
            ))}
          </dl>
          <Card>
            <CardHeader><CardTitle>To do</CardTitle></CardHeader>
            <CardContent className="space-y-3">
              {rollout.lock_alert && (
                <p role="status" className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">
                  Several sign-ups were locked within an hour. Alert recorded {formatEmployeeAppDate(rollout.lock_alert, true)} (Guam time).
                </p>
              )}
              <div className="grid gap-3 lg:grid-cols-3">
                <EmployeeTasks title="Locked sign-ups" rows={rollout.todo.locked} recordPath={recordPath} detail={(row) => `Locked until ${formatEmployeeAppDate(row.locked_until, true)} (Guam time)`} />
                <EmployeeTasks title="Missing contact details" rows={rollout.todo.needs_contact_details} recordPath={recordPath} />
                <EmployeeTasks title="Expiring or expired invites" rows={rollout.todo.expiring} recordPath={recordPath}
                  detail={(row) => `${row.expired ? 'Expired' : 'Expires'} ${formatEmployeeAppDate(row.invite_expires_at, true)} (Guam time)`} />
                {audience === 'admin' && <EmployeeTasks title="Sign-up resets to finish" rows={rollout.todo.reset_pending} recordPath={recordPath} />}
              </div>
              <div className="flex flex-wrap gap-x-4">
                <Link className={textLink} to={employeeContactDetailsPath(companyId)}>Open contact details</Link>
                {audience === 'client' && <Link className={textLink} to="/change-requests">Review employee changes</Link>}
              </div>
            </CardContent>
          </Card>
          {rollout.can_manage_invites && <InviteWave rollout={rollout} companyId={companyId} companyName={companyName} audience={audience}
            recordPath={recordPath} refresh={() => setAttempt((value) => value + 1)} />}
          <Card>
            <CardHeader>
              <CardTitle>Cleanup report</CardTitle>
              <CardDescription>Review inactive employees with no termination date.</CardDescription>
            </CardHeader>
            <CardContent>
              <EmployeeTasks title="Missing termination date" rows={rollout.todo.cleanup} recordPath={recordPath} />
            </CardContent>
          </Card>
        </>}
      </div>
    </div>
  );
}

function EmployeeTasks<Row extends { id: number; name: string }>({ title, rows, recordPath, detail }: {
  title: string;
  rows: Row[];
  recordPath: (employeeId: number) => string;
  detail?: (row: Row) => ReactNode;
}) {
  return (
    <details className="rounded-xl border border-neutral-200 bg-white px-3">
      <summary className="min-h-11 cursor-pointer py-3 text-sm font-semibold text-neutral-800">
        <span className="inline-flex items-center">{title} ({rows.length})</span>
      </summary>
      {rows.length === 0 ? <p className="pb-3 text-sm text-neutral-600">No employees to review.</p> : (
        <ul className="max-h-64 divide-y divide-neutral-100 overflow-y-auto pb-1">
          {rows.map((row) => (
            <li key={row.id} className="pb-2">
              <Link className={textLink} to={recordPath(row.id)}>{row.name}</Link>
              {detail && <p className="text-sm text-neutral-600">{detail(row)}</p>}
            </li>
          ))}
        </ul>
      )}
    </details>
  );
}

type WaveResult = Omit<WaveOutcome, 'print'> & { name: string; codeCreated: boolean };

function InviteWave({ rollout, companyId, companyName, audience, recordPath, refresh }: {
  rollout: Rollout;
  companyId: number;
  companyName: string;
  audience: 'admin' | 'client';
  recordPath: (employeeId: number) => string;
  refresh: () => void;
}) {
  const searchId = useId();
  const [delivery, setDelivery] = useState<InviteDelivery>('email');
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState<number[]>([]);
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<WaveResult[]>([]);
  const [problem, setProblem] = useState('');
  const [printed, setPrinted] = useState<PrintedInvite[]>([]);
  const eligible = rollout.candidates.filter((candidate) => delivery === 'code' || candidate.email_ready);
  const matches = eligible.filter((candidate) => `${candidate.name} ${candidate.email || ''}`.toLowerCase().includes(query.trim().toLowerCase()));
  const selectedIds = selected.filter((id) => eligible.some((candidate) => candidate.id === id));

  async function inviteWave(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy || !rollout.enabled || !selectedIds.length) return;
    setBusy(true);
    setProblem('');
    setResults([]);
    try {
      const { data } = await employeeAppRolloutApi(companyId, audience).inviteWave(selectedIds, delivery);
      setResults(data.map(({ print, ...row }) => ({
        ...row,
        name: eligible.find((candidate) => candidate.id === row.id)?.name || 'Employee',
        codeCreated: !!print,
      })));
      setPrinted(data.flatMap((row) => row.print ? [row.print] : []));
      setSelected([]);
    } catch (caught) {
      setProblem(caught instanceof Error ? caught.message : 'Could not send these invites. Review employee status before trying again.');
    } finally {
      setBusy(false);
      refresh();
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Invite a group</CardTitle>
        <CardDescription>
          {rollout.enabled
            ? `Choose up to ${rollout.max_wave_size} employees. Use printed codes for employees without a personal email.`
            : audience === 'client'
              ? 'You can invite employees once Cornerstone turns the app on.'
              : 'You can invite employees once the app is turned on.'}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {rollout.enabled && (
          <form className="space-y-3" onSubmit={(event) => void inviteWave(event)}>
            <InviteDeliveryField value={delivery} onChange={(value) => { setDelivery(value); setSelected([]); }} disabled={busy} />
            {delivery === 'email' && rollout.candidates.some((candidate) => candidate.email_review_required) && (
              <p className="text-sm text-neutral-600">For employees with an existing payroll login, review and send the email invite from their employee record.</p>
            )}
            <div className="space-y-1">
              <label htmlFor={searchId} className="text-sm font-semibold">Find employees</label>
              <Input id={searchId} type="search" className="max-w-md text-base" value={query} onChange={(event) => setQuery(event.target.value)} />
            </div>
            {matches.length === 0 ? (
              <p className="text-sm text-neutral-600">{query ? 'No matching employees.' : 'No employees ready for this delivery method.'}</p>
            ) : (
              <ul className="max-h-72 divide-y divide-neutral-100 overflow-auto rounded-xl border border-neutral-200">
                {matches.map((employee) => {
                  const checked = selected.includes(employee.id);
                  return (
                    <li key={employee.id}>
                      <label className="flex min-h-11 cursor-pointer items-center gap-3 px-3 py-2 text-sm has-checked:bg-primary-50">
                        <input type="checkbox" className="accent-primary-700" checked={checked}
                          disabled={busy || (!checked && selectedIds.length >= rollout.max_wave_size)}
                          onChange={() => setSelected((previous) => checked ? previous.filter((id) => id !== employee.id) : [...previous, employee.id])} />
                        <span className="min-w-0 [overflow-wrap:anywhere]">
                          <strong>{employee.name}</strong>
                          {delivery === 'email' && <span className="block text-neutral-600">{employee.email}</span>}
                        </span>
                      </label>
                    </li>
                  );
                })}
              </ul>
            )}
            <div className="flex flex-wrap items-center gap-3">
              <Button type="submit" disabled={selectedIds.length === 0} loading={busy}>{delivery === 'email' ? 'Send email invites' : 'Create printed codes'}</Button>
              <p role="status" className="text-sm text-neutral-600">{selectedIds.length} selected</p>
            </div>
          </form>
        )}
        {problem && <p role="alert" className="text-sm text-danger-700">{problem}</p>}
        {results.length > 0 && (
          <section aria-label="Invite results" className="rounded-xl border border-neutral-200 p-3">
            <h3 className="font-semibold">Invite results</h3>
            <ul className="divide-y divide-neutral-100">
              {results.map((row) => (
                <li key={row.id} className="space-y-1 py-2 text-sm [overflow-wrap:anywhere]">
                  <Link className={textLink} to={recordPath(row.id)}>{row.name}</Link>
                  <p className={row.error || row.email_status === 'failed' ? 'text-danger-700' : 'text-neutral-700'}>
                    {row.error || (row.codeCreated ? 'Code created.' : row.email_status && inviteEmailMessages[row.email_status])}
                  </p>
                </li>
              ))}
            </ul>
          </section>
        )}
        <PrintedInvites invites={printed} companyName={companyName} onClose={() => setPrinted([])} />
      </CardContent>
    </Card>
  );
}
