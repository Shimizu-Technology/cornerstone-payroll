import { cn } from '@/lib/utils';

interface SkeletonProps {
  className?: string;
}

export function Skeleton({ className }: SkeletonProps) {
  return (
    <div
      className={cn(
        'relative overflow-hidden rounded-lg bg-neutral-100',
        className
      )}
    >
      <div className="absolute inset-0 -translate-x-full animate-[shimmer_2s_linear_infinite] bg-linear-to-r from-transparent via-white/40 to-transparent" />
    </div>
  );
}

export function CardSkeleton() {
  return (
    <div className="rounded-2xl border border-neutral-200/80 bg-white/90 p-6">
      <Skeleton className="mb-4 h-5 w-1/3" />
      <Skeleton className="mb-3 h-9 w-2/3" />
      <Skeleton className="h-4 w-1/2" />
    </div>
  );
}

export function TableRowSkeleton({ columns = 4 }: { columns?: number }) {
  return (
    <tr>
      {Array.from({ length: columns }).map((_, i) => (
        <td key={i} className="px-4 py-3">
          <Skeleton className="h-4 w-full" />
        </td>
      ))}
    </tr>
  );
}
