import { parsePhoneNumberFromString } from 'libphonenumber-js/min';

/** Format US and Guam phone numbers for display, including local 7-digit Guam numbers. */
export function formatPhone(value?: string | null): string {
  if (value == null) return '';

  const phone = value.trim();
  if (!/^\+?[\d().\s-]+$/.test(phone)) return value;
  const digits = phone.replace(/\D/g, '');

  let national = digits;
  if (phone.startsWith('+') || digits.length === 11) {
    if (digits.length !== 11 || !digits.startsWith('1')) return value;
    national = digits.slice(1);
  } else if (digits.length === 7) {
    national = `671${digits}`;
  }

  const match = /^([2-9]\d{2})([2-9]\d{2})(\d{4})$/.exec(national);
  if (!match) return value;

  // Several countries share +1, so the calling code alone cannot identify a US or Guam number.
  const country = parsePhoneNumberFromString(`+1${national}`)?.country;
  if (country && country !== 'US' && country !== 'GU') return value;

  return `(${match[1]}) ${match[2]}-${match[3]}`;
}
