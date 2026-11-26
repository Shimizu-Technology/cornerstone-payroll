// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ClientPayStubButton } from './ClientPayStubButton';

const mocks = vi.hoisted(() => ({ download: vi.fn() }));
vi.mock('@/services/api', () => ({ clientPayStubsApi: mocks }));
vi.mock('@/components/documents/PdfPreview', () => ({
  PdfPreview: ({ artifact }: { artifact: unknown }) => (artifact ? <div>PDF opened</div> : null),
}));

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

it('keeps visible text inside the accessible name in compact mode and announces Preparing pay stub while busy', async () => {
  let resolveDownload!: (value: { blob: Blob; filename: string }) => void;
  mocks.download.mockImplementationOnce(
    () => new Promise((resolve) => { resolveDownload = resolve; })
  );

  render(<ClientPayStubButton itemId={42} compact employeeName="Synthetic Worker" />);

  const viewButton = screen.getByRole('button', { name: 'View stub for Synthetic Worker' });
  const downloadButton = screen.getByRole('button', { name: 'Download stub for Synthetic Worker' });
  expect(viewButton.textContent).toBe('View stub');
  expect(downloadButton.textContent).toBe('Download stub');

  fireEvent.click(downloadButton);

  expect(screen.getByRole('status').textContent).toBe('Preparing pay stub');
  expect(screen.getByRole<HTMLButtonElement>('button', { name: 'Preparing pay stub' }).textContent).toBe('Preparing…');
  expect(screen.getByRole<HTMLButtonElement>('button', { name: 'View stub for Synthetic Worker' }).disabled).toBe(true);

  const createObjectURL = vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:test');
  const revokeObjectURL = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
  await act(async () => {
    resolveDownload({ blob: new Blob(['%PDF']), filename: 'stub.pdf' });
  });
  expect(screen.getByRole('status').textContent).toBe('');
  expect(screen.getByRole('button', { name: 'Download stub for Synthetic Worker' }).textContent).toBe('Download stub');
  createObjectURL.mockRestore();
  revokeObjectURL.mockRestore();
});
