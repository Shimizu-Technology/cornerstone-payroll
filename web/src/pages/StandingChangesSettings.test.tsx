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
  { id: 1, name: 'Morgan Owner', status: 'active', variable_salary: true, hourly: false, wage_rates: [] },
  { id: 2, name: 'Jordan Worker', status: 'active', variable_salary: false, hourly: true, wage_rates: [{ id: 7, label: 'Maintenance', rate: '35.0' }] },
] };
beforeEach(() => { vi.clearAllMocks(); mocks.canEdit = true; mocks.get.mockResolvedValue(fixture); mocks.post.mockResolvedValue(fixture); });
afterEach(cleanup);
it('saves an owner default without amounts, then an extra-hours default with an explicitly selected job', async () => {
  render(<StandingChangesSettings />);
  await screen.findByLabelText('Employee');
  fireEvent.change(screen.getByLabelText('Employee'), { target: { value: '1' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save default' }));
  await waitFor(() => expect(mocks.post).toHaveBeenCalledWith('/admin/payroll_standing_changes', { standing_change: { kind: 'owner_pay', employee_id: 1, employee_wage_rate_id: null, position: 0, active: true, required: true } }));
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
  await screen.findByText('Needs attention in Settings: Saved job missing');
  expect((screen.getByRole('button', { name: 'Remove default for Jordan Worker' }) as HTMLButtonElement).disabled).toBe(true);
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

it('edits an existing default and renders the returned order', async () => {
  const existing = { id: 11, kind: 'owner_pay', employee_id: 1, employee_wage_rate_id: null, position: 0, active: true };
  mocks.get.mockResolvedValue({ ...fixture, defaults: [existing] });
  mocks.patch.mockResolvedValue({ ...fixture, defaults: [{ ...existing, position: 2 }] });
  render(<StandingChangesSettings />);
  fireEvent.click(await screen.findByRole('button', { name: 'Edit default for Morgan Owner' }));
  fireEvent.change(screen.getByLabelText('Order'), { target: { value: '2' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save default' }));
  await waitFor(() => expect(mocks.patch).toHaveBeenCalledWith('/admin/payroll_standing_changes/11', { standing_change: { ...existing, position: 2 } }));
  await screen.findByText(/Every-period changes saved/);
  fireEvent.click(screen.getByRole('button', { name: 'Edit default for Morgan Owner' }));
  expect((screen.getByLabelText('Order') as HTMLInputElement).value).toBe('2');
});
it('deactivates an existing default and removes its rendered row', async () => {
  const existing = { id: 11, kind: 'owner_pay', employee_id: 1, employee_wage_rate_id: null, position: 0, active: true };
  mocks.get.mockResolvedValue({ ...fixture, defaults: [existing] });
  mocks.patch.mockResolvedValue({ ...fixture, defaults: [{ ...existing, active: false }] });
  render(<StandingChangesSettings />);
  fireEvent.click(await screen.findByRole('button', { name: 'Remove default for Morgan Owner' }));
  await waitFor(() => expect(mocks.patch).toHaveBeenCalledWith('/admin/payroll_standing_changes/11', { standing_change: { ...existing, active: false } }));
  await screen.findByText('No every-period changes configured.');
  expect(screen.queryByRole('button', { name: 'Remove default for Morgan Owner' })).toBeNull();
});

it('saves field labels, help, requirement and none permissions, and suggests hours for an hourly employee', async () => {
  render(<StandingChangesSettings />);
  await screen.findByLabelText('Employee');
  fireEvent.change(screen.getByLabelText('Employee'), { target: { value: '2' } });
  expect((screen.getByLabelText('Change') as HTMLSelectElement).value).toBe('extra_hours');
  fireEvent.change(screen.getByLabelText('Saved job and rate'), { target: { value: '7' } });
  fireEvent.change(screen.getByLabelText('Entry label'), { target: { value: 'Manual work' } });
  fireEvent.change(screen.getByLabelText('Help text'), { target: { value: 'Hours for maintenance' } });
  fireEvent.click(screen.getByLabelText('Allow None this period'));
  fireEvent.click(screen.getByRole('button', { name: 'Save default' }));
  await waitFor(() => expect(mocks.post).toHaveBeenCalledWith('/admin/payroll_standing_changes', { standing_change: expect.objectContaining({ label: 'Manual work', help_text: 'Hours for maintenance', allow_none: false, kind: 'extra_hours' }) }));
});
it('saves the client missing-regular threshold separately from entry configuration', async () => {
  mocks.patch.mockResolvedValue(fixture);
  render(<StandingChangesSettings />);
  await screen.findByLabelText('Paid in at least');
  fireEvent.change(screen.getByLabelText('Paid in at least'), { target: { value: '2' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save missing-regular rule' }));
  await waitFor(() => expect(mocks.patch).toHaveBeenCalledWith('/admin/payroll_standing_changes/rule', { regular_pay_lookback: 4, regular_pay_threshold: 2 }));
});
it('keeps the threshold while the run count is retyped', async () => {
  mocks.patch.mockResolvedValue(fixture);
  render(<StandingChangesSettings />);
  const lookback = await screen.findByLabelText('Last regular runs');
  fireEvent.focus(lookback);
  fireEvent.change(lookback, { target: { value: '1' } });
  fireEvent.change(lookback, { target: { value: '12' } });
  fireEvent.blur(lookback);
  fireEvent.click(screen.getByRole('button', { name: 'Save missing-regular rule' }));
  await waitFor(() => expect(mocks.patch).toHaveBeenCalledWith('/admin/payroll_standing_changes/rule', { regular_pay_lookback: 12, regular_pay_threshold: 3 }));
});
it('refuses a fractional or too-high threshold instead of saving it', async () => {
  render(<StandingChangesSettings />);
  const threshold = await screen.findByLabelText('Paid in at least');
  fireEvent.change(threshold, { target: { value: '2.5' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save missing-regular rule' }));
  expect((await screen.findByRole('alert')).textContent).toContain('Use whole numbers');
  fireEvent.change(threshold, { target: { value: '5' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save missing-regular rule' }));
  expect(mocks.patch).not.toHaveBeenCalled();
});
it('saves a cleared order as 0 when the form is submitted with Enter', async () => {
  const existing = { id: 11, kind: 'owner_pay', employee_id: 1, employee_wage_rate_id: null, position: 5, active: true };
  mocks.get.mockResolvedValue({ ...fixture, defaults: [existing] });
  mocks.patch.mockResolvedValue({ ...fixture, defaults: [{ ...existing, position: 0 }] });
  render(<StandingChangesSettings />);
  fireEvent.click(await screen.findByRole('button', { name: 'Edit default for Morgan Owner' }));
  const order = screen.getByLabelText('Order');
  fireEvent.focus(order);
  fireEvent.change(order, { target: { value: '' } });
  fireEvent.submit(order.closest('form')!);
  await waitFor(() => expect(mocks.patch).toHaveBeenCalledWith('/admin/payroll_standing_changes/11', { standing_change: { ...existing, position: 0 } }));
});
