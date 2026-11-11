import { useState, type FormEvent, type ReactElement } from 'react';
import { Clock, Lock, RotateCcw } from 'lucide-react';
import { useSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import { formatLockTime, fromGuamInput, lockDistance, toGuamInput } from '@/lib/aire-payroll-calendar';
import { payPeriodsApi } from '@/services/api';
import type { AirePayrollCalendarState } from '@/types';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { HelpTip } from '@/components/ui/help-tip';
import { Textarea } from '@/components/ui/textarea';

type LockAction = 'lock_now' | 'change' | 'reset';

type Props = {
  payPeriodId: number;
  calendar: AirePayrollCalendarState;
  companyId: number | null;
  now: Date;
  onChanged: () => Promise<void> | void;
};

const LATE_HOURS = 'Hours clocked or approved after the lock go to the next pay period as late hours. Nothing is lost.';
const TITLES: Record<LockAction, string> = { lock_now: 'Lock hours now?', change: 'Change lock time', reset: 'Reset to the default lock time?' };
const CONFIRM: Record<LockAction, string> = { lock_now: 'Lock now', change: 'Save lock time', reset: 'Reset to default' };

/** The AIRE lock time for one pay period. Cornerstone is the source of truth and republishes every change to AIRE. */
export function AireLockTimeControl({ payPeriodId, calendar, companyId, now, onChanged }: Props): ReactElement | null {
  const canChangeLock = useSelectedCompanyCapability('manage_time_tracking_lock', companyId);
  const [dialog, setDialog] = useState<LockAction | null>(null);
  const control = calendar.cutoff_control;
  if (calendar.lock_mode === 'manual' || !calendar.cutoff_at || !control) return null;

  const override = calendar.cutoff_source === 'override' ? calendar.cutoff_override : null;
  const due = new Date(calendar.cutoff_at).getTime() <= now.getTime();

  return (
    <div className="border-b border-primary-100 bg-primary-50/40 px-4 py-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex items-center gap-1">
            <p className="text-xs font-semibold uppercase tracking-[0.12em] text-primary-800">AIRE lock time</p>
            <HelpTip label="the AIRE lock time">
              At the lock time AIRE freezes this pay period&apos;s hours and sends them here. {LATE_HOURS} Default: 5:00 PM Guam time, 7 days after the last regular payday. Organization admins here, and AIRE owners and admins, can change it with a reason; every change is recorded in both apps.
            </HelpTip>
          </div>
          <p className="mt-1 text-base font-semibold text-neutral-950">
            {due ? 'Lock time reached' : <>Locks {formatLockTime(calendar.cutoff_at)} <span className="font-normal text-neutral-600">({lockDistance(calendar.cutoff_at, now)})</span></>}
          </p>
          {override && (
            <p className="mt-1 break-words text-sm text-neutral-700">
              Changed by {override.set_by_name || 'an admin'}{override.requested_via === 'aire_services' ? ' in AIRE' : ''}: {override.reason}
            </p>
          )}
          {override && calendar.policy_cutoff_at && <p className="mt-1 text-xs text-neutral-500">Default was {formatLockTime(calendar.policy_cutoff_at)}.</p>}
        </div>
        {canChangeLock && control.available && (
          <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:justify-end">
            {control.lock_now_available && (
              <Button type="button" size="sm" className="max-sm:min-h-[44px]" onClick={() => setDialog('lock_now')}>
                <Lock className="mr-2 h-4 w-4" aria-hidden="true" />Lock now
              </Button>
            )}
            <Button type="button" size="sm" variant="outline" className="max-sm:min-h-[44px]" onClick={() => setDialog('change')}>
              <Clock className="mr-2 h-4 w-4" aria-hidden="true" />Change lock time
            </Button>
            {control.reset_available && (
              <Button type="button" size="sm" variant="ghost" className="max-sm:min-h-[44px]" onClick={() => setDialog('reset')}>
                <RotateCcw className="mr-2 h-4 w-4" aria-hidden="true" />Reset to default
              </Button>
            )}
          </div>
        )}
      </div>
      {canChangeLock && !control.available && control.unavailable_reason && !due && (
        <p className="mt-2 text-xs text-neutral-600">{control.unavailable_reason}.</p>
      )}
      {dialog && (
        <LockTimeDialog
          action={dialog}
          payPeriodId={payPeriodId}
          calendar={calendar}
          onClose={() => setDialog(null)}
          onDone={async () => { setDialog(null); await onChanged(); }}
        />
      )}
    </div>
  );
}

function LockTimeDialog({ action, payPeriodId, calendar, onClose, onDone }: {
  action: LockAction;
  payPeriodId: number;
  calendar: AirePayrollCalendarState;
  onClose: () => void;
  onDone: () => Promise<void>;
}): ReactElement {
  const control = calendar.cutoff_control!;
  const [cutoffInput, setCutoffInput] = useState(() => toGuamInput(calendar.cutoff_at!));
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [requestId] = useState(() => crypto.randomUUID());
  const min = toGuamInput(control.earliest_at);
  const max = toGuamInput(control.latest_at);
  const chosen = action === 'change' ? fromGuamInput(cutoffInput) : null;
  const defaultCutoff = calendar.policy_cutoff_at || calendar.cutoff_at!;

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (!reason.trim()) { setError('Enter a reason for the change.'); return; }
    if (action === 'change' && (!chosen || cutoffInput < min || cutoffInput > max)) {
      setError(`Choose a time between ${formatLockTime(control.earliest_at)} and ${formatLockTime(control.latest_at)}.`);
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await payPeriodsApi.changeAireCutoff(payPeriodId, {
        lock_action: action,
        reason: reason.trim(),
        request_id: requestId,
        ...(chosen ? { cutoff_at: chosen } : {}),
      });
      await onDone();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'The lock time could not be changed. Nothing changed.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog open onOpenChange={(next) => { if (!next && !busy) onClose(); }} dismissOnEscape={!busy}>
      <DialogContent className="dialog-center-mobile max-h-[calc(100dvh-2rem)] overflow-y-auto">
        <form onSubmit={(event) => void submit(event)} noValidate>
          <DialogHeader>
            <DialogTitle>{TITLES[action]}</DialogTitle>
            <DialogDescription>
              {action === 'lock_now' && `AIRE locks this period's hours right away instead of ${formatLockTime(calendar.cutoff_at!)}.`}
              {action === 'reset' && `The lock goes back to ${formatLockTime(defaultCutoff)}.`}
              {action === 'change' && `Now: ${formatLockTime(calendar.cutoff_at!)}. Default: ${formatLockTime(defaultCutoff)}.`}
            </DialogDescription>
          </DialogHeader>
          <p className="mt-3 rounded-lg bg-warning-50 px-3 py-2 text-sm text-warning-950">{LATE_HOURS}</p>
          {action === 'change' && (
            <label className="mt-4 block text-sm font-medium text-neutral-800">
              New lock time (Guam)
              <input type="datetime-local" value={cutoffInput} min={min} max={max} step={60} required
                onChange={(event) => setCutoffInput(event.target.value)} aria-describedby="aire-lock-range"
                className="mt-1 block min-h-11 w-full rounded-md border border-neutral-300 bg-white px-3 py-2 text-base text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200" />
              <span id="aire-lock-range" className="mt-1 block text-xs font-normal text-neutral-500">
                Between {formatLockTime(control.earliest_at)} and {formatLockTime(control.latest_at)} (two days before payday).
              </span>
            </label>
          )}
          <label className="mt-4 block text-sm font-medium text-neutral-800">
            Reason (required)
            <Textarea className="mt-1" value={reason} onChange={(event) => setReason(event.target.value)} maxLength={500} rows={3} required
              placeholder="For example: payday moved for the holiday" />
          </label>
          {error && <p role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-800">{error}</p>}
          <DialogFooter className="mt-5">
            <Button type="button" variant="outline" onClick={onClose} disabled={busy}>Cancel</Button>
            <Button type="submit" loading={busy} loadingLabel="Saving…">{CONFIRM[action]}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
