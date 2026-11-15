// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import type { SheetPreviewData } from '@/lib/sheetPreview';
import { columnLetter } from '@/lib/sheetPreview';
import { SheetPreview } from './SheetPreview';

afterEach(cleanup);

const limits = { sheets: 10, rows: 500, columns: 50 };
const workbook: SheetPreviewData = {
  sheet_count: 2,
  truncated_sheets: false,
  limits,
  sheets: [
    { name: 'TIPS', columns: 2, truncated_rows: false, truncated_columns: false, rows: [
      { number: 1, cells: ['Employee', 'Tips'] },
      { number: 3, cells: ['Avery Sample', '$1,234.50'] },
    ] },
    { name: 'LOANS', columns: 1, truncated_rows: true, truncated_columns: true, rows: [{ number: 1, cells: ['Loan'] }] },
  ],
};

it('shows each sheet as a table with Excel row numbers and column letters', () => {
  render(<SheetPreview data={workbook} />);

  const table = screen.getByRole('table', { name: 'TIPS' });
  expect(within(table).getByRole('columnheader', { name: 'A' })).toBeTruthy();
  expect(within(table).getByRole('columnheader', { name: 'B' })).toBeTruthy();
  expect(within(table).getByRole('rowheader', { name: '3' })).toBeTruthy();
  expect(within(table).getByRole('cell', { name: '$1,234.50' }).className).toContain('text-right');
  expect(screen.queryByRole('note')).toBeNull();
});

it('switches sheets with tabs and notes truncation', () => {
  render(<SheetPreview data={workbook} />);

  const tabs = screen.getAllByRole('tab');
  expect(tabs.map((tab) => tab.textContent)).toEqual(['TIPS', 'LOANS']);
  expect(tabs[0].getAttribute('aria-selected')).toBe('true');
  fireEvent.click(tabs[1]);

  expect(screen.getByRole('tab', { name: 'LOANS' }).getAttribute('aria-selected')).toBe('true');
  expect(screen.getByRole('table', { name: 'LOANS' })).toBeTruthy();
  expect(screen.getByRole('note').textContent).toBe('Showing the first 500 rows with data. Showing the first 50 columns. Download the file to see everything.');
});

it('hides tabs for a single sheet and explains empty or extra sheets', () => {
  render(<SheetPreview data={{ ...workbook, sheet_count: 12, truncated_sheets: true, sheets: [{ name: 'Blank', columns: 0, rows: [], truncated_rows: false, truncated_columns: false }] }} />);

  expect(screen.queryByRole('tablist')).toBeNull();
  expect(screen.getByText('This sheet is empty.')).toBeTruthy();
  expect(screen.getByRole('note').textContent).toContain('Showing the first 1 of 12 sheets.');
});

it('names columns past Z like Excel', () => {
  expect([0, 25, 26, 51, 701, 702].map(columnLetter)).toEqual(['A', 'Z', 'AA', 'AZ', 'ZZ', 'AAA']);
});
