// Small text helpers for the employee app and its settings preview.

/** "MoSa's" stays "MoSa's"; "Two Brothers" becomes "Two Brothers'". */
export function possessive(name: string): string {
  const trimmed = name.trim();
  if (/['’]s$/i.test(trimmed)) return trimmed;
  if (/s$/i.test(trimmed)) return `${trimmed}'`;
  return `${trimmed}'s`;
}
