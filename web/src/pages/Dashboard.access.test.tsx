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
  expect(screen.getByText('Browse Employees')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Browse Pay Periods' })).toBeTruthy();
});

it('keeps the ordinary and authorized operator workflow available', async () => {
  mocks.company = { id: 11, test_workspace: true, workspace_can_write: true };
  render(<MemoryRouter><Dashboard /></MemoryRouter>);
  expect(await screen.findByRole('button', { name: 'Add employee' })).toBeTruthy();
  expect(screen.getAllByRole('button', { name: 'Create pay period' })).toHaveLength(2);
});

it('does not offer processing of a draft after effective access becomes read-only', async () => {
  mocks.company = { id: 11, test_workspace: true, workspace_can_write: false };
  mocks.dashboard.mockResolvedValue({ stats: { active_employees: 1, total_employees: 1, current_pay_period: { id: 12, status: 'draft', start_date: '2026-10-01', end_date: '2026-10-15', pay_date: '2026-10-20', employee_count: 1, total_gross: 100, total_net: 90 }, recent_payrolls: [] } });
  render(<MemoryRouter><Dashboard /></MemoryRouter>);
  expect(await screen.findByRole('button', { name: 'Open period' })).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Process payroll' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Continue pay cycle' })).toBeNull();
});
