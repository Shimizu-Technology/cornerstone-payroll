// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { EmployerFilingSettings } from './EmployerFilingSettings';
import { companiesApi } from '@/services/api';
vi.mock('@/services/api', () => ({ companiesApi: { get: vi.fn(), update: vi.fn() } }));
afterEach(cleanup);
it('respects the server editable-field list when staff can update contacts only', async () => {
  vi.mocked(companiesApi.get).mockResolvedValue({ company: {
    kind_of_employer: 'N', employment_code: 'R', establishment_number: '', phone: '6715551234',
    email: 'contact@example.com', filing_contact_name: 'Contact', editable_fields: ['phone'],
  } } as unknown as Awaited<ReturnType<typeof companiesApi.get>>);
  vi.mocked(companiesApi.update).mockResolvedValue({} as Awaited<ReturnType<typeof companiesApi.update>>);
  render(<EmployerFilingSettings companyId={42} onSaved={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Change' }));
  const select = await screen.findByLabelText('Kind of employer');
  expect((select as HTMLSelectElement).disabled).toBe(true);
  expect((screen.getByLabelText('Establishment number (optional)') as HTMLInputElement).disabled).toBe(true);
  fireEvent.change(screen.getByLabelText('Employer contact phone'), { target: { value: '6715554321' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save filing settings' }));
  await waitFor(() => expect(companiesApi.update).toHaveBeenCalledWith(42, { phone: '6715554321' }, 42));
});

it('loads once on a double click, so a late lookup cannot replace an edit', async () => {
  vi.mocked(companiesApi.get).mockReset();
  type Lookup = Awaited<ReturnType<typeof companiesApi.get>>;
  let resolveFirst: (value: Lookup) => void = () => {};
  const company = {
    kind_of_employer: 'N', employment_code: 'R', establishment_number: '', phone: '6715551234',
    email: 'contact@example.com', filing_contact_name: 'Contact', editable_fields: ['phone'],
  };
  vi.mocked(companiesApi.get)
    .mockImplementationOnce(() => new Promise<Lookup>((resolve) => { resolveFirst = resolve; }))
    .mockResolvedValue({ company } as unknown as Lookup);
  render(<EmployerFilingSettings companyId={42} onSaved={vi.fn()} />);
  const change = screen.getByRole('button', { name: 'Change' });
  fireEvent.click(change);
  fireEvent.click(screen.getByRole('button', { name: 'Loading…' }));
  expect(companiesApi.get).toHaveBeenCalledTimes(1);
  resolveFirst({ company } as unknown as Lookup);
  const phone = await screen.findByLabelText('Employer contact phone');
  fireEvent.change(phone, { target: { value: '6715554321' } });
  expect(screen.getByRole('button', { name: 'Change' })).toHaveProperty('disabled', true);
  fireEvent.click(screen.getByRole('button', { name: 'Change' }));
  expect(companiesApi.get).toHaveBeenCalledTimes(1);
  expect((screen.getByLabelText('Employer contact phone') as HTMLInputElement).value).toBe('6715554321');
});
