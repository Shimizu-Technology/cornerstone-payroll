import { forwardRef, useMemo, useState, type InputHTMLAttributes, type WheelEvent } from 'react';
import { cn } from '@/lib/utils';

type BaseProps = Omit<InputHTMLAttributes<HTMLInputElement>, 'type' | 'value' | 'onChange'>;

export interface NumericInputProps extends BaseProps {
  value: number | string | null | undefined;
  onValueChange: (value: number | null) => void;
  emptyValue?: number | null;
  min?: number;
  max?: number;
  fixedDecimalsOnBlur?: number;
}

const PARTIAL_NUMBER_PATTERN = /^-?\d*(?:\.\d*)?$/;

function normalizeNumericValue(value: number | string | null | undefined) {
  if (value == null || value === '') return null;

  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function formatDraftValue(value: number | string | null | undefined, fixedDecimalsOnBlur?: number) {
  const normalized = normalizeNumericValue(value);
  if (normalized == null) return '';
  if (typeof fixedDecimalsOnBlur === 'number') return normalized.toFixed(fixedDecimalsOnBlur);
  return `${normalized}`;
}

function clampValue(value: number, min?: number, max?: number) {
  let next = value;
  if (typeof min === 'number') next = Math.max(min, next);
  if (typeof max === 'number') next = Math.min(max, next);
  return next;
}

export const NumericInput = forwardRef<HTMLInputElement, NumericInputProps>(
  (
    {
      className,
      value,
      onValueChange,
      emptyValue = 0,
      min,
      max,
      fixedDecimalsOnBlur,
      onFocus,
      onBlur,
      onWheel,
      inputMode = 'decimal',
      ...props
    },
    ref
  ) => {
    const [draft, setDraft] = useState(() => formatDraftValue(value, fixedDecimalsOnBlur));
    const [focused, setFocused] = useState(false);
    const allowsNegative = useMemo(() => (typeof min === 'number' ? min < 0 : true), [min]);
    const displayValue = focused ? draft : formatDraftValue(value, fixedDecimalsOnBlur);

    const commitDraft = (rawValue: string) => {
      const trimmed = rawValue.trim();
      if (trimmed === '' || trimmed === '-' || trimmed === '.' || trimmed === '-.') {
        onValueChange(emptyValue);
        setDraft(formatDraftValue(emptyValue, fixedDecimalsOnBlur));
        return;
      }

      const parsed = Number(trimmed);
      if (!Number.isFinite(parsed)) {
        setDraft(formatDraftValue(value, fixedDecimalsOnBlur));
        return;
      }

      const clamped = clampValue(parsed, min, max);
      onValueChange(clamped);
      setDraft(formatDraftValue(clamped, fixedDecimalsOnBlur));
    };

    const handleWheel = (event: WheelEvent<HTMLInputElement>) => {
      if (document.activeElement === event.currentTarget) {
        event.currentTarget.blur();
      }
      onWheel?.(event);
    };

    return (
      <input
        {...props}
        ref={ref}
        type="text"
        inputMode={inputMode}
        value={displayValue}
        className={cn(
          'block w-full rounded-xl border bg-white px-3.5 py-2.5 text-sm text-neutral-900 shadow-sm transition-all duration-200 placeholder:text-neutral-400',
          'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200 focus-visible:border-primary-400',
          'border-neutral-300 disabled:cursor-not-allowed disabled:bg-neutral-50 disabled:text-neutral-500',
          className
        )}
        onFocus={(event) => {
          setFocused(true);
          setDraft(formatDraftValue(value, fixedDecimalsOnBlur));
          onFocus?.(event);
        }}
        onBlur={(event) => {
          setFocused(false);
          commitDraft(event.target.value);
          onBlur?.(event);
        }}
        onWheel={handleWheel}
        onChange={(event) => {
          const next = event.target.value;
          const pattern = allowsNegative ? PARTIAL_NUMBER_PATTERN : /^\d*(?:\.\d*)?$/;
          if (!pattern.test(next)) return;

          setDraft(next);

          const parsed = Number(next);
          if (next !== '' && next !== '-' && next !== '.' && next !== '-.' && Number.isFinite(parsed)) {
            onValueChange(clampValue(parsed, min, max));
          }
        }}
      />
    );
  }
);

NumericInput.displayName = 'NumericInput';
