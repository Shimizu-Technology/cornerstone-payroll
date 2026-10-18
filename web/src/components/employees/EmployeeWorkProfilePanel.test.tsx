// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Employee } from '@/types';
import type { CompanyListItem } from '@/services/api';
import { EmployeeWorkProfilePanel } from './EmployeeWorkProfilePanel';

const mocks = vi.hoisted(() => ({ activeCompany: null as CompanyListItem | null, create: vi.fn() }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: { id: 1, client_capabilities: ['manage_client_configuration'], ...mocks.activeCompany }, activeCompanyId: 1 }) }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({}) }));
vi.mock('@/services/api', () => ({ employeesApi: { createWorkProfile: mocks.create } }));
vi.mock('./EmployeeTimeRecordsDialog', () => ({ EmployeeTimeRecordsDialog: () => null }));
const employee = { id: 5, employment_type: 'salary', hire_date: '2026-01-01' } as Employee;

describe('work profile workspace permissions', () => {
  afterEach(cleanup);
  beforeEach(() => { vi.clearAllMocks(); mocks.activeCompany = null; });
  it('keeps daily time review while hiding configuration writes from a manager workspace operator', () => {
    mocks.activeCompany = { test_workspace: true, workspace_can_write: true, workspace_write_permissions: { manage_client_configuration: false } } as unknown as CompanyListItem;
    const view = render(<EmployeeWorkProfilePanel employee={employee} canManage onUpdated={vi.fn()} />);
    expect(screen.getByRole('button', { name: 'Review daily time' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Set up profile' })).toBeNull();
    mocks.activeCompany = { ...mocks.activeCompany, workspace_write_permissions: { manage_client_configuration: true } };
    view.rerender(<EmployeeWorkProfilePanel employee={employee} canManage onUpdated={vi.fn()} />);
    expect(screen.getByRole('button', { name: 'Set up profile' })).toBeTruthy();
    view.rerender(<EmployeeWorkProfilePanel employee={employee} canManage={false} onUpdated={vi.fn()} />);
    expect(screen.queryByRole('button', { name: 'Set up profile' })).toBeNull();
  });
  it('preserves an open draft and Cancel when effective configuration permission disappears', async () => {
    const user = userEvent.setup();
    const configuredEmployee = { ...employee, current_work_profile: {
      id: 7, effective_on: '2026-01-01', overtime_status: 'nonexempt', standard_weekly_hours: 40,
      salary_covers_weekly_hours: 40, salary_coverage_reason: 'Confirmed employment agreement',
      timekeeping_mode: 'schedule_with_exceptions', daily_schedule: { monday: 8, tuesday: 8, wednesday: 8, thursday: 8, friday: 8, saturday: 0, sunday: 0 },
    } } as unknown as Employee;
    const view = render(<EmployeeWorkProfilePanel employee={configuredEmployee} canManage onUpdated={vi.fn()} />);
    await user.click(screen.getByRole('button', { name: 'Change profile' }));
    const confirmation = screen.getByPlaceholderText('Example: Employment agreement confirms the weekly salary covers 45 straight-time hours.');
    await user.type(confirmation, ' Retained draft');
    expect(screen.getByRole('button', { name: 'Confirm new profile' }).hasAttribute('disabled')).toBe(false);
    mocks.activeCompany = { test_workspace: true, workspace_can_write: true, workspace_write_permissions: { manage_client_configuration: false } } as unknown as CompanyListItem;
    view.rerender(<EmployeeWorkProfilePanel employee={configuredEmployee} canManage onUpdated={vi.fn()} />);
    expect((confirmation as HTMLTextAreaElement).value).toContain('Retained draft');
    expect(screen.getByRole('button', { name: 'Confirm new profile' }).hasAttribute('disabled')).toBe(true);
    await user.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(mocks.create).not.toHaveBeenCalled();
  });
});
