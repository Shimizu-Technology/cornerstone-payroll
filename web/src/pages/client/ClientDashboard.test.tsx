// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { clientPayPeriodsApi } from '@/services/api';
import { ClientDashboard } from './ClientDashboard';

vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 2 }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/payroll-submissions/PayrollFilesEntry', () => ({ PayrollFilesEntry: () => null }));
vi.mock('@/services/api', () => ({
  clientReportsApi: { dashboard: vi.fn().mockResolvedValue({ stats: {} }) },
  clientDocumentsApi: { list: vi.fn().mockResolvedValue({ meta: { total_count: 0 } }) },
  clientPayPeriodsApi: { list: vi.fn() },
}));

afterEach(cleanup);

it.each([true, false])('offers a dashboard approval link only when decision access is %s', async canDecide => {
  const payroll = {
    id: 19,
    key: 'native:19',
    start_date: '2026-11-08',
    end_date: '2026-11-21',
    pay_date: '2026-11-27',
    status: 'approved',
    client_review_status: 'pending',
    can_decide_payroll_review: canDecide,
  };
  vi.mocked(clientPayPeriodsApi.list).mockResolvedValue({ pay_periods: [payroll] } as Awaited<ReturnType<typeof clientPayPeriodsApi.list>>);
  render(<MemoryRouter><ClientDashboard /></MemoryRouter>);
  expect(screen.getByRole('heading', { name: 'Needs your attention' })).toBeTruthy();
  if (canDecide) {
    expect(await screen.findByRole('link', { name: 'Open payroll preview' })).toHaveProperty('pathname', '/companies/2/pay-runs/19/overview');
  } else {
    expect(await screen.findByText('No payroll needs your approval right now.')).toBeTruthy();
    expect(screen.queryByRole('link', { name: 'Open payroll preview' })).toBeNull();
  }
});

it('shows an open payroll whose pay date is still unset', async () => {
  vi.mocked(clientPayPeriodsApi.list).mockResolvedValue({
    pay_periods: [],
    meta: { current_page: 1, per_page: 25, total_count: 0, total_pages: 0, statuses: {}, sources: {}, years: [] },
    open_period: {
      ref: '2026-11-01_2026-11-15',
      start_date: '2026-11-01',
      end_date: '2026-11-15',
      pay_date: null,
      client_payroll_status: 'preparing',
    },
  } as Awaited<ReturnType<typeof clientPayPeriodsApi.list>>);
  render(<MemoryRouter><ClientDashboard /></MemoryRouter>);
  expect(await screen.findByText(/Pay date to be set/)).toBeTruthy();
});
