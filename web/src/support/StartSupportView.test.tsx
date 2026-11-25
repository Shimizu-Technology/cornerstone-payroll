// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactNode } from 'react';
import { afterEach, expect, it, vi } from 'vitest';
import { StartSupportView } from './StartSupportView';

const api = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock('@/services/api', () => ({ default: api, getApiBaseUrl: () => 'http://api.test' }));
vi.mock('@/lib/useStepUpRequest', () => ({ useStepUpRequest: () => vi.fn() }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 3, activeCompany: { id: 3, name: 'Example Bakery' } }) }));
vi.mock('@/components/layout/Header', () => ({
  Header: ({ title, description }: { title: string; description?: ReactNode }) => <header><h1>{title}</h1><p>{description}</p></header>,
}));

afterEach(() => { cleanup(); vi.resetAllMocks(); });

const people = { clients: [{ id: 'c1', name: 'Sample Manager' }], employees: [], employee_site_enabled: false };

it('shows a load failure under the person field and retries it', async () => {
  const user = userEvent.setup();
  api.get.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(people);
  render(<StartSupportView />);

  const alert = await screen.findByRole('alert');
  expect(alert.textContent).toContain('Could not load people for this company.');
  const select = screen.getByRole('combobox', { name: 'Person' });
  expect(select.getAttribute('aria-describedby')).toBe('support-target-error');
  expect(screen.queryByRole('option', { name: /Could not load/ })).toBeNull();

  await user.click(screen.getByRole('button', { name: 'Try again' }));
  expect(await screen.findByRole('option', { name: 'Sample Manager' })).toBeTruthy();
  expect(screen.queryByRole('alert')).toBeNull();
  expect(api.get).toHaveBeenCalledTimes(2);
});

it('says what is missing while the start button is disabled', async () => {
  const user = userEvent.setup();
  api.get.mockResolvedValue(people);
  render(<StartSupportView />);
  await screen.findByRole('option', { name: 'Sample Manager' });

  const start = screen.getByRole('button', { name: 'Start view-only session' }) as HTMLButtonElement;
  expect(start.disabled).toBe(true);
  expect(screen.getByText('Choose a person and enter a reason.')).toBeTruthy();
  expect(start.getAttribute('aria-describedby')).toBe('support-start-hint');

  await user.selectOptions(screen.getByRole('combobox', { name: 'Person' }), 'c1');
  expect(screen.getByText('Enter a reason.')).toBeTruthy();

  await user.type(screen.getByRole('textbox', { name: 'Reason' }), 'Checking a pay stub question');
  expect(start.disabled).toBe(false);
  expect(screen.queryByText(/Enter a reason|Choose a person/)).toBeNull();
  expect(start.getAttribute('aria-describedby')).toBeNull();
});
