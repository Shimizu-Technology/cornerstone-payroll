// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { ImportSourceDocument } from '@/services/api';
import { ImportSourcePanel } from './ImportSourcePanel';

const mocks = vi.hoisted(() => ({ previewSource: vi.fn(), downloadSource: vi.fn() }));
vi.mock('@/services/api', async (original) => ({
  ...await original<typeof import('@/services/api')>(),
  payrollIntakeImportsApi: { previewSource: mocks.previewSource, downloadSource: mocks.downloadSource },
}));
vi.mock('@/components/documents/PdfPreview', () => ({
  PdfDocumentView: ({ blob }: { blob: Blob | null }) => <div data-testid="pdf-view">{blob ? `pdf ${blob.size} bytes` : 'no pdf'}</div>,
}));

const pdf: ImportSourceDocument = { id: 11, source_role: 'revel_hours', filename: 'revel-hours.pdf', content_type: 'application/pdf', byte_size: 8 };
const workbook: ImportSourceDocument = { id: 12, source_role: 'supplemental_workbook', filename: 'changes.xlsx', content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', byte_size: 20 };
const sheetJson = { sheet_preview: { sheet_count: 1, truncated_sheets: false, limits: { sheets: 10, rows: 500, columns: 50 },
  sheets: [{ name: 'TIPS', columns: 2, truncated_rows: false, truncated_columns: false, rows: [{ number: 1, cells: ['Avery Sample', '42.5'] }] }] } };

function setWideScreen(wide: boolean) {
  Object.defineProperty(window, 'matchMedia', { configurable: true, writable: true, value: vi.fn().mockReturnValue({ matches: wide }) });
}

beforeEach(() => {
  vi.clearAllMocks();
  setWideScreen(true);
  mocks.previewSource.mockImplementation((_period: number, _import: number, id: number) => Promise.resolve(id === pdf.id
    ? { blob: new Blob(['%PDF-1.4'], { type: 'application/pdf' }) }
    : { blob: new Blob([JSON.stringify(sheetJson)], { type: 'application/json; charset=utf-8' }) }));
});
afterEach(cleanup);

it('shows the Revel PDF and workbook tabs and loads each file when chosen', async () => {
  render(<ImportSourcePanel payPeriodId={9} importId={30} documents={[pdf, workbook]} />);

  expect(screen.getAllByRole('tab').map((tab) => tab.textContent)).toEqual(['Revel PDF', 'Workbook']);
  expect((await screen.findByTestId('pdf-view')).textContent).toBe('pdf 8 bytes');
  expect(mocks.previewSource).toHaveBeenCalledWith(9, 30, 11);

  fireEvent.click(screen.getByRole('tab', { name: 'Workbook' }));
  expect(await screen.findByRole('cell', { name: 'Avery Sample' })).toBeTruthy();
  expect(screen.getByText('changes.xlsx')).toBeTruthy();
  expect(mocks.previewSource).toHaveBeenCalledWith(9, 30, 12);

  fireEvent.click(screen.getByRole('tab', { name: 'Revel PDF' }));
  expect(await screen.findByTestId('pdf-view')).toBeTruthy();
  expect(mocks.previewSource).toHaveBeenCalledTimes(2);
});

it('hides the Workbook tab when only the PDF was provided', async () => {
  render(<ImportSourcePanel payPeriodId={9} importId={30} documents={[pdf]} />);

  expect(screen.getAllByRole('tab').map((tab) => tab.textContent)).toEqual(['Revel PDF']);
  expect(await screen.findByTestId('pdf-view')).toBeTruthy();
});

it('renders nothing without source files', () => {
  const { container } = render(<ImportSourcePanel payPeriodId={9} importId={30} documents={[]} />);

  expect(container.innerHTML).toBe('');
  expect(mocks.previewSource).not.toHaveBeenCalled();
});

it('collapses and expands, starting collapsed on narrow screens', async () => {
  setWideScreen(false);
  render(<ImportSourcePanel payPeriodId={9} importId={30} documents={[pdf, workbook]} />);

  const show = screen.getByRole('button', { name: /Show source files/ });
  expect(show.getAttribute('aria-expanded')).toBe('false');
  expect(show.textContent).toContain('Revel PDF · Workbook');
  expect(screen.queryByRole('tab')).toBeNull();
  expect(mocks.previewSource).not.toHaveBeenCalled();

  fireEvent.click(show);
  expect(await screen.findByTestId('pdf-view')).toBeTruthy();
  const hide = screen.getByRole('button', { name: 'Hide' });
  expect(hide.getAttribute('aria-expanded')).toBe('true');

  fireEvent.click(hide);
  expect(screen.queryByTestId('pdf-view')).toBeNull();
  expect(screen.getByRole('button', { name: /Show source files/ })).toBeTruthy();
});

it('explains a file that cannot be shown and retries', async () => {
  mocks.previewSource.mockRejectedValueOnce(new Error('This spreadsheet could not be read.'));
  render(<ImportSourcePanel payPeriodId={9} importId={30} documents={[workbook]} />);

  expect((await screen.findByRole('alert')).textContent).toBe('This spreadsheet could not be read.');
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  await waitFor(() => expect(screen.getByRole('cell', { name: 'Avery Sample' })).toBeTruthy());
  expect(mocks.previewSource).toHaveBeenCalledTimes(2);
});
