// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import StandingChangesSettings from './StandingChangesSettings';
const mocks = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn(), patch: vi.fn(), canEdit: true }));
vi.mock('@/services/api', () => ({ default: { get: mocks.get, post: mocks.post, patch: mocks.patch } }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 6, activeCompany: { id: 6, name: 'Example Client' } }) }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: () => mocks.canEdit }));
vi.mock('@/lib/company-write-access', () => ({ canWriteCompany: () => mocks.canEdit }));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title }: { title: string }) => <h1>{title}</h1> }));
const fixture = { defaults: [], employees: [
  { id: 1, name: 'Monique Owner', status: 'active', variable_salary: true, hourly: false, wage_rates: [] },
  { id: 2, name: 'Addison Worker', status: 'active', variable_salary: false, hourly: true, wage_rates: [{ id: 7, label: 'Maintenance', rate: '35.0' }] },
] };
beforeEach(() => { vi.clearAllMocks(); mocks.canEdit = true; mocks.get.mockResolvedValue(fixture); mocks.post.mockResolvedValue(fixture); });
afterEach(cleanup);
it('saves an owner default without amounts, then an extra-hours default with an explicitly selected job', async () => {
  render(<StandingChangesSettings />);
  await screen.findByLabelText('Employee');
  fireEvent.change(screen.getByLabelText('Employee'), { target: { value: '1' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save default' }));
  await waitFor(() => expect(mocks.post).toHaveBeenCalledWith('/admin/payroll_standing_changes', { standing_change: { kind: 'owner_pay', employee_id: 1, employee_wage_rate_id: null, position: 0, active: true } }));
  await screen.findByRole('status');
  fireEvent.change(screen.getByLabelText('Change'), { target: { value: 'extra_hours' } });
  fireEvent.change(screen.getByLabelText('Employee'), { target: { value: '2' } });
  fireEvent.change(screen.getByLabelText('Saved job and rate'), { target: { value: '7' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save default' }));
  await waitFor(() => expect(mocks.post).toHaveBeenLastCalledWith('/admin/payroll_standing_changes', { standing_change: expect.objectContaining({ employee_id: 2, employee_wage_rate_id: 7, kind: 'extra_hours' }) }));
});
it('shows unavailable defaults and prevents saves without configuration capability', async () => {
  mocks.get.mockResolvedValue({ ...fixture, defaults: [{ id: 9, kind: 'extra_hours', employee_id: 2, employee_wage_rate_id: null, position: 0, active: true, availability_error: 'Saved job missing' }] });
  mocks.canEdit = false;
  render(<StandingChangesSettings />);
  await screen.findByText('Saved job missing');
  expect((screen.getByRole('button', { name: 'Remove default for Addison Worker' }) as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByLabelText('Employee').closest('fieldset') as HTMLFieldSetElement).disabled).toBe(true);
  expect(mocks.patch).not.toHaveBeenCalled();
});
it('retains the employee and job draft after a refused save and displays the error', async () => {
  mocks.post.mockRejectedValue(new Error('Saved job is inactive'));
  render(<StandingChangesSettings />);
  await screen.findByLabelText('Employee');
  fireEvent.change(screen.getByLabelText('Employee'), { target: { value: '1' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save default' }));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Saved job is inactive');
  expect((screen.getByLabelText('Employee') as HTMLSelectElement).value).toBe('1');
});
it('recovers a failed defaults request without an indefinite loading state', async () => {
  mocks.get.mockRejectedValueOnce(new Error('Connection interrupted')).mockResolvedValue(fixture);
  render(<StandingChangesSettings />);
  await screen.findByText('Connection interrupted');
  fireEvent.click(screen.getByRole('button', { name: 'Try loading defaults again' }));
  await screen.findByLabelText('Employee');
  expect(mocks.get).toHaveBeenCalledTimes(2);
});
