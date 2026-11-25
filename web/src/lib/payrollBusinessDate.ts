export function guamBusinessDate(date = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Pacific/Guam', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(date);
  const value = (type: Intl.DateTimeFormatPartTypes) => parts.find((part) => part.type === type)?.value ?? '';
  return `${value('year')}-${value('month')}-${value('day')}`;
}

// The Guam business date's tax year, quarter and month, as form strings.
export function guamTaxPeriod(date = new Date()) {
  const [year, month] = guamBusinessDate(date).split('-').map(Number);
  return { tax_year: String(year), tax_quarter: String(Math.ceil(month / 3)), tax_month: String(month) };
}
