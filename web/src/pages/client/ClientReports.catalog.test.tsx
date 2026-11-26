// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { ClientReports } from './ClientReports';
import { clientReportCatalog } from './clientReportCatalog';
import { guamTaxPeriod } from '@/lib/payrollBusinessDate';
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
const api = vi.hoisted(() => ({ periods: vi.fn(), employees: vi.fn(), register: vi.fn(), taxSummary: vi.fn(), annual: vi.fn(), ytd: vi.fn() }));
vi.mock('@/services/api', () => ({
  clientPayPeriodsApi: { list: api.periods },
  clientEmployeesApi: { list: api.employees },
  clientReportsApi: {
    payrollRegister: api.register,
    taxSummary: api.taxSummary,
    ytdSummary: api.ytd,
    annualPayrollSummary: api.annual,
  },
}));
beforeEach(() => {
  vi.resetAllMocks();
  api.periods.mockResolvedValue({ pay_periods: [] });
  api.employees.mockResolvedValue({ data: [] });
  api.register.mockResolvedValue({ report: null });
  api.taxSummary.mockResolvedValue({ report: { source: { label: 'Cornerstone' } } });
  api.annual.mockResolvedValue({ report: null });
  api.ytd.mockResolvedValue({ report: null });
});
afterEach(cleanup);
it('lists every client report in three groups and guards missing selections', async () => {
  render(<ClientReports />);
  expect(await screen.findByRole('region', { name: 'Report catalog' })).toBeTruthy();
  for (const report of clientReportCatalog) expect(screen.getByText(report.title)).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Export Employee Pay History' }).hasAttribute('disabled')).toBe(true);
  expect(screen.queryByText('Full Print Package')).toBeNull();
  expect(screen.queryByText('W-2GU')).toBeNull();
});

it('shows the imported payroll exclusion only for the selected tax range', async () => {
  const statement = 'Imported QuickBooks/prior-provider payroll is not included. Excluded $90.00 in Guam income tax.';
  api.taxSummary.mockImplementation(async ({ quarter }: { quarter: string }) => ({
    report: { source: { label: 'Cornerstone', statement: quarter === '2' ? statement : null } },
  }));
  render(<ClientReports />);
  const quarter = await screen.findByRole('combobox', { name: 'Quarter' });
  fireEvent.change(quarter, { target: { value: '2' } });
  expect(await screen.findAllByText(statement)).toHaveLength(2);

  fireEvent.change(quarter, { target: { value: '1' } });
  expect(screen.queryByText(statement)).toBeNull();
  await waitFor(() => expect(api.taxSummary).toHaveBeenLastCalledWith({ year: Number(guamTaxPeriod().tax_year), quarter: '1' }));
});

it("opens on Guam's tax year, quarter and date while California is still on Dec 31", async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2025-12-31T14:30:00Z'));
  try {
    render(<ClientReports />);
    await waitFor(() => expect(api.taxSummary).toHaveBeenCalledWith({ year: 2026, quarter: '1' }));
    expect((screen.getByLabelText('Client report start date') as HTMLInputElement).value).toBe('2026-01-01');
    expect((screen.getByLabelText('Client report end date') as HTMLInputElement).value).toBe('2026-01-01');
  } finally {
    vi.useRealTimers();
  }
});

it('selects only committed and baseline payroll when newer runs await approval', async () => {
  api.periods.mockResolvedValue({ pay_periods: [
    { id: 9, record_type: 'native', status: 'approved', start_date: '2026-06-01', end_date: '2026-06-14' },
    { id: 8, record_type: 'native', status: 'calculated', start_date: '2026-05-01', end_date: '2026-05-14' },
    { id: 7, record_type: 'native', status: 'approved', test_workspace_role: 'baseline', start_date: '2026-04-01', end_date: '2026-04-14' },
    { id: 6, record_type: 'native', status: 'committed', start_date: '2026-03-01', end_date: '2026-03-14' },
  ] });
  render(<ClientReports />);
  await waitFor(() => expect(api.register).toHaveBeenCalledWith(7));
  expect(screen.queryByRole('option', { name: 'Jun 1 – 14, 2026' })).toBeNull();
  expect(screen.queryByRole('option', { name: 'May 1 – 14, 2026' })).toBeNull();
  expect(screen.getByRole('option', { name: 'Mar 1 – 14, 2026' })).toBeTruthy();
});

it('keeps payroll reports available on employee-list failure and retries all employee pages', async () => {
  api.employees.mockRejectedValueOnce(new Error('Employee service unavailable'));
  render(<ClientReports />);
  expect(await screen.findByRole('region', { name: 'Report catalog' })).toBeTruthy();
  expect(await screen.findByText(/Employee reports are unavailable/)).toBeTruthy();
  api.employees.mockResolvedValueOnce({ data: [{ id: 1, first_name: 'Ana', last_name: 'Perez' }], meta: { total_pages: 2 } })
    .mockResolvedValueOnce({ data: [{ id: 2, first_name: 'Ben', last_name: 'Cruz' }], meta: { total_pages: 2 } });
  fireEvent.click(screen.getByRole('button', { name: 'Retry loading employees' }));
  expect(await screen.findByRole('option', { name: 'Ben Cruz' })).toBeTruthy();
  expect(screen.getByRole('option', { name: 'Ana Perez' })).toBeTruthy();
  expect(screen.queryByText(/Employee reports are unavailable/)).toBeNull();
});

it('reads every page of pay periods before choosing finished payroll', async () => {
  api.periods
    .mockResolvedValueOnce({ pay_periods: [{ id: 9, record_type: 'native', status: 'approved', start_date: '2026-06-01', end_date: '2026-06-14' }], meta: { current_page: 1, total_pages: 2 } })
    .mockResolvedValueOnce({ pay_periods: [{ id: 4, record_type: 'native', status: 'committed', start_date: '2026-01-01', end_date: '2026-01-14' }], meta: { current_page: 2, total_pages: 2 } });
  render(<ClientReports />);
  await waitFor(() => expect(api.register).toHaveBeenCalledWith(4));
  expect(api.periods).toHaveBeenNthCalledWith(2, { page: 2, per_page: 100 });
  expect(screen.getByRole('option', { name: 'Jan 1 – 14, 2026' })).toBeTruthy();
});

it('keeps reading past fifty pages until the last page the server reports', async () => {
  api.periods.mockImplementation(async ({ page }: { page: number }) => ({
    pay_periods: [{ id: page, record_type: 'native', status: page === 60 ? 'committed' : 'approved', start_date: '2020-01-01', end_date: `2020-01-${String(page % 28 + 1).padStart(2, '0')}` }],
    meta: { current_page: page, total_pages: 60 },
  }));
  render(<ClientReports />);
  await waitFor(() => expect(api.register).toHaveBeenCalledWith(60));
  expect(api.periods).toHaveBeenCalledTimes(60);
});

it('replaces accountant QuickBooks snapshot jargon with plain client copy', async () => {
  const accountantText = 'QuickBooks source values remain authoritative locked snapshots and were not recalculated. Recorded ledger adjustments are shown separately and never rewrite the source.';
  api.annual.mockResolvedValue({
    report: {
      source_statement: accountantText,
      totals: { gross_pay: 1000, net_pay: 800, employer_taxes: 76.5, employer_contributions: 0, total_payroll_cost: 1076.5 },
      years: [],
    },
  });
  render(<ClientReports />);
  expect(await screen.findByText('Payroll from before Cornerstone is shown exactly as it was in QuickBooks. Any corrections are listed separately.')).toBeTruthy();
  expect(screen.queryByText(/authoritative locked snapshots/)).toBeNull();
});
