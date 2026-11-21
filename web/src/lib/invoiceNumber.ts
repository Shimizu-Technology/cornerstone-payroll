/**
 * A continuing invoice number as it will print: zero-padded to `width`
 * digits when a width is set (5: 7055 -> "07055"), never cut short.
 * Mirrors InvoiceBillingProfile#format_continuing_number on the API.
 */
export function formatContinuingNumber(number: number, width: number | null | undefined): string {
  const text = String(Math.trunc(number));
  return width && width > 0 ? text.padStart(width, '0') : text;
}

/** Parses the "Digits in invoice number" box: blank means no padding. */
export function parseNumberWidth(value: string): number | null {
  const trimmed = value.trim();
  if (!trimmed) return null;
  const width = Number(trimmed);
  return Number.isInteger(width) && width >= 1 && width <= 12 ? width : null;
}
