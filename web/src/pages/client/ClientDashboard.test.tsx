// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { clientPayPeriodsApi, clientReportsApi } from '@/services/api';
import { ClientDashboard } from './ClientDashboard';

vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 2 }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/payroll-submissions/PayrollFilesEntry', () => ({ PayrollFilesEntry: () => null }));
vi.mock('@/services/api', () => ({
  clientReportsApi: { dashboard: vi.fn().mockResolvedValue({ stats: {} }) },
  clientDocumentsApi: { list: vi.fn().mockResolvedValue({ meta: { total_count: 0 } }) },
  clientPayPeriodsApi: { list: vi.fn() },
}));

const emptyPayroll = {
  pay_periods: [],
  meta: { current_page: 1, per_page: 100, total_count: 0, total_pages: 0, statuses: {}, sources: {}, years: [] },
};

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

it('keeps stats visible when payroll lookup fails and retries only payroll', async () => {
  vi.mocked(clientReportsApi.dashboard).mockResolvedValueOnce({ stats: { active_employees: 7 } } as Awaited<ReturnType<typeof clientReportsApi.dashboard>>);
  vi.mocked(clientPayPeriodsApi.list)
    .mockRejectedValueOnce(new Error('Payroll unavailable'))
    .mockResolvedValueOnce(emptyPayroll);
  render(<MemoryRouter><ClientDashboard /></MemoryRouter>);

  expect(await screen.findByText('7')).toBeTruthy();
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', "Couldn't check for payroll approvals.");
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

  expect(await screen.findByText('No payroll needs your approval right now.')).toBeTruthy();
  expect(screen.getByText('7')).toBeTruthy();
  expect(screen.queryByRole('alert')).toBeNull();
});

it('loads payroll attention when dashboard stats fail', async () => {
  vi.mocked(clientReportsApi.dashboard).mockRejectedValueOnce(new Error('Stats unavailable'));
  vi.mocked(clientPayPeriodsApi.list).mockResolvedValueOnce(emptyPayroll);
  render(<MemoryRouter><ClientDashboard /></MemoryRouter>);

  expect(await screen.findByText('Stats unavailable')).toBeTruthy();
  expect(await screen.findByText('No payroll needs your approval right now.')).toBeTruthy();
});

it.each([{}, { pay_periods: [null] }, { pay_periods: [{ can_decide_payroll_review: true }] }, { pay_periods: [], open_period: {} }])(
  'contains malformed payroll data in the attention card (%j)',
  async payload => {
    vi.mocked(clientPayPeriodsApi.list).mockResolvedValueOnce(payload as Awaited<ReturnType<typeof clientPayPeriodsApi.list>>);
    render(<MemoryRouter><ClientDashboard /></MemoryRouter>);

    expect(await screen.findByRole('button', { name: 'Try again' })).toBeTruthy();
    expect(screen.getByText('Active employees')).toBeTruthy();
  },
);


it('formats the pay period and payday in Recent payrolls', async () => {
  vi.mocked(clientPayPeriodsApi.list).mockResolvedValueOnce(emptyPayroll);
  vi.mocked(clientReportsApi.dashboard).mockResolvedValueOnce({
    stats: { recent_payrolls: [{
      id: 19, start_date: '2026-10-26', end_date: '2026-11-08', pay_date: '2026-11-11',
      period_description: '10/26/2026 - 11/08/2026', employee_count: 3, total_net: 1200,
    }] },
  } as Awaited<ReturnType<typeof clientReportsApi.dashboard>>);

  render(<MemoryRouter><ClientDashboard /></MemoryRouter>);

  expect(await screen.findByRole('button', { name: /Oct 26 – Nov 8, 2026.*Nov 11, 2026/ })).toBeTruthy();
});
