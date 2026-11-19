// @vitest-environment jsdom
import { expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { EmployerFilingSettings } from './EmployerFilingSettings';
import { companiesApi } from '@/services/api';
vi.mock('@/services/api', () => ({ companiesApi: { get: vi.fn(), update: vi.fn() } }));
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
