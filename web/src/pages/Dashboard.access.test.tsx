// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { Dashboard } from './Dashboard';

const mocks = vi.hoisted(() => ({ company: {} as Record<string, unknown>, dashboard: vi.fn() }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 11, activeCompany: mocks.company }) }));
vi.mock('@/services/api', () => ({ reportsApi: { dashboard: mocks.dashboard } }));
vi.mock('@/components/layout/Header', () => ({ Header: ({ actions }: { actions: React.ReactNode }) => <div>{actions}</div> }));
beforeEach(() => {
  vi.clearAllMocks();
  mocks.dashboard.mockResolvedValue({ stats: { active_employees: 1, total_employees: 1, current_pay_period: null, recent_payrolls: [] } });
});
afterEach(cleanup);

it.each([
  { test_workspace: true, workspace_can_write: false },
  { test_workspace: true, workspace_can_write: true, test_workspace_expired: true },
  { test_workspace: true, workspace_can_write: true, test_workspace_archived_at: '2026-10-14T00:00:00Z' },
  { test_workspace: true, workspace_can_write: true, test_workspace_sealed_at: '2026-10-14T00:00:00Z' },
])('offers review destinations instead of mutation prompts for %j', async (access) => {
  mocks.company = { id: 11, ...access };
  render(<MemoryRouter><Dashboard /></MemoryRouter>);
  expect(await screen.findByText('Review preserved payroll records')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Add employee' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Create pay period' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Process payroll' })).toBeNull();
  expect(screen.getByText('Browse employees')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Browse Pay Periods' })).toBeTruthy();
});

it('keeps the ordinary and authorized operator workflow available', async () => {
  mocks.company = { id: 11, test_workspace: true, workspace_can_write: true };
  render(<MemoryRouter><Dashboard /></MemoryRouter>);
  expect(await screen.findByRole('button', { name: 'Create the next pay period' })).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Add employee' })).toBeTruthy();
});

it('does not offer processing of a draft after effective access becomes read-only', async () => {
  mocks.company = { id: 11, test_workspace: true, workspace_can_write: false };
  mocks.dashboard.mockResolvedValue({ stats: { active_employees: 1, total_employees: 1, current_pay_period: { id: 12, status: 'draft', start_date: '2026-10-01', end_date: '2026-10-15', pay_date: '2026-10-20', employee_count: 1, total_gross: 100, total_net: 90 }, recent_payrolls: [] } });
  render(<MemoryRouter><Dashboard /></MemoryRouter>);
  expect(await screen.findByRole('button', { name: 'Continue' })).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Process payroll' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Continue pay cycle' })).toBeNull();
});

 it('leads with the selected period and names its next action without draft money', async () => {
  mocks.company = { id: 11, name: 'Synthetic client' };
  mocks.dashboard.mockResolvedValue({ stats: { active_employees: 2, total_employees: 2,
    current_pay_period: { id: 12, period_description: 'Oct 1–15, 2026', pay_date: '2026-10-31', status: 'draft', run_purpose: 'regular', employee_count: 0, total_gross: 0, total_net: 0,
      next_action: 'Review & add hours', blocker: 'Time tracking hours have not been added.' },
    last_regular_payroll: { id: 9, pay_date: '2026-10-15', total_net: 3200, run_purpose: 'regular' },
    last_adjustment_payroll: { id: 10, pay_date: '2026-10-20', total_net: 92.35, run_purpose: 'adjustment' }, recent_payrolls: [] } });
  render(<MemoryRouter><Dashboard /></MemoryRouter>);
  expect(await screen.findByRole('heading', { name: 'Oct 1–15, 2026' })).toBeTruthy();
  expect(screen.getByText('Next: Review & add hours')).toBeTruthy();
  expect(screen.getByText('Last regular payroll')).toBeTruthy();
  expect(screen.getByText('Last adjustment payroll')).toBeTruthy();
  expect(screen.getByText('$92.35')).toBeTruthy();
  expect(screen.queryByText(/0 employees.*net pay/)).toBeNull();
  expect(screen.queryByText(/fewer handoffs/)).toBeNull();
});
