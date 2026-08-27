export function parsePayRunYear(value: string | null): number | undefined {
  if (!value || !/^\d{4}$/.test(value)) return undefined;

  const year = Number(value);
  return year >= 1900 && year <= 9999 ? year : undefined;
}
