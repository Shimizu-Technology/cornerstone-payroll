import { useId, forwardRef, type InputHTMLAttributes, type WheelEvent } from 'react';
import { controlClassName, FIELD_LABEL } from './field-styles';

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
          <label htmlFor={inputId} className={FIELD_LABEL}>
            {label}
          </label>
        )}
        <input
          ref={ref}
          id={inputId}
          type={type}
          className={controlClassName(className, { invalid: !!error })}
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
          <p id={`${inputId}-helper`} className="text-sm text-neutral-500">
            {helperText}
          </p>
        )}
      </div>
    );
  }
);

Input.displayName = 'Input';

export { Input };
