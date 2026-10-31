import { useId, forwardRef, type InputHTMLAttributes, type WheelEvent } from 'react';
import { cn } from '@/lib/utils';

export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label?: string;
  error?: string;
  helperText?: string;
}

const Input = forwardRef<HTMLInputElement, InputProps>(
  ({ className, label, error, helperText, id, type = 'text', onWheel, ...props }, ref) => {
    const generatedId = useId();
    const inputId = id || generatedId;
    const handleWheel = (event: WheelEvent<HTMLInputElement>) => {
      if (type === 'number' && document.activeElement === event.currentTarget) {
        event.currentTarget.blur();
      }

      onWheel?.(event);
    };

    return (
      <div className="space-y-1.5">
        {label && (
          <label htmlFor={inputId} className="block text-xs font-medium text-ink-muted">
            {label}
          </label>
        )}
        <input
          ref={ref}
          id={inputId}
          type={type}
          className={cn(
            'block w-full rounded-xl border bg-surface-panel px-3.5 py-2.5 text-base sm:text-sm text-ink-default transition-[border-color,background-color,color,box-shadow] duration-150 ease-out placeholder:text-ink-muted',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200 focus-visible:border-primary-400',
            error
              ? 'border-danger-300 focus-visible:border-danger-500 focus-visible:ring-danger-200'
              : 'border-border-control',
            'disabled:cursor-not-allowed disabled:bg-surface-subtle disabled:text-neutral-500',
            className
          )}
          aria-invalid={error ? 'true' : 'false'}
          aria-describedby={error ? `${inputId}-error` : helperText ? `${inputId}-helper` : undefined}
          {...props}
          onWheel={handleWheel}
        />
        {error && (
          <p id={`${inputId}-error`} className="text-sm text-danger-600">
            {error}
          </p>
        )}
        {helperText && !error && (
          <p id={`${inputId}-helper`} className="text-sm text-ink-muted">
            {helperText}
          </p>
        )}
      </div>
    );
  }
);

Input.displayName = 'Input';

export { Input };
