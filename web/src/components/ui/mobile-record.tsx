import type { ReactNode } from 'react';
import { cn } from '@/lib/utils';

interface MobileRecordCardProps {
  children: ReactNode;
  className?: string;
  tone?: 'default' | 'muted' | 'primary';
  onClick?: () => void;
}

export function MobileRecordCard({ children, className, tone = 'default', onClick }: MobileRecordCardProps) {
  const classes = cn(
    'rounded-2xl border bg-white p-4 shadow-[0_14px_32px_-26px_rgba(15,23,42,0.55)] ring-1 ring-neutral-950/[0.03]',
    tone === 'default' && 'border-neutral-200/80',
    tone === 'muted' && 'border-neutral-200/80 bg-neutral-50/80',
    tone === 'primary' && 'border-primary-200 bg-primary-50/60',
    onClick && 'text-left transition active:scale-[0.99] hover:border-primary-200 hover:bg-primary-50/40',
    className
  );

  if (onClick) {
    return (
      <button type="button" onClick={onClick} className={cn('block w-full', classes)}>
        {children}
      </button>
    );
  }

  return <div className={classes}>{children}</div>;
}

export function MobileField({ label, value, className }: { label: string; value: ReactNode; className?: string }) {
  return (
    <div className={className}>
      <p className="text-[11px] font-semibold uppercase tracking-[0.12em] text-neutral-400">{label}</p>
      <div className="mt-1 text-sm font-medium text-neutral-900">{value}</div>
    </div>
  );
}

export function MobileCardActions({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cn('mt-4 flex flex-col gap-2 sm:flex-row sm:flex-wrap', className)}>
      {children}
    </div>
  );
}
