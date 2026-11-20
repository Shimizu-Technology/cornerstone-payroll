// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { EmployerFilingSettings } from './EmployerFilingSettings';
import { FilingSubmitterCard } from './FilingSubmitterCard';

const mocks = vi.hoisted(() => ({ get: vi.fn(), update: vi.fn(), submitterGet: vi.fn(), submitterUpdate: vi.fn() }));
vi.mock('@/services/api', () => ({
  companiesApi: { get: mocks.get, update: mocks.update },
  filingSubmitterApi: { get: mocks.submitterGet, update: mocks.submitterUpdate },
}));
const employer = { company: { kind_of_employer: 'N', employment_code: 'R', establishment_number: '',
  phone: '6715551234', email: 'contact@example.com', filing_contact_name: 'Contact',
  editable_fields: ['phone', 'email', 'kind_of_employer', 'employment_code', 'establishment_number', 'filing_contact_name'] } };
const submitter = { profile: { name: 'Practice', contact_email: 'filing@example.com' }, missing_fields: [], can_edit: true };
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
beforeEach(() => {
  vi.resetAllMocks();
  mocks.get.mockResolvedValue(employer);
  mocks.update.mockResolvedValue({});
  mocks.submitterGet.mockResolvedValue(submitter);
  mocks.submitterUpdate.mockResolvedValue({});
});
afterEach(cleanup);

it('blocks employer edits and duplicate submissions through update and checklist refresh, then recovers from refresh failure', async () => {
  const update = deferred<void>();
  const refresh = deferred<void>();
  mocks.update.mockReturnValue(update.promise);
  const onSaved = vi.fn(() => refresh.promise);
  render(<EmployerFilingSettings companyId={42} onSaved={onSaved} />);
  fireEvent.click(screen.getByRole('button', { name: 'Change' }));
  const phone = await screen.findByLabelText('Employer contact phone');
  const save = screen.getByRole('button', { name: 'Save filing settings' });
  const form = save.closest('form')!;
  fireEvent.submit(form);
  fireEvent.submit(form);
  expect(mocks.update).toHaveBeenCalledTimes(1);
  expect(phone.hasAttribute('disabled')).toBe(true);
  expect(screen.getByRole('button', { name: 'Saving…' }).hasAttribute('disabled')).toBe(true);
  await act(async () => update.resolve());
  expect(onSaved).toHaveBeenCalledOnce();
  expect(phone.hasAttribute('disabled')).toBe(true);
  await act(async () => refresh.reject(new Error('Checklist refresh failed')));
  expect(screen.getByRole('alert').textContent).toBe('Checklist refresh failed');
  expect(phone.hasAttribute('disabled')).toBe(false);
  fireEvent.change(phone, { target: { value: '6715554321' } });
  expect(screen.queryByRole('alert')).toBeNull();
});

it('clears employer lookup and save errors when retrying', async () => {
  mocks.get.mockRejectedValueOnce(new Error('offline'));
  render(<EmployerFilingSettings companyId={42} onSaved={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Change' }));
  await screen.findByRole('alert');
  fireEvent.click(screen.getByRole('button', { name: 'Change' }));
  await screen.findByLabelText('Employer contact phone');
  expect(screen.queryByRole('alert')).toBeNull();
  mocks.update.mockRejectedValueOnce(new Error('Save failed'));
  fireEvent.click(screen.getByRole('button', { name: 'Save filing settings' }));
  await screen.findByRole('alert');
  const pending = deferred<void>();
  mocks.update.mockReturnValueOnce(pending.promise);
  fireEvent.click(screen.getByRole('button', { name: 'Save filing settings' }));
  expect(screen.queryByRole('alert')).toBeNull();
  await act(async () => pending.resolve());
});

it('serializes submitter saves through update and reload and clears confirmation after an edit', async () => {
  const update = deferred<void>();
  const reload = deferred<typeof submitter>();
  mocks.submitterUpdate.mockReturnValueOnce(update.promise);
  mocks.submitterGet.mockResolvedValueOnce(submitter).mockReturnValueOnce(reload.promise);
  render(<FilingSubmitterCard />);
  await waitFor(() => expect(screen.getByRole('button', { name: 'View submitter profile' }).hasAttribute('disabled')).toBe(false));
  fireEvent.click(screen.getByRole('button', { name: 'View submitter profile' }));
  const name = screen.getByLabelText('Practice name');
  const form = screen.getByRole('button', { name: 'Save submitter profile' }).closest('form')!;
  fireEvent.submit(form);
  fireEvent.submit(form);
  expect(mocks.submitterUpdate).toHaveBeenCalledTimes(1);
  expect(name.hasAttribute('disabled')).toBe(true);
  await act(async () => update.resolve());
  expect(name.hasAttribute('disabled')).toBe(true);
  expect(screen.getByRole('button', { name: 'Saving…' }).hasAttribute('disabled')).toBe(true);
  await act(async () => reload.resolve(submitter));
  expect(screen.getByRole('status').textContent).toBe('Submitter profile saved.');
  expect(name.hasAttribute('disabled')).toBe(false);
  fireEvent.change(name, { target: { value: 'Updated Practice' } });
  expect(screen.queryByText('Submitter profile saved.')).toBeNull();
});

it('releases submitter pending state after failure and clears obsolete errors on edits', async () => {
  mocks.submitterUpdate.mockRejectedValueOnce(new Error('Save failed'));
  render(<FilingSubmitterCard />);
  await waitFor(() => expect(screen.getByRole('button', { name: 'View submitter profile' }).hasAttribute('disabled')).toBe(false));
  fireEvent.click(screen.getByRole('button', { name: 'View submitter profile' }));
  fireEvent.click(screen.getByRole('button', { name: 'Save submitter profile' }));
  await screen.findByRole('alert');
  expect(screen.getByLabelText('Practice name').hasAttribute('disabled')).toBe(false);
  fireEvent.change(screen.getByLabelText('Practice name'), { target: { value: 'Updated Practice' } });
  expect(screen.queryByRole('alert')).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Save submitter profile' }));
  await screen.findByText('Submitter profile saved.');
});
