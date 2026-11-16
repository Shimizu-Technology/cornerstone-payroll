// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import type { Employee } from '@/types';
import { EmployeeStatusTransitionDialog } from './EmployeeStatusTransitionDialog';
const deactivate = vi.hoisted(() => vi.fn());
const reactivate = vi.hoisted(() => vi.fn());
vi.mock('@/services/api', () => ({ employeesApi: { reactivate, deactivate } }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
function view(status: Employee['status'], termination_date: string | null = null) {
  const onCompleted = vi.fn();
  render(<EmployeeStatusTransitionDialog employee={{ id: 7, first_name: 'Avery', employment_type: 'hourly', status, termination_date } as Employee} mode="reactivate" open onOpenChange={vi.fn()} onCompleted={onCompleted} />);
  return onCompleted;
}
it('explains an inactive return without a termination date and submits a reactivation', async () => {
  const active = { id: 7, status: 'active' };
  reactivate.mockResolvedValue({ data: active });
  const completed = view('inactive');
  expect(screen.getByText(/The inactive period stays/)).toBeTruthy();
  expect(screen.getByText('Use the first day they are working again. It does not alter prior payroll.')).toBeTruthy();
  expect(screen.queryByText(/must be after the recorded termination/)).toBeNull();
  fireEvent.change(screen.getByLabelText(/Reactivation effective date/), { target: { value: '2024-04-01' } });
  fireEvent.click(screen.getByRole('button', { name: 'Reactivate employee' }));
  await waitFor(() => expect(completed).toHaveBeenCalledWith(active));
  expect(reactivate).toHaveBeenCalledWith(7, { effective_date: '2024-04-01', internal_notes: undefined });
});
it('keeps the terminated history explanation and date guard', () => {
  view('terminated', '2024-03-15');
  expect(screen.getByText(/The prior termination stays/)).toBeTruthy();
  expect(screen.getByText(/must be after the recorded termination on 2024-03-15/)).toBeTruthy();
  fireEvent.change(screen.getByLabelText(/Reactivation effective date/), { target: { value: '2024-03-15' } });
  expect((screen.getByRole('button', { name: 'Reactivate employee' }) as HTMLButtonElement).disabled).toBe(true);
});

it('marks an active worker inactive with an effective date', async () => {
  const inactive = { id: 7, status: 'inactive' };
  deactivate.mockResolvedValue({ data: inactive });
  const completed = vi.fn();
  render(<EmployeeStatusTransitionDialog employee={{ id: 7, first_name: 'Avery', employment_type: 'hourly', status: 'active' } as Employee} mode="deactivate" open onOpenChange={vi.fn()} onCompleted={completed} />);
  expect(screen.getByText('Inactive: not paid until reactivated. Use Terminate when employment has ended.')).toBeTruthy();
  fireEvent.change(screen.getByLabelText(/Inactive effective date/), { target: { value: '2024-03-15' } });
  fireEvent.click(screen.getByRole('button', { name: 'Mark inactive' }));
  await waitFor(() => expect(completed).toHaveBeenCalledWith(inactive));
  expect(deactivate).toHaveBeenCalledWith(7, { effective_date: '2024-03-15', reason_category: undefined, internal_notes: undefined });
});
