// Small text helpers for the employee app and its settings preview.

/** "MoSa's" stays "MoSa's"; "Two Brothers" becomes "Two Brothers'". */
export function possessive(name: string): string {
  const trimmed = name.trim();
  if (/['’]s$/i.test(trimmed)) return trimmed;
  if (/s$/i.test(trimmed)) return `${trimmed}'`;
  return `${trimmed}'s`;
}

/** (671) 555-0100 for Guam and US numbers; anything else as entered. */
export function formatPhone(phone: string): string {
  const digits = phone.replace(/\D/g, '');
  const local = digits.length === 11 && digits.startsWith('1') ? digits.slice(1) : digits;
  if (local.length === 10) return `(${local.slice(0, 3)}) ${local.slice(3, 6)}-${local.slice(6)}`;
  if (local.length === 7) return `${local.slice(0, 3)}-${local.slice(3)}`;
  return phone.trim();
}
