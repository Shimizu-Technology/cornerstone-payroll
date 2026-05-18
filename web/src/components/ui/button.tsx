import { forwardRef, type ButtonHTMLAttributes } from 'react';
import { cn } from '@/lib/utils';

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'outline' | 'ghost' | 'danger' | 'default' | 'destructive';
  size?: 'sm' | 'md' | 'lg';
}

const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = 'primary', size = 'md', disabled, children, ...props }, ref) => {
    const baseStyles =
      'inline-flex items-center justify-center rounded-full font-semibold tracking-[-0.01em] transition-all duration-200 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2 disabled:opacity-50 disabled:pointer-events-none active:scale-[0.985]';

    const variants = {
      primary:
        'bg-primary-700 text-white shadow-[0_12px_28px_-16px_rgba(29,95,210,0.85)] hover:-translate-y-0.5 hover:bg-primary-800 hover:shadow-[0_18px_34px_-18px_rgba(29,95,210,0.9)]',
      secondary:
        'border border-neutral-200 bg-white text-neutral-800 shadow-sm shadow-neutral-200/60 hover:-translate-y-0.5 hover:border-neutral-300 hover:bg-neutral-50',
      outline:
        'border border-neutral-300 bg-white/80 text-neutral-700 hover:-translate-y-0.5 hover:border-primary-300 hover:bg-primary-50/60 hover:text-primary-800',
      ghost:
        'text-neutral-700 hover:bg-neutral-100 hover:text-neutral-950',
      danger: 'bg-danger-600 text-white shadow-[0_12px_28px_-16px_rgba(220,38,38,0.85)] hover:-translate-y-0.5 hover:bg-danger-700',
      default:
        'bg-primary-700 text-white shadow-[0_12px_28px_-16px_rgba(29,95,210,0.85)] hover:-translate-y-0.5 hover:bg-primary-800',
      destructive: 'bg-danger-600 text-white shadow-[0_12px_28px_-16px_rgba(220,38,38,0.85)] hover:-translate-y-0.5 hover:bg-danger-700',
    };

    const sizes = {
      sm: 'px-3.5 py-1.5 text-xs',
      md: 'px-4 py-2.5 text-sm',
      lg: 'px-6 py-3 text-base',
    };

    return (
      <button
        ref={ref}
        className={cn(baseStyles, variants[variant], sizes[size], className)}
        disabled={disabled}
        {...props}
      >
        {children}
      </button>
    );
  }
);

Button.displayName = 'Button';

export { Button };
