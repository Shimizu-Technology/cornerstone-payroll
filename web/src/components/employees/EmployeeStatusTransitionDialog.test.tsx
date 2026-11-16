// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import type { Employee } from '@/types';
import { EmployeeStatusTransitionDialog } from './EmployeeStatusTransitionDialog';
const deactivate = vi.hoisted(() => vi.fn());
const get = vi.hoisted(() => vi.fn().mockResolvedValue({ data: { open_pay_runs: [] } }));
const reactivate = vi.hoisted(() => vi.fn());
vi.mock('@/services/api', () => ({ employeesApi: { get, reactivate, deactivate } }));
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
  await waitFor(() => expect((screen.getByRole('button', { name: 'Mark inactive' }) as HTMLButtonElement).disabled).toBe(false));
  fireEvent.click(screen.getByRole('button', { name: 'Mark inactive' }));
  await waitFor(() => expect(completed).toHaveBeenCalledWith(inactive));
  expect(deactivate).toHaveBeenCalledWith(7, { effective_date: '2024-03-15', reason_category: undefined, internal_notes: undefined });
});

it.each(['deactivate', 'terminate'] as const)('lists a later approved run and calculated run for %s', async mode => {
  get.mockResolvedValue({ data: { open_pay_runs: [
    { id: 42, status: 'approved', start_date: '2026-11-16', end_date: '2026-11-30' },
    { id: 43, status: 'calculated', start_date: '2026-12-01', end_date: '2026-12-15' },
  ] } });
  render(<MemoryRouter><EmployeeStatusTransitionDialog employee={{ id: 7, company_id: 1, first_name: 'Dana', employment_type: 'hourly', status: 'active' } as Employee} mode={mode} open onOpenChange={vi.fn()} onCompleted={vi.fn()} /></MemoryRouter>);
  fireEvent.change(screen.getByLabelText(/effective date/), { target: { value: '2026-11-15' } });
  await screen.findByText('Unapprove pay run #42 first');
  expect(get).toHaveBeenLastCalledWith(7, 1, '2026-11-15');
  expect(screen.getByRole('link', { name: /Pay run #43/ }).getAttribute('href')).toBe('/companies/1/pay-runs/43/work');
  expect((screen.getByRole('button', { name: mode === 'deactivate' ? 'Mark inactive' : 'Terminate employee' }) as HTMLButtonElement).disabled).toBe(true);
});
