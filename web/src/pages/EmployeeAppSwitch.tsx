import { formatGuamDateTime } from '@/lib/utils';
import { formatDate } from '@/lib/display-date';
import { useCallback, useEffect, useId, useState, type FormEvent } from 'react';
import { isReverificationCancelledError } from '@clerk/react/errors';
import { CheckCircle2, ChevronDown, CircleAlert, Lock, ShieldAlert, XCircle } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { Alert } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { useCompany } from '@/contexts/CompanyContext';
import { useOptionalStepUpRequest } from '@/lib/useOptionalStepUpRequest';
import {
  employeeAppSwitchApi, switchRequest,
  type EmployeeAppSwitchState, type ReadinessCheck, type SwitchFailure, type SwitchRow,
} from '@/services/employee-app-switch-api';

const MASTER = 'employee_portal_enabled';

function formatDateTime(value: string | null): string {
  if (!value) return 'Never';
  return formatGuamDateTime(value, { second: undefined });
}

type Mutation = { method: 'PATCH' | 'PUT' | 'DELETE' | 'POST'; suffix: string; body: unknown };

export function EmployeeAppSwitch() {
  const { activeCompany } = useCompany();
  if (!activeCompany) return <WorkspaceLoader label="Loading client" />;
  return <CompanySwitch key={activeCompany.id} companyId={activeCompany.id} />;
}

function CompanySwitch({ companyId }: { companyId: number }) {
  const [state, setState] = useState<EmployeeAppSwitchState | null>(null);
  const [loadError, setLoadError] = useState('');
  const [checking, setChecking] = useState(false);
  const [notice, setNotice] = useState('');
  const [change, setChange] = useState<{ row: SwitchRow; on: boolean } | null>(null);
  const [stopping, setStopping] = useState(false);

  const load = useCallback(async () => {
    setChecking(true);
    try {
      const { data } = await employeeAppSwitchApi.get(companyId);
      setState(data);
      setLoadError('');
    } catch {
      setLoadError('Could not load the employee app switch. Try again.');
    } finally {
      setChecking(false);
    }
  }, [companyId]);

  useEffect(() => { void load(); }, [load]);

  const send = useOptionalStepUpRequest((token: string, mutation: Mutation) =>
    switchRequest(companyId, mutation.method, mutation.suffix, mutation.body)(token));

  // Resolves to null on success, or the server's failure body.
  const mutate = useCallback(async (mutation: Mutation): Promise<SwitchFailure | null> => {
    try {
      const response = await send(mutation);
      const body = await response.json().catch(() => null) as (SwitchFailure & { data?: EmployeeAppSwitchState }) | null;
      if (body?.data) setState(body.data);
      if (response.ok) return null;
      return body ?? { error: 'Could not save the change. Try again.' };
    } catch (failure) {
      if (isReverificationCancelledError(failure)) return { error: 'Sign-in check cancelled. Nothing was changed.' };
      return { error: 'Could not save the change. Check your connection and try again.' };
    }
  }, [send]);

  if (loadError && !state) {
    return (
      <>
        <Header title="Employee app switch" />
        <div className="space-y-3 p-4 sm:p-6 lg:p-8">
          <Alert tone="error">{loadError}</Alert>
          <Button variant="outline" onClick={() => void load()}>Try again</Button>
        </div>
      </>
    );
  }
  if (!state) return <WorkspaceLoader label="Checking readiness" />;

  const checks = [...state.readiness.checks, state.readiness.counsel_checks.terms, state.readiness.counsel_checks.consent];
  const names = Object.fromEntries(checks.map((check) => [check.key, plainName(check)]));
  const master = state.switches.find((item) => item.key === MASTER);

  return (
    <>
      <Header title="Employee app switch" description="Turn the employee app on for this company one part at a time." />
      <div className="mx-auto max-w-5xl space-y-6 p-4 sm:p-6 lg:p-8">
        <p className="max-w-3xl text-sm leading-6 text-neutral-700">
          Each part turns on only when every check it needs passes. Turning anything off always works, and every change needs a reason and is recorded in the activity history.
        </p>
        {notice && <Alert tone="success">{notice}</Alert>}
        {state.company.demo && (
          <Alert tone="info">
            <strong>Demo company.</strong> Until the database enforces row-level security, a demo can turn on only through the demo early-access rule below. Real companies always need every check.
          </Alert>
        )}

        {master && <ReadinessSummary master={master} checks={checks} names={names} />}

        <Card>
          <CardHeader className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <CardTitle>Readiness checklist</CardTitle>
              <CardDescription>Checked {formatDateTime(state.readiness.checked_at)}</CardDescription>
            </div>
            <Button variant="outline" size="sm" loading={checking} onClick={() => { setNotice(''); void load(); }}>Check again</Button>
          </CardHeader>
          <CardContent>
            <ul className="divide-y divide-neutral-100">
              {checks.map((check) => <CheckRow key={check.key} check={check} scope={scopeOf(check.key)} />)}
            </ul>
          </CardContent>
        </Card>

        <ObservedState state={state} />

        <Card>
          <CardHeader>
            <CardTitle>Switches</CardTitle>
            <CardDescription>Features work only while the employee app is on.</CardDescription>
          </CardHeader>
          <CardContent>
            <ul className="divide-y divide-neutral-100">
              {state.switches.map((row) => (
                <SwitchItem key={row.key} row={row} names={names}
                  masterOn={master?.on ?? false}
                  onChange={(on) => { setNotice(''); setChange({ row, on }); }} />
              ))}
              {state.stays_off.map((row) => (
                <li key={row.key} className="flex flex-col gap-2 py-4 sm:flex-row sm:items-center sm:justify-between">
                  <div className="min-w-0 pl-4 sm:pl-6">
                    <p className="font-semibold text-neutral-900">{row.label}</p>
                    <p className="text-sm text-neutral-600">{row.description}</p>
                  </div>
                  <Badge variant="outline"><Lock className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Locked off</Badge>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>

        {state.company.demo && <EarlyAccessCard state={state} mutate={mutate} onSaved={setNotice} />}
        {state.company.demo && (
          <Card className="border-danger-200">
            <CardHeader>
              <CardTitle>Stop all demo employee access</CardTitle>
              <CardDescription>
                For a problem with a demo. Turns every demo company's employee app off, ends early access, cancels pending demo invitations, ends demo sign-ins and support views, and stops demo employee emails. Demo data and the activity history stay.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <Button variant="danger" onClick={() => { setNotice(''); setStopping(true); }}>Stop demo employee access</Button>
            </CardContent>
          </Card>
        )}
      </div>

      {change && (
        <ChangeDialog row={change.row} on={change.on} state={state} names={names} mutate={mutate}
          onClose={() => setChange(null)}
          onSaved={(message) => { setChange(null); setNotice(message); }} />
      )}
      {stopping && (
        <ReasonDialog title="Stop demo employee access" confirmLabel="Stop demo access" danger
          description="Every demo company's employee app turns off right away. You can turn parts back on later, after the checks pass."
          onClose={() => setStopping(false)}
          onSubmit={async (reason) => {
            const failure = await mutate({ method: 'POST', suffix: '/demo_stop', body: { reason } });
            if (!failure) { setStopping(false); setNotice('Demo employee access stopped.'); }
            return failure?.error ?? null;
          }} />
      )}
    </>
  );
}

type Owner = 'Cornerstone' | 'Shimizu Technology';

// Plain names for the server's checks. The server's own wording, with its
// setting names, stays under Technical details for whoever fixes it.
const CHECK_COPY: Record<string, { label: string; owner: Owner }> = {
  company: { label: 'This is an active client or a demo company', owner: 'Cornerstone' },
  mfa: { label: 'Two-step sign-in is turned on', owner: 'Shimizu Technology' },
  rls_guard: { label: "The employee app reads only this company's records", owner: 'Shimizu Technology' },
  rls_database: { label: "The database keeps each company's records apart", owner: 'Shimizu Technology' },
  authorized_parties: { label: 'Sign-in works only from our own web addresses', owner: 'Shimizu Technology' },
  subdomain: { label: "The company's web address is set", owner: 'Cornerstone' },
  employee_service: { label: "The employee app's server is running", owner: 'Shimizu Technology' },
  terms: { label: 'The employee app terms and privacy notice are ready', owner: 'Cornerstone' },
  consent: { label: 'The electronic delivery consent wording is ready', owner: 'Cornerstone' },
};

function plainName(check: ReadinessCheck): string {
  return CHECK_COPY[check.key]?.label ?? check.name;
}

function ReadinessSummary({ master, checks, names }: { master: SwitchRow; checks: ReadinessCheck[]; names: Record<string, string> }) {
  const failing = checks.filter((check) => check.status === 'failed').length;
  const blocking = master.blocked_by;
  const ready = master.on || blocking.length === 0;
  const title = master.on ? 'The employee app is on'
    : ready ? 'Ready to turn on'
      : `Not ready yet: ${blocking.length} ${blocking.length === 1 ? 'thing' : 'things'} to fix`;
  // A waived check doesn't pass, so "every check passes" would overstate it.
  // Only a demo in an early-access window waives the database check; two-step
  // sign-in is waived for every company until it's turned on for everyone.
  const waived = checks.filter((check) => check.status === 'waived');
  const earlyAccess = waived.some((check) => check.key === 'rls_database') ? ' under demo early access (database check waived)' : '';
  const notes = waived.filter((check) => check.key !== 'rls_database')
    .map((check) => check.key === 'mfa' ? "Two-step sign-in isn't required yet." : `${names[check.key] ?? check.key} is waived.`).join(' ');
  const noteText = notes ? ` ${notes}` : '';
  const summary = master.on
    ? failing ? `${failing} ${failing === 1 ? 'check needs' : 'checks need'} attention. Parts that depend on ${failing === 1 ? 'it' : 'them'} can't turn on.`
      : earlyAccess ? `On${earlyAccess}.${noteText}` : notes ? `Every other check passes.${noteText}` : 'Every check passes.'
    // Scoped to the app's own checks: a feature's failing check (consent, say)
    // doesn't block the app and stays listed in the checklist below.
    : ready ? `${earlyAccess ? `Ready to turn on${earlyAccess}.` : notes ? 'Every other check the employee app needs passes.' : 'Every check the employee app needs passes.'}${noteText} Turn it on under Switches below.`
      : 'These checks must pass before the employee app can turn on:';
  return (
    <section aria-labelledby="readiness-summary" className={`rounded-xl border p-4 ${ready ? 'border-success-200 bg-success-50' : 'border-warning-200 bg-warning-50'}`}>
      <div className="flex gap-3">
        {ready
          ? <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-success-700" aria-hidden="true" />
          : <CircleAlert className="mt-0.5 h-5 w-5 shrink-0 text-warning-700" aria-hidden="true" />}
        <div className="min-w-0">
          <h2 id="readiness-summary" className="font-semibold text-neutral-950">{title}</h2>
          <p className="mt-1 text-sm text-neutral-700">{summary}</p>
          {!ready && (
            <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-neutral-800">
              {blocking.map((key) => (
                <li key={key} className="[overflow-wrap:anywhere]">
                  {names[key] ?? key}
                  {CHECK_COPY[key] && <span className="text-neutral-600"> · {CHECK_COPY[key].owner} fixes this</span>}
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </section>
  );
}

function scopeOf(key: string): string | null {
  if (key === 'terms') return 'Needed for the employee app';
  if (key === 'consent') return 'Needed for electronic delivery consent';
  return null;
}

// Two-step sign-in is waived for every company while REQUIRE_MFA is off; the
// database check is waived only for a demo under early access.
function waivedLabel(key: string): string {
  return key === 'mfa' ? 'Not required yet' : 'Waived for demo';
}

function CheckRow({ check, scope }: { check: ReadinessCheck; scope: string | null }) {
  const owner = CHECK_COPY[check.key]?.owner;
  // Cornerstone's own checks and waivers explain themselves in plain words;
  // the platform checks name server settings, so they stay in the details.
  const plainDetail = owner === 'Cornerstone' || check.status === 'waived';
  const icon = check.status === 'passed'
    ? <CheckCircle2 className="h-5 w-5 text-success-700" aria-hidden="true" />
    : check.status === 'waived'
      ? <ShieldAlert className="h-5 w-5 text-warning-700" aria-hidden="true" />
      : <XCircle className="h-5 w-5 text-danger-700" aria-hidden="true" />;
  const label = check.status === 'passed' ? 'Passed' : check.status === 'waived' ? waivedLabel(check.key) : 'Not ready';
  return (
    <li className="flex gap-3 py-3">
      <span className="mt-0.5 shrink-0">{icon}</span>
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <p className="font-medium text-neutral-900 [overflow-wrap:anywhere]">{plainName(check)}</p>
          <Badge variant={check.status === 'passed' ? 'success' : check.status === 'waived' ? 'warning' : 'danger'}>{label}</Badge>
        </div>
        {scope && <p className="text-xs font-medium text-neutral-500">{scope}</p>}
        {check.status === 'failed' && owner && <p className="mt-1 text-xs font-semibold text-neutral-600">{owner} fixes this</p>}
        {check.detail && plainDetail && <p className="mt-1 text-sm text-neutral-700 [overflow-wrap:anywhere]">{check.detail}</p>}
        {check.status !== 'passed' && (check.name !== plainName(check) || (check.detail && !plainDetail)) && (
          <details className="mt-1 text-sm">
            <summary className="cursor-pointer text-neutral-600 hover:text-neutral-900">Technical details</summary>
            <div className="mt-1 space-y-1 rounded-lg bg-neutral-50 p-2 text-neutral-700 [overflow-wrap:anywhere]">
              <p>{check.name}</p>
              {check.detail && !plainDetail && <p>{check.detail}</p>}
            </div>
          </details>
        )}
      </div>
    </li>
  );
}

function ObservedState({ state }: { state: EmployeeAppSwitchState }) {
  const { observed, database } = state.readiness;
  const guard = !observed.reported ? 'No signed answer'
    : observed.rls_guard_mode === 'raise' ? 'Raise (refuses reads without a company)'
      : observed.rls_guard_mode === 'log' ? 'Log only' : 'Off';
  const phase = database.phase === 'enforced' ? 'Enforced'
    : database.phase === 'shadow' ? 'Shadow (policies installed, not enforced)'
      : database.phase === 'partial' ? 'Partly enforced'
        : database.phase === 'bypassed' ? 'Bypassed by the kill switch'
          : database.phase === 'not_installed' ? 'Policies not installed' : 'Unknown';
  const killSwitch = database.kill_switch_bypass === false ? 'Off' : database.kill_switch_bypass ? 'Bypassing' : 'Unknown';
  return (
    <Card>
      <details className="group">
        <summary className="cursor-pointer list-none px-4 py-4 sm:px-6 sm:py-5 [&::-webkit-details-marker]:hidden">
          <span className="flex items-center justify-between gap-3">
            <span>
              <CardTitle>Technical details: what the system sees</CardTitle>
              <CardDescription className="mt-1">For Shimizu Technology. The employee service's guard and the database are separate. The employee service's settings come from its signed answer to this check.</CardDescription>
            </span>
            <ChevronDown className="h-5 w-5 shrink-0 text-neutral-500 transition-transform group-open:rotate-180" aria-hidden="true" />
          </span>
        </summary>
        <CardContent className="grid gap-4 md:grid-cols-2">
          <section className="rounded-xl border border-neutral-200 p-4" aria-labelledby="observed-service">
            <h3 id="observed-service" className="font-semibold text-neutral-900">Employee service</h3>
            <dl className="mt-2 space-y-2 text-sm">
              <Fact term="RLS guard" value={guard} good={observed.rls_guard_mode === 'raise'} />
              <Fact term="Database role" value={observed.rls_runtime_role_verified ? 'Restricted role verified' : 'Not verified'} good={observed.rls_runtime_role_verified} />
              <Fact term="Health check" value={!observed.health_check_configured ? 'Not set up on Payroll' : observed.answered_health_check ? 'Answered' : 'No answer'} good={observed.answered_health_check} />
              <Fact term="Signed answer" value={observed.verified ? `Verified${observed.revision ? ` (revision ${observed.revision.slice(0, 12)})` : ''}` : 'Not verified'} good={observed.verified} />
            </dl>
          </section>
          <section className="rounded-xl border border-neutral-200 p-4" aria-labelledby="observed-database">
            <h3 id="observed-database" className="font-semibold text-neutral-900">Database</h3>
            <dl className="mt-2 space-y-2 text-sm">
              <Fact term="Row-level security" value={phase} good={database.enforced} />
              <Fact term="Protected tables enforced" value={`${database.enforced_tables} of ${database.protected_tables}`} good={database.enforced} />
              <Fact term="RLS kill switch" value={killSwitch} good={database.kill_switch_bypass === false} />
            </dl>
          </section>
        </CardContent>
      </details>
    </Card>
  );
}

function Fact({ term, value, good }: { term: string; value: string; good: boolean }) {
  return (
    <div className="flex flex-col gap-0.5 sm:flex-row sm:justify-between sm:gap-4">
      <dt className="text-neutral-600">{term}</dt>
      <dd className={`font-medium [overflow-wrap:anywhere] ${good ? 'text-success-800' : 'text-neutral-900'}`}>{value}</dd>
    </div>
  );
}

function SwitchItem({ row, names, masterOn, onChange }: {
  row: SwitchRow; names: Record<string, string>; masterOn: boolean; onChange: (on: boolean) => void;
}) {
  const needsMaster = row.feature && !masterOn;
  const blocked = row.blocked_by.length > 0;
  return (
    <li className="flex flex-col gap-3 py-4 sm:flex-row sm:items-center sm:justify-between">
      <div className={`min-w-0 ${row.feature ? 'pl-4 sm:pl-6' : ''}`}>
        <div className="flex flex-wrap items-center gap-2">
          <p className="font-semibold text-neutral-900">{row.label}</p>
          <Badge variant={row.on ? 'success' : 'default'}>{row.on ? 'On' : 'Off'}</Badge>
          {row.on && !row.open_today && <Badge variant="warning">Not open to employees yet</Badge>}
        </div>
        <p className="text-sm text-neutral-600">{row.description}</p>
        {!row.on && needsMaster && <p className="mt-1 text-sm text-neutral-600">Turn on the employee app first.</p>}
        {!row.on && !needsMaster && blocked && (
          <p className="mt-1 flex gap-1.5 text-sm text-danger-800">
            <CircleAlert className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            <span>
              Can't turn on yet: {row.blocked_by.length} {row.blocked_by.length === 1 ? 'check' : 'checks'} to finish
              {row.blocked_by.length === 1 ? ` (${names[row.blocked_by[0]] ?? row.blocked_by[0]})` : ''}. See the readiness checklist above.
            </span>
          </p>
        )}
      </div>
      {row.on
        ? <Button variant="outline" className="w-full sm:w-auto" onClick={() => onChange(false)}>Turn off</Button>
        : <Button className="w-full sm:w-auto" disabled={needsMaster || blocked} onClick={() => onChange(true)}>Turn on</Button>}
    </li>
  );
}

function ChangeDialog({ row, on, state, names, mutate, onClose, onSaved }: {
  row: SwitchRow; on: boolean; state: EmployeeAppSwitchState; names: Record<string, string>;
  mutate: (mutation: Mutation) => Promise<SwitchFailure | null>;
  onClose: () => void; onSaved: (message: string) => void;
}) {
  const [failing, setFailing] = useState<ReadinessCheck[]>([]);
  const alsoOff = !on && row.key === MASTER ? state.switches.filter((item) => item.feature && item.on).map((item) => item.label) : [];
  return (
    <ReasonDialog
      title={`${on ? 'Turn on' : 'Turn off'} ${row.label}`}
      description={on
        ? `${row.description} This takes effect today for ${state.company.name}.`
        : `Employees lose this right away. ${alsoOff.length ? `This also turns off: ${alsoOff.join(', ')}.` : ''}`}
      confirmLabel={on ? 'Turn on' : 'Turn off'}
      danger={!on}
      extra={failing.length > 0 && (
        <div className="rounded-lg border border-danger-200 bg-danger-50 p-3 text-sm text-danger-950" role="alert">
          <p className="font-semibold">These checks are failing:</p>
          <ul className="mt-1 list-disc space-y-1 pl-5">
            {failing.map((check) => <li key={check.key}>{names[check.key] ?? check.name}{check.detail ? ` ${check.detail}` : ''}</li>)}
          </ul>
        </div>
      )}
      onClose={onClose}
      onSubmit={async (reason) => {
        const failure = await mutate({ method: 'PATCH', suffix: '', body: { changes: { [row.key]: on }, reason } });
        if (!failure) { onSaved(`${row.label} is ${on ? 'on' : 'off'}.`); return null; }
        setFailing(failure.failing_checks ?? []);
        return failure.error ?? 'Could not save the change.';
      }} />
  );
}

function ReasonDialog({ title, description, confirmLabel, danger = false, extra, onClose, onSubmit }: {
  title: string; description: string; confirmLabel: string; danger?: boolean; extra?: React.ReactNode;
  onClose: () => void; onSubmit: (reason: string) => Promise<string | null>;
}) {
  const reasonId = useId();
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState('');

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!reason.trim() || busy) return;
    setBusy(true);
    setProblem('');
    const error = await onSubmit(reason.trim());
    setBusy(false);
    if (error) setProblem(error);
  }

  return (
    <Dialog open dismissOnEscape={!busy} onOpenChange={(open) => { if (!open && !busy) onClose(); }}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <form className="space-y-4" onSubmit={(event) => void submit(event)}>
          <DialogHeader>
            <DialogTitle>{title}</DialogTitle>
            <DialogDescription>{description}</DialogDescription>
          </DialogHeader>
          <div className="space-y-1.5">
            <label htmlFor={reasonId} className="text-sm font-semibold">Reason</label>
            <Textarea id={reasonId} required maxLength={500} className="text-base" value={reason}
              onChange={(event) => setReason(event.target.value)} disabled={busy} />
          </div>
          {extra}
          {problem && <p role="alert" className="text-sm text-danger-700">{problem}</p>}
          <DialogFooter>
            <Button type="button" variant="outline" disabled={busy} onClick={onClose}>Cancel</Button>
            <Button type="submit" variant={danger ? 'danger' : 'primary'} loading={busy} disabled={!reason.trim()}>{confirmLabel}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function EarlyAccessCard({ state, mutate, onSaved }: {
  state: EmployeeAppSwitchState;
  mutate: (mutation: Mutation) => Promise<SwitchFailure | null>;
  onSaved: (message: string) => void;
}) {
  const info = state.early_access;
  const current = info.windows.find((window) => window.status === 'in_effect');
  const dateId = useId();
  const reasonId = useId();
  const [expiresOn, setExpiresOn] = useState('');
  const [selected, setSelected] = useState<number[]>([state.company.id]);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState('');
  const [ending, setEnding] = useState(false);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy) return;
    setBusy(true);
    setProblem('');
    const failure = await mutate({ method: 'PUT', suffix: '/early_access', body: { expires_on: expiresOn, company_ids: selected, reason: reason.trim() } });
    setBusy(false);
    if (failure) { setProblem(failure.error ?? 'Could not set early access.'); return; }
    setReason('');
    onSaved('Demo early access is set.');
  }

  const toggle = (id: number) => setSelected((ids) => (ids.includes(id) ? ids.filter((value) => value !== id) : [...ids, id]));

  return (
    <Card>
      <CardHeader>
        <CardTitle>{info.name}</CardTitle>
        <CardDescription>
          With the owner's approval, the named demo companies can turn on before the database enforces row-level security, as long as the employee service's guard is in raise mode. Every other check still applies. After the expiry date the demo's employee app closes on its own. Once the database enforces row-level security the window retires for good.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        {current ? (
          <div className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm text-warning-950">
            <p className="font-semibold">In effect through {formatDate(current.expires_on)}</p>
            <p className="mt-1 [overflow-wrap:anywhere]">Covers {current.companies.map((company) => company.name ?? `Company ${company.id}`).join(' and ')}.</p>
            <p className="mt-1 [overflow-wrap:anywhere]">Approved by {current.approved_by ?? 'the owner'} on {formatDateTime(current.set_at)}: {current.reason}</p>
            <Button variant="outline" size="sm" className="mt-3" onClick={() => setEnding(true)}>End early access now</Button>
          </div>
        ) : (
          <p className="text-sm text-neutral-700">No early-access window is in effect.</p>
        )}

        {!info.can_set && (
          <p className="text-sm text-neutral-700">Only the owner (a super admin) can set or extend early access.</p>
        )}
        {info.can_set && (
        <form className="space-y-4 rounded-xl border border-neutral-200 p-4" onSubmit={(event) => void submit(event)}>
          <h3 className="font-semibold text-neutral-900">{current ? 'Extend or replace the window' : 'Set a window'}</h3>
          <fieldset disabled={busy} className="space-y-4">
            <div className="space-y-1.5">
              <label htmlFor={dateId} className="text-sm font-semibold">Owner-approved expiry date</label>
              <Input id={dateId} type="date" required className="text-base sm:max-w-xs" value={expiresOn} onChange={(event) => setExpiresOn(event.target.value)} />
              <p className="text-xs text-neutral-600">Up to {info.max_days} days from today.</p>
            </div>
            <fieldset className="space-y-1">
              <legend className="text-sm font-semibold">Demo companies (up to {info.max_companies})</legend>
              {info.demo_companies.map((company) => (
                <label key={company.id} className="flex min-h-11 items-center gap-2 text-sm">
                  <input type="checkbox" className="h-4 w-4 accent-primary-700" checked={selected.includes(company.id)} onChange={() => toggle(company.id)} />
                  <span className="[overflow-wrap:anywhere]">{company.name}</span>
                </label>
              ))}
            </fieldset>
            <div className="space-y-1.5">
              <label htmlFor={reasonId} className="text-sm font-semibold">Reason and owner approval</label>
              <Textarea id={reasonId} required maxLength={500} className="text-base" value={reason} onChange={(event) => setReason(event.target.value)} />
            </div>
          </fieldset>
          {problem && <p role="alert" className="text-sm text-danger-700">{problem}</p>}
          <Button type="submit" loading={busy} disabled={!expiresOn || !reason.trim() || selected.length === 0} className="w-full sm:w-auto">
            {current ? 'Replace early access' : 'Set early access'}
          </Button>
        </form>
        )}

        {info.windows.length > 0 && (
          <div>
            <h3 className="text-sm font-semibold text-neutral-900">Recent windows</h3>
            <ul className="mt-2 space-y-2 text-sm">
              {info.windows.map((window) => (
                <li key={window.id} className="rounded-lg bg-neutral-50 p-3 [overflow-wrap:anywhere]">
                  <span className="font-medium">{window.status === 'in_effect' ? 'In effect' : window.status === 'expired' ? 'Expired' : window.status === 'retired' ? 'Retired' : 'Ended'}</span>
                  {' '}· through {formatDate(window.expires_on)} · approved by {window.approved_by ?? 'the owner'} on {formatDateTime(window.set_at)}
                  {window.ended_at && <> · ended by {window.ended_by ?? 'an admin'}: {window.end_reason}</>}
                </li>
              ))}
            </ul>
          </div>
        )}
      </CardContent>
      {ending && (
        <ReasonDialog title="End early access" confirmLabel="End early access" danger
          description="The database exception ends right away. While the database still doesn't enforce row-level security, any demo employee app parts that are on turn off too."
          onClose={() => setEnding(false)}
          onSubmit={async (endReason) => {
            const failure = await mutate({ method: 'DELETE', suffix: '/early_access', body: { reason: endReason } });
            if (!failure) { setEnding(false); onSaved('Demo early access ended.'); }
            return failure?.error ?? null;
          }} />
      )}
    </Card>
  );
}
