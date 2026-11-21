/**
 * A continuing invoice number as it will print: zero-padded to `width`
 * digits when a width is set (5: 7055 -> "07055"), never cut short.
 * Mirrors InvoiceBillingProfile#format_continuing_number on the API.
 */
export function formatContinuingNumber(number: number, width: number | null | undefined): string {
  const text = String(Math.trunc(number));
  return width && width > 0 ? text.padStart(width, '0') : text;
}

export const NUMBER_WIDTH_ERROR = 'Enter a whole number from 1 to 12, or leave it blank for no leading zeros.';

export interface NumberWidthInput {
  /** The width to save: null for blank (no leading zeros) or when invalid. */
  value: number | null;
  /** Set only for a nonblank value that isn't a whole number from 1 to 12. */
  error: string | null;
}

/** Reads the "Digits in invoice number" box. Blank and invalid are different: blank clears padding, invalid must be fixed. */
export function readNumberWidth(text: string): NumberWidthInput {
  const trimmed = text.trim();
  if (!trimmed) return { value: null, error: null };
  const width = Number(trimmed);
  return /^\d+$/.test(trimmed) && width >= 1 && width <= 12 ? { value: width, error: null } : { value: null, error: NUMBER_WIDTH_ERROR };
}

/**
 * What to send when a billing profile is saved. An invalid width blocks the
 * save for a continuing sequence (where the box is shown). For a yearly
 * profile the box is hidden, so an invalid leftover is left out and the
 * saved width is kept.
 */
export function numberWidthForSave(numberingStyle: 'yearly' | 'continuing', text: string):
  { ok: true; value: number | null | undefined } | { ok: false; error: string } {
  const width = readNumberWidth(text);
  if (!width.error) return { ok: true, value: width.value };
  return numberingStyle === 'continuing' ? { ok: false, error: width.error } : { ok: true, value: undefined };
}
