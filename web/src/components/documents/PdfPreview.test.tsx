// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { PdfPreview } from './PdfPreview';

const pdfMocks = vi.hoisted(() => ({ destroy: vi.fn(), getPage: vi.fn() }));
vi.mock('pdfjs-dist', () => ({
  GlobalWorkerOptions: { workerSrc: '' },
  getDocument: () => ({
    promise: Promise.resolve({
      numPages: 2,
      getPage: pdfMocks.getPage.mockImplementation(async () => ({
        getViewport: () => ({ width: 612, height: 792 }),
        render: () => ({ promise: Promise.resolve(), cancel: vi.fn() }),
      })),
    }),
    destroy: pdfMocks.destroy,
  }),
}));

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
