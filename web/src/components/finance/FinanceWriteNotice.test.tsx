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
  ],
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
    const useClient = screen.getByRole('button', { name: 'Use selected live client' }) as HTMLButtonElement;
    expect(useClient.disabled).toBe(true);
    expect(context.switchCompany).not.toHaveBeenCalled();
    fireEvent.change(screen.getByRole('combobox', { name: 'Live payroll client' }), { target: { value: '1' } });
    expect(context.switchCompany).not.toHaveBeenCalled();
    fireEvent.click(useClient);
    expect(context.switchCompany).toHaveBeenCalledExactlyOnceWith(1);
  });
});
