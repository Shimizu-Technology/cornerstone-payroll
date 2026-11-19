/**
 * A report period passed in the URL (`/reports?report=941-gu&year=2026&quarter=2`),
 * so a link from the year-end checklist opens the year and quarter it names.
 * Values a panel cannot show are ignored and the panel keeps its own default.
 */
export function linkedReportYear(params: URLSearchParams, years: number[]): number | null {
  const year = Number(params.get('year'));
  return years.includes(year) ? year : null;
}

export function linkedReportQuarter(params: URLSearchParams): number | null {
  const quarter = Number(params.get('quarter'));
  return [1, 2, 3, 4].includes(quarter) ? quarter : null;
}

export function reportPeriodPath(report: string, year: number, quarter?: number): string {
  const params = new URLSearchParams({ report, year: String(year) });
  if (quarter) params.set('quarter', String(quarter));
  return `/reports?${params.toString()}`;
}
