import { cn } from '@/lib/utils';

interface BadgeProps {
  children: React.ReactNode;
  variant?: 'default' | 'success' | 'warning' | 'danger' | 'info' | 'outline';
  className?: string;
  wrap?: boolean;
}

const variants = {
  default: 'bg-neutral-100 text-neutral-700',
  success: 'bg-success-50 text-success-800',
  warning: 'bg-warning-50 text-warning-800',
  danger: 'bg-danger-50 text-danger-700',
  info: 'bg-primary-50 text-primary-700',
  outline: 'border border-border-control bg-surface-panel text-neutral-700',
};

export function Badge({ children, variant = 'default', className, wrap = false }: BadgeProps) {
  return (
    <span
      className={cn(
        'inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold flex-none',
        wrap ? 'max-w-full whitespace-normal [overflow-wrap:anywhere]' : 'whitespace-nowrap',
        variants[variant],
        className
      )}
    >
      {children}
    </span>
  );
}
