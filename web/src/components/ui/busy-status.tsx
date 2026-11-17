import { cn } from '@/lib/utils';

/** Keep a live region and its space in place before an action starts. */
export function BusyStatus({ busy, children, className, reserveMessage = children }: { busy: boolean; children: string; className?: string; reserveMessage?: string }) {
  return <p role="status" aria-live="polite" aria-atomic="true" className={cn('grid text-sm text-neutral-600', className)}>
    <span aria-hidden="true" className="invisible col-start-1 row-start-1">{reserveMessage}</span>
    <span className="col-start-1 row-start-1">{busy ? children : ''}</span>
  </p>;
}
