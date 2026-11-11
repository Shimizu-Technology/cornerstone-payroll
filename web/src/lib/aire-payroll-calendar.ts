import type { AirePayrollCalendarState } from '@/types';

export function cutoffDistance(cutoffAt?: string | null, now = new Date()): string | null {
  if (!cutoffAt) return null;
  const milliseconds = new Date(cutoffAt).getTime() - now.getTime();
  if (!Number.isFinite(milliseconds)) return null;
  if (milliseconds <= 0) return 'Cutoff reached';

  const totalMinutes = Math.ceil(milliseconds / 60_000);
  if (totalMinutes < 60) {
    return `${totalMinutes} minute${totalMinutes === 1 ? '' : 's'} until cutoff`;
  }

  const totalHours = Math.ceil(totalMinutes / 60);
  const days = Math.floor(totalHours / 24);
  const hours = totalHours % 24;
  if (days === 0) return `${hours} hour${hours === 1 ? '' : 's'} until cutoff`;
  return `${days} day${days === 1 ? '' : 's'}${hours ? `, ${hours} hr` : ''} until cutoff`;
}

export function lockedBatchCopy(batch: AirePayrollCalendarState['finalized_batch']) {
  if (!batch) {
    return {
      headline: 'No finalized batch received',
      detail: 'The time tracking system has not sent locked hours for this period.',
    };
  }

  const issueCount = Object.values(batch.issues || {}).reduce((sum, value) => sum + Number(value || 0), 0);
  if (batch.verification_status === 'verified') {
    return {
      headline: `${Number(batch.summary?.total_hours || 0).toFixed(2)} verified batch hours`,
      detail: `${issueCount} held or review item${issueCount === 1 ? '' : 's'}`,
    };
  }
  if (batch.verification_status === 'failed') {
    return { headline: 'Verification retrying', detail: 'Hours are not ready to import or process.' };
  }
  if (batch.verification_status === 'rejected') {
    return { headline: 'Batch rejected', detail: 'Review the connection error before using these hours.' };
  }
  return { headline: 'Verification in progress', detail: 'Cornerstone is checking the finalized batch.' };
}

export function lockScheduleCopy(period: { lock_mode?: 'manual' | 'scheduled'; cutoff_at?: string | null }, locked = false): string {
  if (period.lock_mode === 'manual') return locked ? 'Locked manually' : 'Lock manually when you are ready';
  if (!period.cutoff_at) return 'Automatic lock time unavailable';
  const date = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Pacific/Guam', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true,
  }).format(new Date(period.cutoff_at)).replace(/\s*AM$/, ' a.m.').replace(/\s*PM$/, ' p.m.');
  return `Locks automatically ${date} ChST`;
}

// AIRE locks on Guam time, which has no daylight saving: UTC+10 all year.
const GUAM = 'Pacific/Guam';
const DAY = 86_400_000;
const guamPart = (value: Date, options: Intl.DateTimeFormatOptions): string =>
  new Intl.DateTimeFormat('en-US', { timeZone: GUAM, ...options }).format(value);
// en-CA formats a date as YYYY-MM-DD.
const guamDay = (value: Date): number =>
  Date.parse(`${new Intl.DateTimeFormat('en-CA', { timeZone: GUAM, year: 'numeric', month: '2-digit', day: '2-digit' }).format(value)}T00:00:00Z`);

/** "Sat, Nov 22 at 5:00 PM" in Guam time. */
export function formatLockTime(iso: string): string {
  const value = new Date(iso);
  return `${guamPart(value, { weekday: 'short', month: 'short', day: 'numeric' })} at ${guamPart(value, { hour: 'numeric', minute: '2-digit' })}`;
}

/** "in 3 days", "tomorrow", "in 5 hours", "in 12 minutes", or "now". */
export function lockDistance(iso: string, now = new Date()): string {
  const target = new Date(iso);
  const ms = target.getTime() - now.getTime();
  if (ms <= 60_000) return 'now';
  const minutes = Math.round(ms / 60_000);
  if (minutes < 60) return `in ${minutes} minute${minutes === 1 ? '' : 's'}`;
  const days = Math.round((guamDay(target) - guamDay(now)) / DAY);
  if (days === 0) {
    const hours = Math.round(minutes / 60);
    return `in ${hours} hour${hours === 1 ? '' : 's'}`;
  }
  return days === 1 ? 'tomorrow' : `in ${days} days`;
}

/** ISO instant to a datetime-local value in Guam time ("2026-11-22T17:00"). */
export function toGuamInput(iso: string): string {
  return new Date(new Date(iso).getTime() + 10 * 3_600_000).toISOString().slice(0, 16);
}

/** A datetime-local value entered as Guam time to an ISO instant with offset. */
export function fromGuamInput(value: string): string | null {
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value) ? `${value}:00+10:00` : null;
}
