import { useCallback, useEffect, useId, useState, type FormEvent } from 'react';
import { Link, useLocation } from 'react-router';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Textarea } from '@/components/ui/textarea';
import { employeeAppRolloutPath, employeeEditPath } from '@/lib/routes';
import { ApiError } from '@/services/api';
import {
  employeeAppOff, employeeAppRolloutApi, formatEmployeeAppDate, inviteEmailMessages,
  type EmployeeAppAccess, type EmployeeAppOperation, type EmployeeAppStatus, type InviteDelivery, type PrintedInvite,
} from '@/services/employee-app-rollout-api';
import { InviteDeliveryField } from './InviteDeliveryField';
import { PrintedInvites } from './PrintedInvites';

const labels: Record<EmployeeAppStatus, string> = {
  not_invited: 'Not invited', invited: 'Invited', active: 'Active',
  locked: 'Locked', former: 'Former', revoked: 'Revoked',
};
const operations: Record<EmployeeAppOperation, { label: string; description: string }> = {
  invite: { label: 'Invite', description: 'Give this employee a one-time invitation to set up the app.' },
  resend: { label: 'Resend invite', description: 'Issue a new invitation. The previous email or printed code will stop working.' },
  unlock: { label: 'Unlock sign-up', description: 'Let the employee try signing up again with their current invitation.' },
  revoke: { label: 'Revoke access', description: 'End this employee’s app access immediately. This also cancels any outstanding invitation.' },
  reset_sign_up: { label: 'Reset sign-up', description: 'Clear the unfinished sign-up and issue a new invitation. The employee will need to start again.' },
};

export function EmployeeAppPanel({ companyId, companyName, employeeId, audience }: {
  companyId: number;
  companyName: string;
  employeeId: number;
  audience: 'admin' | 'client';
}) {
  const [access, setAccess] = useState<EmployeeAppAccess | null>(null);
  const [loadError, setLoadError] = useState('');
  const [loadAttempt, setLoadAttempt] = useState(0);
  const [operation, setOperation] = useState<EmployeeAppOperation | null>(null);
  const [feedback, setFeedback] = useState('');
  const [printed, setPrinted] = useState<PrintedInvite[]>([]);
  const location = useLocation();
  const getAccess = useCallback(() => employeeAppRolloutApi(companyId, audience).employee(employeeId), [companyId, audience, employeeId]);

  useEffect(() => {
    let current = true;
    void getAccess().then(({ data }) => {
      if (current) { setAccess(data); setLoadError(''); }
    }).catch(() => {
      if (current) setLoadError('Could not load employee app status.');
    });
    return () => { current = false; };
  }, [getAccess, loadAttempt]);

  const open = access?.status === 'invited' || access?.status === 'locked';
  const canInvite = access?.enabled && access.can_manage_invites;
  const actions: EmployeeAppOperation[] = [];
  if (canInvite && access.can_invite) actions.push('invite');
  if (canInvite && open && !access.reset_pending) actions.push('resend');
  if (access?.staff_actions && access.status === 'locked' && !access.reset_pending) actions.push('unlock');
  if (canInvite && access.staff_actions && open) actions.push('reset_sign_up');
  if (access?.staff_actions && (open || access.status === 'active' || access.status === 'former')) actions.push('revoke');

  return (
    <Card>
      <CardHeader className="flex flex-wrap items-center justify-between gap-2 space-y-0">
        <CardTitle>Employee app</CardTitle>
        <Link className="inline-flex min-h-11 items-center text-sm font-semibold text-primary-800 underline" to={employeeAppRolloutPath(companyId)}>Company rollout</Link>
      </CardHeader>
      <CardContent className="space-y-3">
        {loadError ? (
          <div className="flex flex-wrap items-center gap-2"><p role="alert" className="text-sm text-danger-700">{loadError}</p><Button type="button" variant="outline" onClick={() => setLoadAttempt((attempt) => attempt + 1)}>Try again</Button></div>
        ) : !access ? <p role="status" className="text-sm text-neutral-600">Loading app status…</p> : (
          <>
            <Badge variant={access.status === 'active' ? 'success' : access.status === 'locked' ? 'warning' : 'default'}>{labels[access.status]}</Badge>
            {!access.enabled && <p className="text-sm text-neutral-700">{employeeAppOff}</p>}
            {access.status === 'former' && access.former_access_until && <p className="text-sm">Former employee access through {formatEmployeeAppDate(access.former_access_until)}.</p>}
            {open && access.invite_expires_at && !access.reset_pending && (
              <p className="text-sm">Invitation {new Date(access.invite_expires_at).getTime() <= Date.now() ? 'expired' : 'expires'} {formatEmployeeAppDate(access.invite_expires_at)}.</p>
            )}
            {access.status === 'locked' && access.locked_until && <p className="text-sm">Sign-up locked until {formatEmployeeAppDate(access.locked_until, true)} (Guam time). {!access.staff_actions && "Ask Cornerstone if this employee needs help unlocking sign-up."}</p>}
            {access.reset_pending && <p className="text-sm font-medium text-amber-800">Sign-up reset is waiting to finish. {access.staff_actions ? 'Choose Reset sign-up to finish it.' : 'Ask Cornerstone to finish the reset.'}</p>}
            <div className="flex flex-wrap items-center gap-3 text-sm">
              <span className="[overflow-wrap:anywhere]">{access.email || 'No email on file'}</span>
              <Link className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline" to={employeeEditPath(companyId, employeeId, { returnTo: location.pathname + location.search })}>Edit contact details</Link>
            </div>
            {feedback && <p role="status" className="rounded-lg bg-neutral-50 p-3 text-sm font-medium text-neutral-900">{feedback}</p>}
            {actions.length > 0 && (
              <div className="flex flex-wrap gap-2">
                {actions.map((action) => (
                  <Button key={action} type="button" variant={action === 'invite' || action === 'resend' ? 'primary' : 'outline'} onClick={() => { setFeedback(''); setOperation(action); }}>
                    {operations[action].label}
                  </Button>
                ))}
              </div>
            )}
            {operation && <EmployeeAppAction
              access={access}
              operation={operation}
              onClose={() => setOperation(null)}
              submit={(payload) => employeeAppRolloutApi(companyId, audience).change(employeeId, operation, payload)}
              refresh={() => setLoadAttempt((attempt) => attempt + 1)}
              onSuccess={(result) => {
                setAccess(result.data);
                setOperation(null);
                if (result.print) setPrinted([result.print]);
                else if (result.email_status) setFeedback(inviteEmailMessages[result.email_status]);
                else setFeedback(operation === 'unlock' ? 'Sign-up unlocked.' : 'App access revoked.');
              }}
            />}
          </>
        )}
        <PrintedInvites invites={printed} companyName={companyName} onClose={() => setPrinted([])} />
      </CardContent>
    </Card>
  );
}

type Change = ReturnType<typeof employeeAppRolloutApi>['change'];
type ChangeResponse = Awaited<ReturnType<Change>>;

function EmployeeAppAction({ access, operation, submit, onClose, onSuccess, refresh }: {
  access: EmployeeAppAccess;
  operation: EmployeeAppOperation;
  submit: (payload: Parameters<Change>[2]) => ReturnType<Change>;
  onClose: () => void;
  onSuccess: (response: ChangeResponse) => void;
  refresh: () => void;
}) {
  const reasonId = useId();
  const [delivery, setDelivery] = useState<InviteDelivery>(
    operation === 'invite' ? (access.email ? 'email' : 'code') : (access.invite_delivery || 'code'),
  );
  const [reason, setReason] = useState('');
  const [confirmEmail, setConfirmEmail] = useState(false);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState('');
  const [alreadyRegistered, setAlreadyRegistered] = useState(false);
  const sendsInvite = operation === 'invite' || operation === 'resend' || operation === 'reset_sign_up';
  const needsReason = operation === 'revoke' || operation === 'reset_sign_up';
  const { label, description } = operations[operation];

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy || alreadyRegistered) return;
    setBusy(true);
    setProblem('');
    try {
      onSuccess(await submit({
        access_id: access.access_id, delivery: sendsInvite ? delivery : undefined,
        reason: needsReason ? reason.trim() : undefined,
        confirm_same_person_email: sendsInvite && delivery === 'email' && confirmEmail,
      }));
    } catch (caught) {
      setProblem(caught instanceof Error ? caught.message : 'Could not complete this action. Try again.');
      setAlreadyRegistered(caught instanceof ApiError && (caught.data as { code?: string } | undefined)?.code === 'sign_up_accepted');
      refresh();
    } finally {
      setBusy(false);
    }
  }

  return (
    <Dialog open dismissOnEscape={!busy} onOpenChange={(open) => { if (!open && !busy) onClose(); }}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <form className="space-y-4" onSubmit={(event) => void save(event)}>
          <DialogHeader>
            <DialogTitle>{label}</DialogTitle>
            <DialogDescription>{description}</DialogDescription>
          </DialogHeader>
          <p className="text-sm font-semibold [overflow-wrap:anywhere]">{access.name}</p>
          {sendsInvite && !alreadyRegistered && <>
            <InviteDeliveryField value={delivery} onChange={setDelivery} disabled={busy} />
            {delivery === 'email' && (
              access.email
                ? <div className="space-y-2 text-sm">
                  <p className="[overflow-wrap:anywhere]">Send to <strong>{access.email}</strong></p>
                  <label className="flex min-h-11 items-center gap-2">
                    <input type="checkbox" className="accent-primary-700" checked={confirmEmail} disabled={busy} onChange={(event) => setConfirmEmail(event.target.checked)} />
                    {access.staff_actions ? 'I confirm any existing payroll account with this email belongs to this employee.' : 'If this is my payroll sign-in email, I confirm this is my own employee record.'}
                  </label>
                </div>
                : <p className="text-sm text-neutral-700">Add a personal email in contact details, or choose Printed code.</p>
            )}
          </>}
          {needsReason && (
            <div className="space-y-1.5">
              <label htmlFor={reasonId} className="text-sm font-semibold">Reason</label>
              <Textarea id={reasonId} required maxLength={500} className="text-base" value={reason} onChange={(event) => setReason(event.target.value)} disabled={busy} />
            </div>
          )}
          {problem && <p role={alreadyRegistered ? 'status' : 'alert'} className={alreadyRegistered ? 'rounded-lg bg-blue-50 p-3 text-sm text-blue-950' : 'text-sm text-danger-700'}>{problem}</p>}
          <DialogFooter>
            <Button type="button" variant="outline" disabled={busy} onClick={onClose}>{alreadyRegistered ? 'Done' : 'Cancel'}</Button>
            {!alreadyRegistered && (
              <Button type="submit" variant={operation === 'revoke' ? 'danger' : 'primary'} loading={busy}
                disabled={(needsReason && !reason.trim()) || (sendsInvite && delivery === 'email' && !access.email)}>
                {sendsInvite && delivery === 'code' ? (operation === 'reset_sign_up' ? 'Reset and create code' : 'Create code') : label}
              </Button>
            )}
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
