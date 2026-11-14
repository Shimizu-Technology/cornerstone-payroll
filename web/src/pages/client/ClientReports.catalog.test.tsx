// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ClientReports } from './ClientReports';
import { clientReportCatalog } from './clientReportCatalog';
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/services/api', () => ({
  clientPayPeriodsApi: { list: async () => ({ pay_periods: [] }) },
  clientEmployeesApi: { list: async () => ({ data: [] }) },
  clientReportsApi: {
    ytdSummary: async () => ({ report: null }),
    annualPayrollSummary: async () => ({ report: null }),
  },
}));
afterEach(cleanup);
it('lists every client report in three groups and guards missing selections', async () => {
  render(<ClientReports />);
  expect(await screen.findByRole('region', { name: 'Report catalog' })).toBeTruthy();
  for (const report of clientReportCatalog) expect(screen.getByText(report.title)).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Export Employee Pay History' }).hasAttribute('disabled')).toBe(true);
  expect(screen.queryByText('Full Print Package')).toBeNull();
  expect(screen.queryByText('W-2GU')).toBeNull();
});
