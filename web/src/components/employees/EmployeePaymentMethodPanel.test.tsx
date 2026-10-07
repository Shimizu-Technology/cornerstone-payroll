// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import { EmployeePaymentMethodPanel } from './EmployeePaymentMethodPanel';
import type { Employee } from '@/types';
const mocks = vi.hoisted(() => ({ update: vi.fn(), canChange: true }));
vi.mock('@/services/api', () => ({ employeesApi: { update: mocks.update } }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ hasCapability: () => mocks.canChange }) }));
const employee = { id: 19, company_id: 6, first_name: 'Avery', last_name: 'Example', payment_delivery_method: 'paper_check' } as Employee;
afterEach(cleanup);
describe('employee future payment default', () => {
  beforeEach(() => { vi.clearAllMocks(); mocks.canChange = true; mocks.update.mockResolvedValue({ data: employee }); });
  it('submits only the chosen default without touching the rest of the employee setup', async () => {
    const user = userEvent.setup();
    const refresh = vi.fn().mockResolvedValue(undefined);
    render(<FeedbackProvider><EmployeePaymentMethodPanel employee={employee} onEmployeeReload={refresh} /></FeedbackProvider>);
    await user.click(screen.getByRole('button', { name: 'Change future payment method' }));
    await user.selectOptions(screen.getByLabelText('Future payroll payment method'), 'direct_deposit');
    await user.click(screen.getByRole('button', { name: 'Save future default' }));
    await waitFor(() => expect(mocks.update).toHaveBeenCalledWith(19, { payment_delivery_method: 'direct_deposit' }, 6));
    expect(refresh).toHaveBeenCalledOnce();
    expect(screen.getByText(/future payroll default saved as Direct deposit/)).toBeTruthy();
  });
  it('reports the saved outcome even when reload fails', async () => {
    const user = userEvent.setup();
    render(<FeedbackProvider><EmployeePaymentMethodPanel employee={employee} onEmployeeReload={vi.fn().mockRejectedValue(new Error('Offline'))} /></FeedbackProvider>);
    await user.click(screen.getByRole('button', { name: 'Change future payment method' }));
    await user.click(screen.getByRole('button', { name: 'Save future default' }));
    expect(await screen.findByText(/future payment method was saved, but the employee screen could not refresh/)).toBeTruthy();
    expect(mocks.update).toHaveBeenCalledOnce();
  });
  it('keeps client viewers out of staff payment settings', () => {
    mocks.canChange = false;
    render(<EmployeePaymentMethodPanel employee={employee} onEmployeeReload={vi.fn()} />);
    expect(screen.queryByRole('button', { name: 'Change future payment method' })).toBeNull();
    expect(screen.getByText(/Ask the payroll team/)).toBeTruthy();
  });
});
