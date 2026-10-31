import { forwardRef, type ButtonHTMLAttributes } from 'react';
import { LoaderCircle } from 'lucide-react';
import { cn } from '@/lib/utils';

type ButtonVariant = 'primary' | 'secondary' | 'outline' | 'ghost' | 'danger';
type ButtonAlias = 'default' | 'destructive';
const aliases: Record<ButtonAlias, ButtonVariant> = { default: 'primary', destructive: 'danger' };

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant | ButtonAlias;
  size?: 'sm' | 'md' | 'lg';
  loading?: boolean;
  loadingLabel?: string;
}

const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = 'primary', size = 'md', disabled, loading = false, loadingLabel, children, ...props }, ref) => {
    const baseStyles =
      'inline-flex items-center justify-center whitespace-nowrap rounded-full font-semibold tracking-[-0.01em] transition-[background-color,border-color,color,box-shadow,transform] duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2 disabled:opacity-60 disabled:pointer-events-none active:scale-[0.97] motion-reduce:active:scale-100';

    const variants = {
      primary:
        'bg-primary-700 text-white hover:bg-primary-800',
      secondary:
        'border border-border-subtle bg-surface-panel text-neutral-800 hover:border-border-control hover:bg-surface-subtle',
      outline:
        'border border-border-control bg-surface-panel text-neutral-700 hover:border-primary-300 hover:bg-primary-50/60 hover:text-primary-800',
      ghost:
        'text-neutral-700 hover:bg-neutral-100 hover:text-ink-strong',
      danger: 'bg-danger-600 text-white hover:bg-danger-700',
    };

    const sizes = {
      sm: 'min-h-9 px-3.5 py-1.5 text-xs sm:min-h-0',
      md: 'min-h-11 px-4 py-2.5 text-sm sm:min-h-0',
      lg: 'min-h-12 px-6 py-3 text-base sm:min-h-0',
    };

    return (
      <button
        ref={ref}
        className={cn(baseStyles, variants[variant === 'default' || variant === 'destructive' ? aliases[variant] : variant], sizes[size], className)}
        disabled={disabled || loading}
        aria-busy={loading || undefined}
        {...props}
      >
        {loading && <LoaderCircle aria-hidden="true" className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}
        {loading && loadingLabel ? <span>{loadingLabel}</span> : children}
      </button>
    );
  }
);

Button.displayName = 'Button';

export { Button };
