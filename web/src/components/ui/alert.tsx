import type { HTMLAttributes } from 'react';
import { cn } from '@/lib/utils';

const tones = {
  warning: 'border-warning-200 bg-warning-50 text-warning-950',
  error: 'border-danger-200 bg-danger-50 text-danger-950',
  success: 'border-success-200 bg-success-50 text-success-950',
  info: 'border-primary-200 bg-primary-50 text-ink-strong',
};

/** Inline record feedback. Keep the complete message and its recovery action together. */
export function Alert({ tone = 'warning', className, role, ...props }: HTMLAttributes<HTMLDivElement> & { tone?: keyof typeof tones }) {
  return <div role={role ?? (tone === 'error' ? 'alert' : 'status')} className={cn('rounded-xl border p-4 text-sm leading-6', tones[tone], className)} {...props} />;
}
