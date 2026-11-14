// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ClientPayStubHistory } from './ClientPayStubHistory';
const mocks = vi.hoisted(() => ({ history: vi.fn(), download: vi.fn() }));
vi.mock('@/services/api', () => ({ clientPayStubsApi: mocks }));
vi.mock('@/components/documents/PdfPreview', () => ({ PdfPreview: ({ artifact }: { artifact: unknown }) => artifact ? <div>PDF opened</div> : null }));
afterEach(cleanup);
it('opens a finished stub and reports a download failure with retry', async () => {
  mocks.history.mockResolvedValue({ pay_stubs: [{ id: 9, period_description: 'Apr 1 – 14', pay_date: '2026-04-18', net_pay: 100 }] });
  mocks.download.mockRejectedValueOnce(new Error('Could not download')).mockResolvedValue({ blob: new Blob(['pdf']), filename: 'stub.pdf' });
  render(<ClientPayStubHistory employeeId={7} />);
  fireEvent.click(await screen.findByRole('button', { name: 'View pay stub' }));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Could not download');
  fireEvent.click(screen.getByRole('button', { name: 'View pay stub' }));
  expect(await screen.findByText('PDF opened')).toBeTruthy();
  expect(mocks.download).toHaveBeenLastCalledWith(9);
});
it('shows an empty state without download controls', async () => {
  mocks.history.mockResolvedValue({ pay_stubs: [] });
  render(<ClientPayStubHistory employeeId={8} />);
  expect(await screen.findByText(/No finished payroll/)).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Download pay stub' })).toBeNull();
});
