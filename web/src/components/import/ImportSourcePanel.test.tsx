// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { ImportSourceDocument } from '@/services/api';
import { ImportSourcePanel } from './ImportSourcePanel';

const mocks = vi.hoisted(() => ({ previewSource: vi.fn(), downloadSource: vi.fn(), loadPdf: vi.fn() }));
vi.mock('@/services/api', async (original) => ({
  ...await original<typeof import('@/services/api')>(),
  payrollIntakeImportsApi: { previewSource: mocks.previewSource, downloadSource: mocks.downloadSource },
}));
vi.mock('@/components/documents/PdfPreview', () => ({
  get PdfDocumentView() {
    mocks.loadPdf();
    return ({ blob }: { blob: Blob | null }) => <div data-testid="pdf-view">{blob ? `pdf ${blob.size} bytes` : 'no pdf'}</div>;
  },
}));

const pdf: ImportSourceDocument = { id: 11, source_role: 'revel_hours', filename: 'revel-hours.pdf', content_type: 'application/pdf', byte_size: 8 };
const workbook: ImportSourceDocument = { id: 12, source_role: 'supplemental_workbook', filename: 'changes.xlsx', content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', byte_size: 20 };
const sheetJson = { sheet_preview: { sheet_count: 1, truncated_sheets: false, limits: { sheets: 10, rows: 500, columns: 50 },
  sheets: [{ name: 'TIPS', columns: 2, truncated_rows: false, truncated_columns: false, rows: [{ number: 1, cells: ['Ava Cruz', '42.5'] }] }] } };

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
  expect(await screen.findByRole('cell', { name: 'Ava Cruz' })).toBeTruthy();
  expect(screen.getByText('changes.xlsx')).toBeTruthy();
  expect(mocks.previewSource).toHaveBeenCalledWith(9, 30, 12);

  fireEvent.click(screen.getByRole('tab', { name: 'Revel PDF' }));
  expect(await screen.findByTestId('pdf-view')).toBeTruthy();
  expect(mocks.previewSource).toHaveBeenCalledTimes(2);
});

it('keeps the review open when the PDF chunk fails and retries the loader in place', async () => {
  mocks.loadPdf.mockImplementationOnce(() => { throw new Error('Could not fetch preview chunk'); });
  mocks.downloadSource.mockRejectedValueOnce(new Error('Synthetic download failure'));
  render(<div role="dialog" aria-label="Import review">
    <input aria-label="Review note" defaultValue="Keep this draft" />
    <ImportSourcePanel payPeriodId={9} importId={30} documents={[pdf]} />
  </div>, { onCaughtError: () => {} });

  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'The PDF preview could not load.');
  expect(screen.getByRole('dialog', { name: 'Import review' })).toBeTruthy();
  expect(screen.getByRole('textbox', { name: 'Review note' })).toHaveProperty('value', 'Keep this draft');

  fireEvent.click(screen.getByRole('button', { name: 'Download PDF' }));
  expect(await screen.findByText('Synthetic download failure')).toBeTruthy();
  expect(mocks.downloadSource).toHaveBeenCalledWith(9, 30, 11);

  fireEvent.click(screen.getByRole('button', { name: 'Retry preview' }));
  expect(await screen.findByTestId('pdf-view')).toBeTruthy();
  expect(mocks.loadPdf).toHaveBeenCalledTimes(2);
  expect(mocks.previewSource).toHaveBeenCalledOnce();
  expect(screen.queryByText('The PDF preview could not load.')).toBeNull();
});

it('advises saving and reloading after a second consecutive PDF preview failure while keeping Retry and promoting Download', async () => {
  mocks.loadPdf
    .mockImplementationOnce(() => { throw new Error('Could not fetch preview chunk'); })
    .mockImplementationOnce(() => { throw new Error('Transitive chunk failed'); });
  render(<ImportSourcePanel payPeriodId={9} importId={30} documents={[pdf]} />, { onCaughtError: () => {} });

  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'The PDF preview could not load.');
  expect(screen.queryByText(/save your review and reload the page/)).toBeNull();

  fireEvent.click(screen.getByRole('button', { name: 'Retry preview' }));

  expect(await screen.findByText("If the preview still won't load, save your review and reload the page.")).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Retry preview' })).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Reload page' })).toBeNull();
  const downloadBtn = screen.getByRole('button', { name: 'Download PDF' });
  expect(downloadBtn.className).toContain('bg-primary-700');
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
  await waitFor(() => expect(screen.getByRole('cell', { name: 'Ava Cruz' })).toBeTruthy());
  expect(mocks.previewSource).toHaveBeenCalledTimes(2);
});

it('says why a damaged workbook is not shown', async () => {
  mocks.previewSource.mockResolvedValueOnce({ blob: new Blob([JSON.stringify({ sheet_preview: null, sheet_preview_unavailable: 'This spreadsheet could not be read.' })], { type: 'application/json' }) });
  render(<ImportSourcePanel payPeriodId={9} importId={30} documents={[workbook]} />);

  expect(await screen.findByText('Preview not available')).toBeTruthy();
  expect(screen.getByText('This spreadsheet could not be read.')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Download changes.xlsx' })).toBeTruthy();
});
