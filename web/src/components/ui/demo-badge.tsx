import { cn } from '@/lib/utils';

interface DemoBadgeProps {
  className?: string;
}

/**
 * Neutral grey "Demo" marker (Track B / D-3).
 * Render ONLY when a company has `demo === true`; real clients never show it.
 */
export function DemoBadge({ className }: DemoBadgeProps) {
  return (
    <span
      className={cn(
        'inline-flex shrink-0 items-center rounded-full border border-neutral-300 bg-neutral-100 px-2 py-0.5 text-[11px] font-semibold leading-4 text-neutral-700',
        className
      )}
    >
      Demo
    </span>
  );
}
