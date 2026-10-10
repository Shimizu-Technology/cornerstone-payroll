// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { PdfPreview } from './PdfPreview';

const pdfMocks = vi.hoisted(() => ({ destroy: vi.fn(), getDocument: vi.fn(), getPage: vi.fn(), cancel: vi.fn() }));
vi.mock('pdfjs-dist', () => ({ GlobalWorkerOptions: { workerSrc: '' }, getDocument: pdfMocks.getDocument }));

beforeEach(() => {
  pdfMocks.destroy.mockReset();
  pdfMocks.cancel.mockReset();
  pdfMocks.getPage.mockReset().mockResolvedValue({ getViewport: () => ({ width: 612, height: 792 }), render: () => ({ promise: Promise.resolve(), cancel: pdfMocks.cancel }) });
  pdfMocks.getDocument.mockReset().mockImplementation(() => ({ promise: Promise.resolve({ numPages: 2, getPage: pdfMocks.getPage }), destroy: pdfMocks.destroy }));
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

it('renders pages without downloading until requested and cleans up the PDF worker', async () => {
  const create = vi.spyOn(URL, 'createObjectURL').mockReturnValue('http://localhost/preview.pdf');
  const revoke = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
  const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
  const open = vi.spyOn(window, 'open').mockImplementation(() => null);
  const artifact = { blob: new Blob(['%PDF-1.4'], { type: 'application/pdf' }), filename: 'test-checks.pdf', title: 'Mock checks' };
  const onClose = vi.fn();

  const view = render(<PdfPreview artifact={artifact} onClose={onClose} />);
  expect(screen.queryByTitle('PDF print source')).toBeNull();
  expect(open).not.toHaveBeenCalled();
  expect(await screen.findByText('Page 1 of 2')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Next' }));
  expect(await screen.findByText('Page 2 of 2')).toBeTruthy();
  expect(pdfMocks.getPage).toHaveBeenCalledWith(2);
  expect(click).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Open to print' }));
  expect(open).toHaveBeenCalledWith('http://localhost/preview.pdf', '_blank', 'noopener,noreferrer');
  fireEvent.click(screen.getByRole('button', { name: 'Download' }));
  expect(click).toHaveBeenCalledOnce();
  expect(create).toHaveBeenCalledWith(artifact.blob);

  fireEvent.keyDown(document, { key: 'Escape' });
  expect(onClose).toHaveBeenCalledOnce();
  view.unmount();
  expect(revoke).toHaveBeenCalledWith('http://localhost/preview.pdf');
  expect(pdfMocks.destroy).toHaveBeenCalledOnce();
});


it('keeps the original statement download available when a page cannot render', async () => {
  vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:statement');
  vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
  const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
  pdfMocks.getPage.mockRejectedValue(new Error('Page render failed'));
  const artifact = { blob: new Blob(['%PDF-1.4'], { type: 'application/pdf' }), filename: 'statement.pdf' };
  render(<PdfPreview artifact={artifact} onClose={vi.fn()} />);
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('page could not be displayed'));
  fireEvent.click(screen.getByRole('button', { name: 'Download' }));
  expect(click).toHaveBeenCalledOnce();
});

it('resets shared statement pages and cancels stale rendering when its blob changes', async () => {
  vi.spyOn(URL, 'createObjectURL').mockReturnValueOnce('blob:first').mockReturnValueOnce('blob:second');
  const revoke = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
  const first = { blob: new Blob(['%PDF-first']), filename: 'first.pdf' };
  const second = { blob: new Blob(['%PDF-second']), filename: 'second.pdf' };
  const view = render(<PdfPreview artifact={first} onClose={vi.fn()} />);
  await screen.findByText('Page 1 of 2');
  fireEvent.click(screen.getByRole('button', { name: 'Next' }));
  await screen.findByText('Page 2 of 2');
  let resolveOldPage!: (page: { getViewport: () => { width: number; height: number }; render: () => { promise: Promise<void>; cancel: () => void } }) => void;
  pdfMocks.getPage.mockReturnValueOnce(new Promise((resolve) => { resolveOldPage = resolve; }));
  fireEvent.click(screen.getByRole('button', { name: 'Previous' }));
  await waitFor(() => expect(pdfMocks.getPage).toHaveBeenCalledTimes(3));
  view.rerender(<PdfPreview artifact={second} onClose={vi.fn()} />);
  await screen.findByText('Page 1 of 2');
  const paint = vi.fn(() => ({ promise: Promise.resolve(), cancel: vi.fn() }));
  await act(async () => { resolveOldPage({ getViewport: () => ({ width: 612, height: 792 }), render: paint }); });
  expect(paint).not.toHaveBeenCalled();
  expect(pdfMocks.destroy).toHaveBeenCalled();
  expect(revoke).toHaveBeenCalledWith('blob:first');
  view.unmount();
  expect(revoke).toHaveBeenCalledWith('blob:second');
});
