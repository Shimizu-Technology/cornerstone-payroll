import { forwardRef, useMemo, useRef, useState, type InputHTMLAttributes, type WheelEvent } from 'react';
import { controlClassName } from './field-styles';

type BaseProps = Omit<InputHTMLAttributes<HTMLInputElement>, 'type' | 'value' | 'onChange'>;

export interface NumericInputProps extends BaseProps {
  value: number | string | null | undefined;
  onValueChange: (value: number | null) => void;
  emptyValue?: number | null;
  notifyEmptyOnChange?: boolean;
  /** On blur, a blank field goes back to the value it had when editing started. */
  restoreOnEmpty?: boolean;
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
      notifyEmptyOnChange = false,
      restoreOnEmpty = false,
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
    const valueAtFocus = useRef<number | null>(null);
    const allowsNegative = useMemo(() => (typeof min === 'number' ? min < 0 : true), [min]);
    const displayValue = focused ? draft : formatDraftValue(value, fixedDecimalsOnBlur);

    // Report only real changes, so leaving a field untouched doesn't look like an edit.
    const commitValue = (next: number | null) => {
      if (next !== normalizeNumericValue(value)) onValueChange(next);
      setDraft(formatDraftValue(next, fixedDecimalsOnBlur));
    };

    const commitDraft = (rawValue: string) => {
      const trimmed = rawValue.trim();
      if (trimmed === '' || trimmed === '-' || trimmed === '.' || trimmed === '-.') {
        commitValue(restoreOnEmpty ? valueAtFocus.current : emptyValue);
        return;
      }

      const parsed = Number(trimmed);
      if (!Number.isFinite(parsed)) {
        setDraft(formatDraftValue(value, fixedDecimalsOnBlur));
        return;
      }

      commitValue(clampValue(parsed, min, max));
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
        className={controlClassName(className)}
        onFocus={(event) => {
          setFocused(true);
          valueAtFocus.current = normalizeNumericValue(value);
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

          if (next === '') {
            // Keep the parent on what blur will commit, so Enter on a blank field saves the same thing.
            if (restoreOnEmpty) onValueChange(valueAtFocus.current);
            else if (notifyEmptyOnChange) onValueChange(emptyValue);
            return;
          }

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
