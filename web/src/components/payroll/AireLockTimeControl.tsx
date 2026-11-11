import { useEffect, useState, type FormEvent, type ReactElement } from 'react';
import { Clock, Lock, RotateCcw } from 'lucide-react';
import { useSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import { useCompany } from '@/contexts/CompanyContext';
import { earliestLockChange, formatLockTime, fromGuamInput, lockDistance, toGuamInput } from '@/lib/aire-payroll-calendar';
import { payPeriodsApi } from '@/services/api';
import type { AireAppliedCutoffOverride, AireCutoffDelivery, AirePayrollCalendarState } from '@/types';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { HelpTip } from '@/components/ui/help-tip';
import { Textarea } from '@/components/ui/textarea';

type LockAction = 'lock_now' | 'change' | 'reset';

type Props = {
  payPeriodId: number;
  calendar: AirePayrollCalendarState;
  /** Defaults to the active company when the caller has no scoped company. */
  companyId?: number | null;
  /** Defaults to a clock that ticks each minute. */
  now?: Date;
  onChanged: () => Promise<void> | void;
};

const LATE_HOURS = 'Hours clocked or approved after the lock go to the next pay period as late hours. Nothing is lost.';
const TITLES: Record<LockAction, string> = { lock_now: 'Lock hours now?', change: 'Change lock time', reset: 'Reset to the default lock time?' };
const CONFIRM: Record<LockAction, string> = { lock_now: 'Lock now', change: 'Save lock time', reset: 'Reset to default' };

/** The AIRE lock time for one pay period. Cornerstone is the source of truth and republishes every change to AIRE. */
export function AireLockTimeControl({ payPeriodId, calendar, companyId, now: providedNow, onChanged }: Props): ReactElement | null {
  const { activeCompanyId } = useCompany();
  const [scopeCompanyId] = useState(companyId ?? activeCompanyId);
  const canChangeLock = useSelectedCompanyCapability('manage_time_tracking_lock', scopeCompanyId);
  const [tick, setTick] = useState(() => new Date());
  useEffect(() => {
    if (providedNow) return;
    const timer = window.setInterval(() => setTick(new Date()), 60_000);
    return () => window.clearInterval(timer);
  }, [providedNow]);
  const now = providedNow ?? tick;
  const [dialog, setDialog] = useState<LockAction | null>(null);
  const control = calendar.cutoff_control;
  // What AIRE runs on. A newer change counts only once AIRE confirms it.
  const appliedAt = calendar.applied_cutoff_at ?? calendar.cutoff_at;
  if (calendar.lock_mode === 'manual' || !appliedAt || !control) return null;

  const delivery = calendar.cutoff_delivery ?? null;
  const applied = appliedOverride(calendar);
  const due = new Date(appliedAt).getTime() <= now.getTime();

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
            {due ? 'Lock time reached' : <>Locks {formatLockTime(appliedAt)} <span className="font-normal text-neutral-600">({lockDistance(appliedAt, now)})</span></>}
          </p>
          {applied && (
            <p className="mt-1 break-words text-sm text-neutral-700">
              Changed by {applied.set_by_name || 'an admin'}{applied.requested_via === 'aire_services' ? ' in AIRE' : ''}: {applied.reason}
            </p>
          )}
          {applied?.policy_cutoff_at && <p className="mt-1 text-xs text-neutral-500">Default was {formatLockTime(applied.policy_cutoff_at)}.</p>}
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
      {/* Once the lock AIRE has passes, a change that never applied is history. */}
      {delivery && !due && (
        <DeliveryNote delivery={delivery} canReplace={canChangeLock && control.available} canLockNow={control.lock_now_available} />
      )}
      {canChangeLock && !control.available && control.unavailable_reason && !due && !delivery && (
        <p className="mt-2 text-xs text-neutral-600">{control.unavailable_reason}.</p>
      )}
      {dialog && (
        <LockTimeDialog
          action={dialog}
          payPeriodId={payPeriodId}
          calendar={calendar}
          appliedAt={appliedAt}
          now={now}
          currentTime={() => providedNow ?? new Date()}
          onClose={() => setDialog(null)}
          onDone={async () => { setDialog(null); await onChanged(); }}
        />
      )}
    </div>
  );
}

/** Older API responses have no applied_cutoff_override; their current override is the applied one. */
function appliedOverride(calendar: AirePayrollCalendarState): AireAppliedCutoffOverride | null {
  if (calendar.applied_cutoff_override !== undefined) return calendar.applied_cutoff_override;
  const override = calendar.cutoff_source === 'override' ? calendar.cutoff_override : null;
  if (!override || override.action === 'reset') return null;
  return { action: override.action, reason: override.reason, set_by_name: override.set_by_name, requested_via: override.requested_via, policy_cutoff_at: calendar.policy_cutoff_at ?? null };
}

function deliveryTarget(delivery: AireCutoffDelivery): string {
  if (delivery.action === 'lock_now') return 'Lock now';
  if (delivery.cutoff_source === 'policy') return `the reset to ${formatLockTime(delivery.cutoff_at)}`;
  return `the change to ${formatLockTime(delivery.cutoff_at)}`;
}

function DeliveryNote({ delivery, canReplace, canLockNow }: { delivery: AireCutoffDelivery; canReplace: boolean; canLockNow: boolean }): ReactElement {
  if (delivery.state === 'pending') {
    return (
      <p role="status" className="mt-3 rounded-lg border border-primary-200 bg-white px-3 py-2 text-sm text-neutral-800">
        <span className="font-semibold">Waiting for AIRE to confirm {deliveryTarget(delivery)}.</span> Until it does, AIRE keeps the lock time above.
      </p>
    );
  }
  const target = deliveryTarget(delivery);
  const headline = delivery.state === 'expired'
    ? `${target.charAt(0).toUpperCase()}${target.slice(1)} didn't reach AIRE in time, so AIRE didn't apply it.`
    : `AIRE rejected ${target}${delivery.error ? `: ${delivery.error}` : '.'}`;
  const replaced = delivery.state === 'rejected' ? 'the rejected change' : 'it';
  const replace = canReplace ? ` ${canLockNow ? 'Lock now or choose' : 'Choose'} a new time to replace ${replaced}.` : '';
  return (
    <div role="status" className="mt-3 rounded-lg border border-warning-200 bg-warning-50 px-3 py-2 text-sm text-warning-950">
      <p className="font-semibold">{headline}</p>
      <p className="mt-1">The lock time above is still in effect.{replace}</p>
    </div>
  );
}

function LockTimeDialog({ action, payPeriodId, calendar, appliedAt, now, currentTime, onClose, onDone }: {
  action: LockAction;
  payPeriodId: number;
  calendar: AirePayrollCalendarState;
  appliedAt: string;
  now: Date;
  /** The clock at submit; `now` only ticks each minute. */
  currentTime: () => Date;
  onClose: () => void;
  onDone: () => Promise<void>;
}): ReactElement {
  const control = calendar.cutoff_control!;
  // The server's earliest time ages while the page is open; never offer less than 15 minutes ahead.
  const serverMin = toGuamInput(control.earliest_at);
  const leadMin = toGuamInput(earliestLockChange(now).toISOString());
  const min = leadMin > serverMin ? leadMin : serverMin;
  const max = toGuamInput(control.latest_at);
  const current = toGuamInput(appliedAt);
  const [cutoffInput, setCutoffInput] = useState(() => (current < min ? min : current > max ? max : current));
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [requestId] = useState(() => crypto.randomUUID());
  const chosen = action === 'change' ? fromGuamInput(cutoffInput) : null;
  const defaultCutoff = calendar.policy_cutoff_at || appliedAt;
  const minLabel = formatLockTime(fromGuamInput(min)!);
  // Saving the time AIRE already has would be refused, unless it replaces a change AIRE didn't apply.
  const replacing = calendar.cutoff_delivery != null && calendar.cutoff_delivery.state !== 'pending';
  const unchanged = action === 'change' && cutoffInput === current && !replacing;

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (!reason.trim()) { setError('Enter a reason for the change.'); return; }
    // The minimum moves on while the dialog is open; Cornerstone would refuse a time that slipped under it.
    const freshMin = toGuamInput(earliestLockChange(currentTime()).toISOString());
    if (action === 'change' && chosen && cutoffInput < freshMin && freshMin <= max) {
      setCutoffInput(freshMin);
      setError(`The lock time must be at least 15 minutes from now, so the earliest is now ${formatLockTime(fromGuamInput(freshMin)!)}. Check the new time and save again.`);
      return;
    }
    if (action === 'change' && (!chosen || cutoffInput < min || cutoffInput > max)) {
      setError(`Choose a time between ${minLabel} and ${formatLockTime(control.latest_at)}.`);
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
              {action === 'lock_now' && `AIRE locks this period's hours right away instead of ${formatLockTime(appliedAt)}.`}
              {action === 'reset' && `The lock goes back to ${formatLockTime(defaultCutoff)}.`}
              {action === 'change' && `Now: ${formatLockTime(appliedAt)}. Default: ${formatLockTime(defaultCutoff)}.`}
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
                {unchanged ? 'Choose a new time to save. ' : ''}Between {minLabel} (at least 15 minutes from now) and {formatLockTime(control.latest_at)} (two days before payday).
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
            <Button type="submit" loading={busy} loadingLabel="Saving…" disabled={unchanged}>{CONFIRM[action]}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
