import { createElement, Fragment, type ReactNode } from 'react';
import { useSearchParams } from 'react-router';

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

/**
 * Remounts a period panel whenever the URL's year or quarter changes (Back,
 * Forward or a new link). The panel then reads both values from the URL again,
 * drops every report it had loaded for the old period, and late responses for
 * the old period land on the unmounted panel. Choosing a period in the panel's
 * own selector doesn't change the URL, so it doesn't remount.
 */
export function PeriodKeyed({ children }: { children: ReactNode }) {
  const [searchParams] = useSearchParams();
  const periodKey = `${searchParams.get('year') ?? ''}:${searchParams.get('quarter') ?? ''}`;
  return createElement(Fragment, { key: periodKey }, children);
}
