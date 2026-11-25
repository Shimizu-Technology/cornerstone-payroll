// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FinanceWriteNotice } from './FinanceWriteNotice';

const context = vi.hoisted(() => ({
  activeCompany: { id: 2, organization_id: 1, payroll_environment: 'migration_rehearsal', test_workspace: true },
  companies: [
    { id: 1, organization_id: 1, name: 'Live QA client', active: true, payroll_environment: 'live', workspace_can_write: true },
    { id: 2, organization_id: 1, name: 'QA sandbox', active: true, payroll_environment: 'migration_rehearsal', workspace_can_write: true },
    { id: 3, organization_id: 2, name: 'Other firm client', active: true, payroll_environment: 'live', workspace_can_write: true },
    { id: 4, organization_id: 1, name: 'Unavailable client', active: true, payroll_environment: 'live', workspace_can_write: false },
    { id: 5, organization_id: 1, name: 'Harbor Finch Kitchen', active: true, payroll_environment: 'live', test_workspace: false, workspace_can_write: true },
  ],
  billingCompanyIds: [ 1, 3, 4 ],
  switchCompany: vi.fn(),
}));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => context }));

describe('FinanceWriteNotice context recovery', () => {
  afterEach(cleanup);
  beforeEach(() => vi.clearAllMocks());

  it('explains the live-book boundary before an explicit authorized context choice', () => {
    render(<FinanceWriteNotice />);
    expect(screen.getByRole('status').textContent).toContain('finance book contains live records');
    expect(screen.queryByRole('option', { name: 'Other firm client' })).toBeNull();
    expect(screen.queryByRole('option', { name: 'Unavailable client' })).toBeNull();
    expect(screen.queryByRole('option', { name: 'QA sandbox' })).toBeNull();
    expect(screen.queryByRole('option', { name: 'Harbor Finch Kitchen' })).toBeNull();
    const useClient = screen.getByRole('button', { name: 'Use selected live client' }) as HTMLButtonElement;
    expect(useClient.disabled).toBe(true);
    expect(context.switchCompany).not.toHaveBeenCalled();
    fireEvent.change(screen.getByRole('combobox', { name: 'Live payroll client' }), { target: { value: '1' } });
    expect(context.switchCompany).not.toHaveBeenCalled();
    fireEvent.click(useClient);
    expect(context.switchCompany).toHaveBeenCalledExactlyOnceWith(1);
  });
});

describe('FinanceWriteNotice for a client finance cannot bill', () => {
  const demo = { id: 5, organization_id: 1, name: 'Harbor Finch Kitchen', active: true, payroll_environment: 'live', test_workspace: false, workspace_can_write: true };
  let saved: typeof context;
  beforeEach(() => {
    vi.clearAllMocks();
    saved = { ...context };
    Object.assign(context, { activeCompany: demo, companies: [ ...saved.companies, demo ], billingCompanyIds: [ 1, 3, 4 ] });
  });
  afterEach(() => { cleanup(); Object.assign(context, saved); });

  it('shows the blocked notice with neutral wording when the active company is not billable', () => {
    render(<FinanceWriteNotice />);
    const status = screen.getByRole('status').textContent ?? '';
    expect(status).toContain("Finance changes aren't available for this client.");
    expect(status).not.toMatch(/test workspace|live|demo/i);
    expect(screen.getByRole('option', { name: 'Live QA client' })).toBeTruthy();
    expect(screen.queryByRole('option', { name: 'Harbor Finch Kitchen' })).toBeNull();
    fireEvent.change(screen.getByRole('combobox', { name: 'Payroll client' }), { target: { value: '1' } });
    fireEvent.click(screen.getByRole('button', { name: 'Use selected client' }));
    expect(context.switchCompany).toHaveBeenCalledExactlyOnceWith(1);
  });

  it('shows the notice when the billable list is missing', () => {
    Object.assign(context, { billingCompanyIds: null });
    render(<FinanceWriteNotice />);
    expect(screen.getByRole('status').textContent).toContain("Finance changes aren't available for this client.");
  });

  it('stays hidden for a billable client', () => {
    Object.assign(context, { activeCompany: saved.companies[0] });
    render(<FinanceWriteNotice />);
    expect(screen.queryByRole('status')).toBeNull();
  });
});
