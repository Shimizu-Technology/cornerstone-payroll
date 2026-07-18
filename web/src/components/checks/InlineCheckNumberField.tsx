interface InlineCheckNumberFieldProps {
  value: string;
  onChange: (value: string) => void;
  ariaLabel: string;
  disabled?: boolean;
  allowBlank?: boolean;
  placeholder?: string;
  className?: string;
  dirty?: boolean;
  error?: string | null;
  onReset?: () => void;
}

export function InlineCheckNumberField({
  value,
  onChange,
  ariaLabel,
  disabled = false,
  allowBlank = false,
  placeholder = 'Not assigned',
  className = '',
  dirty = false,
  error = null,
  onReset,
}: InlineCheckNumberFieldProps) {
  return (
    <div className={`min-w-0 ${className}`}>
      <div className="relative w-28">
        <input
          type="text"
          inputMode="numeric"
          aria-label={ariaLabel}
          aria-invalid={Boolean(error)}
          value={value}
          placeholder={placeholder}
          disabled={disabled}
          onChange={(event) => onChange(event.target.value)}
          onFocus={(event) => event.currentTarget.select()}
          onKeyDown={(event) => {
            if (event.key === 'Enter') {
              event.preventDefault();
              event.currentTarget.blur();
            }
            if (event.key === 'Escape' && onReset) {
              event.preventDefault();
              onReset();
              event.currentTarget.blur();
            }
          }}
          className={`h-9 w-full rounded-lg border bg-white px-2.5 pr-7 font-mono text-sm font-semibold text-slate-900 shadow-sm transition-colors placeholder:font-sans placeholder:text-xs placeholder:font-normal placeholder:text-amber-700 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-100 disabled:cursor-not-allowed disabled:bg-slate-100 ${
            error ? 'border-red-400 bg-red-50/40' : dirty ? 'border-amber-400 bg-amber-50/70' : 'border-slate-300'
          }`}
        />
        {dirty && !error && (
          <span className="pointer-events-none absolute right-2 top-1/2 h-2 w-2 -translate-y-1/2 rounded-full bg-amber-500" aria-hidden="true" />
        )}
      </div>
      {error && <p className="mt-1 max-w-40 text-xs leading-tight text-red-600">{error}</p>}
      {!error && dirty && <p className="mt-1 text-[11px] font-medium text-amber-700">Not saved</p>}
      <span className="sr-only">{allowBlank ? 'This check number may be left blank.' : 'A check number is required.'}</span>
    </div>
  );
}
