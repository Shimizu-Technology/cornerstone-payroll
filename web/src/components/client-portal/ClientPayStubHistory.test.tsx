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
  mocks.history.mockResolvedValue({ pay_stubs: [], quickbooks_paychecks: [] });
  render(<ClientPayStubHistory employeeId={8} />);
  expect(await screen.findByText(/No finished payroll/)).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Download pay stub' })).toBeNull();
});

it('shows imported checks under a From QuickBooks records heading', async () => {
  mocks.history.mockResolvedValue({
    pay_stubs: [{ id: 9, pay_period_id: 2, period_description: '08/01/2026 - 08/14/2026', start_date: '2026-08-01', end_date: '2026-08-14', pay_date: '2026-08-19', net_pay: 1100 }],
    quickbooks_paychecks: [
      {
        id: 501,
        pay_date: '2026-02-19',
        period_start: '2026-02-01',
        period_end: '2026-02-14',
        gross_pay: 1400,
        net_pay: 1125.5,
        source_label: 'From QuickBooks records',
        adjustment_note: null,
      },
    ],
  });
  render(<ClientPayStubHistory employeeId={10} />);
  expect(await screen.findByRole('heading', { name: 'From QuickBooks records' })).toBeTruthy();
  expect(screen.getByText('Aug 1 – 14, 2026')).toBeTruthy();
  expect(screen.getByText(/Pay date Aug 19, 2026/)).toBeTruthy();
  expect(screen.getByText('Feb 1 – 14, 2026')).toBeTruthy();
  expect(screen.getByText(/Pay date Feb 19, 2026/)).toBeTruthy();
  expect(screen.getByText(/\$1,125\.50/)).toBeTruthy();
});
