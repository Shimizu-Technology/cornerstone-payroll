import { useId, forwardRef, type SelectHTMLAttributes, type ReactNode } from 'react';
import { controlClassName, FIELD_LABEL } from './field-styles';

export interface SelectOption {
  value: string;
  label: string;
}

export interface SelectProps extends SelectHTMLAttributes<HTMLSelectElement> {
  label?: string;
  error?: string;
  options?: SelectOption[];
  placeholder?: string;
  children?: ReactNode;
}

const Select = forwardRef<HTMLSelectElement, SelectProps>(
  ({ className, label, error, options, placeholder, id, children, ...props }, ref) => {
    const generatedId = useId();
    const selectId = id || generatedId;

    return (
      <div className="space-y-1.5">
        {label && (
          <label htmlFor={selectId} className={FIELD_LABEL}>
            {label}
          </label>
        )}
        <select
          ref={ref}
          id={selectId}
          className={controlClassName(className, { invalid: !!error })}
          aria-invalid={error ? 'true' : 'false'}
          aria-describedby={error ? `${selectId}-error` : undefined}
          {...props}
        >
          {placeholder && (
            <option value="" disabled>
              {placeholder}
            </option>
          )}
          {children
            ? children
            : options?.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
        </select>
        {error && <p id={`${selectId}-error`} className="text-sm text-danger-600">{error}</p>}
      </div>
    );
  }
);

Select.displayName = 'Select';

export { Select };
