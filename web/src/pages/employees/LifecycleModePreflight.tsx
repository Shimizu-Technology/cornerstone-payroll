import { useId, useRef, useState, type FormEvent } from 'react';
import { Link } from 'react-router';
import { Alert } from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Textarea } from '@/components/ui/textarea';
import { formatDate } from '@/lib/display-date';
import { safeInternalReturnPath } from '@/lib/routes';
import type { OperatingProfileResponse } from '@/services/operating-profile';
import { LIFECYCLE_MODE_KEY, staffEmployeeLifecycleApi, type LifecyclePreflight } from '@/services/staff-employee-lifecycle';

export function LifecyclePreflightSummary({ checks, companyId }: { checks: LifecyclePreflight; companyId: number }) {
  return <div className="mt-3 space-y-2 rounded-lg bg-neutral-50 p-3 text-sm text-neutral-800">
    <h3 className="font-semibold">Before switching to client-managed mode</h3>
    <LifecyclePreflightChecks checks={checks} companyId={companyId} showPassed />
  </div>;
}

function LifecyclePreflightChecks({ checks, companyId, showPassed = false }: {
  checks: LifecyclePreflight['lifecycle_mode_activation_blockers'];
  companyId: number;
  showPassed?: boolean;
}) {
  const pending = checks.pending_non_address_change_requests_count;
  const recipients = checks.qualifying_staff_notification_recipients_count;
  const linkClass = 'inline-flex min-h-11 items-center font-semibold underline';
  return <ul className="list-disc space-y-1 pl-5">
    {pending ? <li>
      {pending} pending employee change {pending === 1 ? 'request' : 'requests'} to review.{' '}
      <Link className={linkClass} to={`/companies/${companyId}/client-change-requests`}>Review change requests</Link>
    </li> : showPassed && <li>No pending employee change requests</li>}
    {checks.active_intake_window ? <li>
      {showPassed ? 'The incomplete-employee entry window is open.' : 'The incomplete-employee entry window was open when the switch was attempted.'}{' '}
      <Link className={linkClass} to={`/companies/${companyId}/employees`}>Open employee entry settings</Link>
    </li> : showPassed && <li>Incomplete-employee entry window is closed</li>}
    {recipients === 0 ? <li>
      {showPassed ? 'Add at least one staff notification recipient.' : 'No qualifying staff notification recipients were configured when the switch was attempted.'}{' '}
      <Link className={linkClass} to={`/companies/${companyId}/client-documents#portal-alert-recipients`}>Manage notification recipients</Link>
    </li> : showPassed && <li>{recipients} staff notification {recipients === 1 ? 'recipient' : 'recipients'} configured</li>}
  </ul>;
}

export function BlockedLifecycleActivation({ profile, companyId, disabled, inboxReturn, onUpdated }: {
  profile: OperatingProfileResponse;
  companyId: number;
  disabled: boolean;
  inboxReturn: string | null;
  onUpdated: (profile: OperatingProfileResponse) => void;
}) {
  const checks = profile.employee_lifecycle_preflight;
  const [reverting, setReverting] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const reasonId = useId();
  const revertTrigger = useRef<HTMLButtonElement>(null);
  if (checks?.lifecycle_mode_activation_status !== 'blocked') return null;

  const scheduledDate = checks.scheduled_effective_on;
  const blockers = checks.lifecycle_mode_activation_blockers;
  const canChange = profile.editable_keys.includes(LIFECYCLE_MODE_KEY) && !profile.locked_keys.includes(LIFECYCLE_MODE_KEY);

  async function act(action: 'retry' | 'revert') {
    if (!canChange || busy || disabled || (action === 'revert' && (!scheduledDate || !reason.trim()))) return;
    setBusy(true);
    setError('');
    try {
      const updated = action === 'retry' ? await staffEmployeeLifecycleApi.retryActivation(companyId)
        : await staffEmployeeLifecycleApi.revertActivation(companyId, { effective_on: scheduledDate!, lock_version: profile.lock_version, reason: reason.trim() });
      setReverting(false);
      setReason('');
      onUpdated(updated);
      window.dispatchEvent(new Event('portal-work-changed'));
    } catch (problem) {
      setError(problem instanceof Error ? problem.message : 'Could not update the scheduled switch.');
    } finally {
      setBusy(false);
    }
  }

  return <>
    <Alert tone="warning">
      <h2 className="font-semibold">Scheduled employee lifecycle switch blocked</h2>
      <p>{scheduledDate ? `The switch scheduled for ${formatDate(scheduledDate)} could not activate. ` : ''}Cornerstone still approves employee changes first.</p>
      <LifecyclePreflightChecks checks={blockers} companyId={companyId} />
      {!reverting && error && <p role="alert" className="font-medium text-danger-800">{error}</p>}
      <div className="mt-3 flex flex-wrap gap-2">
        {canChange && <>
          <Button type="button" className="min-h-11!" disabled={disabled || busy}
            onClick={() => void act('retry')}>{busy && !reverting ? 'Retrying…' : 'Retry activation'}</Button>
          <Button ref={revertTrigger} type="button" className="min-h-11!" variant="outline" disabled={disabled || busy || !scheduledDate}
            onClick={() => { setError(''); setReverting(true); }}>Revert to Cornerstone approval</Button>
        </>}
        {inboxReturn && <Link className="inline-flex min-h-11 items-center underline" to={safeInternalReturnPath(inboxReturn, '/app/client-inbox')}>Back to Client Inbox</Link>}
      </div>
    </Alert>
    {reverting && <Dialog open returnFocusRef={revertTrigger} onOpenChange={open => { if (!open && !busy) setReverting(false); }}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Revert the scheduled switch?</DialogTitle>
          <DialogDescription>Cancel this scheduled switch and keep Cornerstone approval first.</DialogDescription>
        </DialogHeader>
        <form className="space-y-4" onSubmit={(event: FormEvent) => { event.preventDefault(); void act('revert'); }}>
          <div className="space-y-2">
            <label className="text-sm font-medium" htmlFor={reasonId}>Reason for reverting</label>
            <Textarea id={reasonId} className="text-base!" autoFocus required value={reason} disabled={busy} onChange={event => setReason(event.target.value)} />
          </div>
          {error && <Alert tone="error">{error}</Alert>}
          <DialogFooter>
            <Button type="button" className="min-h-11!" variant="outline" disabled={busy} onClick={() => { setReverting(false); setError(''); }}>Cancel</Button>
            <Button type="submit" className="min-h-11!" disabled={busy || !reason.trim()}>{busy ? 'Saving…' : 'Revert mode'}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>}
  </>;
}
