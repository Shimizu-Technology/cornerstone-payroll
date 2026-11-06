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
