import { useEffect, useRef, useState } from 'react';
import { Check, Loader2 } from 'lucide-react';

interface InlineCheckNumberFieldProps {
  value?: string | null;
  onSave: (value: string | null) => Promise<void>;
  ariaLabel: string;
  disabled?: boolean;
  allowBlank?: boolean;
  placeholder?: string;
  className?: string;
}

export function InlineCheckNumberField({
  value,
  onSave,
  ariaLabel,
  disabled = false,
  allowBlank = false,
  placeholder = 'Not assigned',
  className = '',
}: InlineCheckNumberFieldProps) {
  const normalizedValue = value?.toString() || '';
  const [draft, setDraft] = useState(normalizedValue);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const savingRef = useRef(false);
  const skipNextBlur = useRef(false);
  const savedTimer = useRef<number | null>(null);

  useEffect(() => {
    setDraft(normalizedValue);
  }, [normalizedValue]);

  useEffect(() => () => {
    if (savedTimer.current) window.clearTimeout(savedTimer.current);
  }, []);

  const validate = (nextValue: string) => {
    if (!nextValue && !allowBlank) return 'Enter a check number.';
    if (nextValue && !/^\d+$/.test(nextValue)) return 'Use numbers only.';
    if (nextValue && Number(nextValue) < 1) return 'Must be greater than 0.';
    if (nextValue && Number(nextValue) > 9_999_999) return 'Must be 9,999,999 or less.';
    return null;
  };

  const save = async () => {
    if (savingRef.current || disabled) return;
    const nextValue = draft.trim();
    const validationError = validate(nextValue);
    if (validationError) {
      setError(validationError);
      return;
    }
    if (nextValue === normalizedValue) {
      setError(null);
      return;
    }

    savingRef.current = true;
    setSaving(true);
    setSaved(false);
    setError(null);
    try {
      await onSave(nextValue || null);
      setSaved(true);
      if (savedTimer.current) window.clearTimeout(savedTimer.current);
      savedTimer.current = window.setTimeout(() => setSaved(false), 1_500);
    } catch (err) {
      setDraft(normalizedValue);
      setError(err instanceof Error ? err.message : 'Could not update the check number.');
    } finally {
      savingRef.current = false;
      setSaving(false);
    }
  };

  return (
    <div className={`min-w-0 ${className}`}>
      <div className="relative w-28">
        <input
          type="text"
          inputMode="numeric"
          aria-label={ariaLabel}
          value={draft}
          placeholder={placeholder}
          disabled={disabled || saving}
          onChange={(event) => {
            setDraft(event.target.value);
            setError(null);
            setSaved(false);
          }}
          onFocus={(event) => event.currentTarget.select()}
          onBlur={() => {
            if (skipNextBlur.current) {
              skipNextBlur.current = false;
              return;
            }
            void save();
          }}
          onKeyDown={(event) => {
            if (event.key === 'Enter') {
              event.preventDefault();
              void save();
            }
            if (event.key === 'Escape') {
              skipNextBlur.current = true;
              setDraft(normalizedValue);
              setError(null);
              event.currentTarget.blur();
            }
          }}
          className={`h-9 w-full rounded-lg border bg-white px-2.5 pr-8 font-mono text-sm font-semibold text-slate-900 shadow-sm transition-colors placeholder:font-sans placeholder:text-xs placeholder:font-normal placeholder:text-amber-700 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-100 disabled:cursor-not-allowed disabled:bg-slate-100 ${error ? 'border-red-400' : 'border-slate-300'}`}
        />
        <span className="pointer-events-none absolute inset-y-0 right-2 flex items-center">
          {saving && <Loader2 className="h-4 w-4 animate-spin text-blue-600" aria-hidden="true" />}
          {!saving && saved && <Check className="h-4 w-4 text-emerald-600" aria-hidden="true" />}
        </span>
      </div>
      {error && <p className="mt-1 max-w-40 text-xs leading-tight text-red-600">{error}</p>}
    </div>
  );
}
