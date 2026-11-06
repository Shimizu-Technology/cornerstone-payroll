// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeIntakePanel } from './EmployeeIntakePanel';
import type { Employee } from '@/types';

const mocks = vi.hoisted(() => ({ update: vi.fn(), canReview: true, activeCompany: null as import('@/services/api').CompanyListItem | null }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: { id: 1, client_capabilities: mocks.canReview ? ['manage_client_configuration'] : [], ...mocks.activeCompany }, activeCompanyId: 1 }) }));
vi.mock('@/services/employee-intake-api', () => ({ employeeIntakeApi: { updateException: mocks.update } }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ hasCapability: () => mocks.canReview }) }));

const employee = {
  id: 9, company_id: 1, first_name: 'New', last_name: 'Worker',
  intake_readiness: {
    profile_incomplete: true, missing_fields: ['ssn', 'hire_date', 'withholding_election'],
    exception: { reason: 'Employer details pending', authorized_by_name: 'Admin', created_by_name: 'Chels', follow_up_owner_id: 2, follow_up_owner_name: 'Chels', follow_up_due_on: '2026-10-16', payroll_eligible_from: null, payroll_setup_confirmed_at: null, payroll_setup_confirmed_by_name: null },
  },
} as Employee;

describe('Incomplete employee payroll review', () => {
  afterEach(cleanup);
  beforeEach(() => { vi.clearAllMocks(); mocks.activeCompany = null; mocks.canReview = true; mocks.update.mockResolvedValue({ data: employee }); });

  it('hides configuration review actions for a manager workspace operator while retaining the checklist', () => {
    mocks.activeCompany = { test_workspace: true, workspace_can_write: true, workspace_write_permissions: { manage_client_configuration: false } } as unknown as import('@/services/api').CompanyListItem;
    const view = render(<EmployeeIntakePanel companyId={1} employee={employee} onUpdated={vi.fn()} />);
    expect(screen.getByText('Social Security Number')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Confirm payroll setup' })).toBeNull();
    mocks.activeCompany = { ...mocks.activeCompany, workspace_write_permissions: { manage_client_configuration: true } };
    view.rerender(<EmployeeIntakePanel companyId={1} employee={employee} onUpdated={vi.fn()} />);
    expect(screen.getByRole('button', { name: 'Confirm payroll setup' })).toBeTruthy();
  });
  it('requires a participation date, reason and explicit default-withholding acknowledgement', async () => {
    const onUpdated = vi.fn();
    render(<EmployeeIntakePanel companyId={1} employee={employee} onUpdated={onUpdated} />);
    const confirm = screen.getByRole('button', { name: 'Confirm payroll setup' });
    expect(confirm.hasAttribute('disabled')).toBe(true);
    fireEvent.change(screen.getByLabelText('Earliest payroll participation date'), { target: { value: '2026-10-09' } });
    fireEvent.change(screen.getByLabelText('Payroll setup review reason'), { target: { value: 'Reviewed employer pay instruction' } });
    expect(confirm.hasAttribute('disabled')).toBe(true);
    fireEvent.click(screen.getByRole('checkbox'));
    fireEvent.click(confirm);
    await waitFor(() => expect(mocks.update).toHaveBeenCalledWith(1, 9, {
      follow_up_due_on: '2026-10-16', confirm_payroll_setup: true, payroll_eligible_from: '2026-10-09', reason: 'Reviewed employer pay instruction', acknowledge_default_withholding: true,
    }));
    expect(onUpdated).toHaveBeenCalledWith(employee);
  });

  it('keeps the checklist visible to operators without advertising manager actions', () => {
    mocks.canReview = false;
    render(<EmployeeIntakePanel companyId={1} employee={employee} onUpdated={vi.fn()} />);
    expect(screen.getByText('Social Security Number')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Confirm payroll setup' })).toBeNull();
  });

  it('discards a completed request after switching employee scope', async () => {
    let resolve!: (value: { data: Employee }) => void;
    mocks.update.mockReturnValue(new Promise((done) => { resolve = done; }));
    const onUpdated = vi.fn();
    const view = render(<EmployeeIntakePanel companyId={1} employee={employee} onUpdated={onUpdated} />);
    fireEvent.click(screen.getByRole('button', { name: 'Save follow-up date' }));
    view.rerender(<EmployeeIntakePanel companyId={2} employee={{ ...employee, id: 10 }} onUpdated={onUpdated} />);
    resolve({ data: employee });
    await waitFor(() => expect(mocks.update).toHaveBeenCalled());
    expect(onUpdated).not.toHaveBeenCalled();
  });
});
