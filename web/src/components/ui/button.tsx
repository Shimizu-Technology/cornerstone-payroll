import { forwardRef, type ButtonHTMLAttributes } from 'react';
import { cn } from '@/lib/utils';

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'outline' | 'ghost' | 'danger' | 'default' | 'destructive';
  size?: 'sm' | 'md' | 'lg';
}

const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = 'primary', size = 'md', disabled, children, ...props }, ref) => {
    const baseStyles =
      'inline-flex items-center justify-center rounded-xl font-medium transition-all duration-200 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2 disabled:opacity-50 disabled:pointer-events-none active:scale-[0.99]';

    const variants = {
      primary:
        'bg-primary-600 text-white shadow-sm hover:bg-primary-700 hover:shadow-lg hover:shadow-primary-600/20',
      secondary:
        'bg-white text-neutral-800 border border-neutral-200 hover:bg-neutral-50 hover:border-neutral-300',
      outline:
        'border border-neutral-300 bg-white text-neutral-700 hover:bg-neutral-50 hover:border-primary-300 hover:text-primary-700',
      ghost:
        'text-neutral-700 hover:bg-neutral-100 hover:text-neutral-900',
      danger: 'bg-danger-600 text-white shadow-sm hover:bg-danger-500 hover:shadow-lg hover:shadow-danger-600/20',
      default:
        'bg-primary-600 text-white shadow-sm hover:bg-primary-700 hover:shadow-lg hover:shadow-primary-600/20',
      destructive: 'bg-danger-600 text-white shadow-sm hover:bg-danger-500 hover:shadow-lg hover:shadow-danger-600/20',
    };

    const sizes = {
      sm: 'px-3 py-1.5 text-xs',
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
