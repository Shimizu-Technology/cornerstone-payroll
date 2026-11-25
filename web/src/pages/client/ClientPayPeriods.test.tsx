// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { clientPayPeriodsApi } from '@/services/api';
import { ClientPayPeriods } from './ClientPayPeriods';

vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/services/api', () => ({ clientPayPeriodsApi: { list: vi.fn() } }));

afterEach(cleanup);

it('shows an unset pay date and preserves the Locked label for QuickBooks history', async () => {
  vi.mocked(clientPayPeriodsApi.list).mockResolvedValue({
    open_period: {
      ref: '2026-11-01_2026-11-15',
      start_date: '2026-11-01',
      end_date: '2026-11-15',
      pay_date: null,
      client_payroll_status: 'preparing',
    },
    pay_periods: [{
      id: 19, key: 'imported:19', record_type: 'imported', status: 'locked',
      start_date: '2026-10-16', end_date: '2026-10-31', pay_date: '2026-11-05',
      source: { label: 'QuickBooks import' },
    }],
  } as Awaited<ReturnType<typeof clientPayPeriodsApi.list>>);
  render(<MemoryRouter initialEntries={['/companies/2/pay-runs']}>
    <Routes><Route path="/companies/:companyId/pay-runs" element={<ClientPayPeriods />} /></Routes>
  </MemoryRouter>);
  expect(await screen.findByText(/Pay date to be set/)).toBeTruthy();
  expect(within(screen.getByRole('row', { name: /QuickBooks import/ })).getByText('Locked')).toBeTruthy();
});
