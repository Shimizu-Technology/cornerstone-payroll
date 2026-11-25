// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { clientPayrollSubmissionsApi } from '@/services/payrollSubmissions';
import { PayrollPeriodsList } from './PayrollPeriodsList';

vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({}) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/services/payrollSubmissions', () => ({
  clientPayrollSubmissionsApi: { list: vi.fn() },
  adminPayrollSubmissionsApi: { list: vi.fn() },
}));

afterEach(cleanup);

it('shows outstanding file requests alongside the finalized status', async () => {
  vi.mocked(clientPayrollSubmissionsApi.list).mockResolvedValue({
    data: [{
      ref: '9', label: 'Nov 2–15, 2026', pay_date: '2026-11-20', status: 'in_review',
      status_label: 'Requested files outstanding', client_payroll_status: 'committed',
    }],
    meta: { derives_from_schedule: true },
  } as Awaited<ReturnType<typeof clientPayrollSubmissionsApi.list>>);
  render(<MemoryRouter><PayrollPeriodsList audience="client" /></MemoryRouter>);
  const row = await screen.findByRole('link', { name: /Payroll Nov 2/ });
  expect(within(row).getByText('Finalized')).toBeTruthy();
  expect(within(row).getByText('Requested files outstanding')).toBeTruthy();
});
