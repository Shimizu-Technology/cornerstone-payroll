// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { useState } from 'react';
import { createMemoryRouter, RouterProvider, useNavigate } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { CompanyProvider, useCompany } from './CompanyContext';
import { UnsavedPayrollChangesGuard } from '@/components/routing/UnsavedPayrollChangesGuard';

const mocks = vi.hoisted(() => ({ switchCompany: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ isAuthenticated: true, isLoading: false, user: { id: 1, organization_id: 1 } }) }));
vi.mock('@/services/api', () => ({ companiesApi: {
  getActiveCompanyId: () => 1, clearActiveCompanyId: vi.fn(), switchCompany: mocks.switchCompany,
  list: async () => ({ companies: [{ id: 1, organization_id: 1, name: 'First' }, { id: 2, organization_id: 1, name: 'Second' }, { id: 3, organization_id: 2, name: 'Other firm' }], current_company_id: 1, can_manage_clients: true, can_switch_company: true }),
} }));
afterEach(() => { cleanup(); vi.restoreAllMocks(); });
function Worksheet() {
  const [hours, setHours] = useState('');
  return <><UnsavedPayrollChangesGuard dirty={hours !== ''} /><input aria-label="Hours" value={hours} onChange={e => setHours(e.target.value)} /></>;
}
function Host() {
  const { activeCompanyId, loading, switchCompany, switchOrganization } = useCompany();
  const navigate = useNavigate();
  if (loading) return <p>Loading</p>;
  return <><span data-testid="scope">{activeCompanyId}</span><Worksheet key={activeCompanyId} /><button onClick={() => { if (switchCompany(2) !== false) void navigate('/second'); }}>Change client</button><button onClick={() => { if (switchOrganization(2) !== false) void navigate('/other-firm'); }}>Change organization</button></>;
}
async function setup() {
  render(<RouterProvider router={createMemoryRouter([{ path: '*', element: <CompanyProvider><Host /></CompanyProvider> }], { initialEntries: ['/work'] })} />);
  await screen.findByLabelText('Hours');
  await waitFor(() => expect(screen.getByTestId('scope').textContent).toBe('1'));
  mocks.switchCompany.mockClear();
  fireEvent.change(screen.getByLabelText('Hours'), { target: { value: '17' } });
}
it.each(['Change client', 'Change organization'])('preserves scope, headers and hours when %s is cancelled', async (button) => {
  await setup();
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
  fireEvent.click(screen.getByText(button));
  expect(confirm).toHaveBeenCalledOnce();
  expect(screen.getByTestId('scope').textContent).toBe('1');
  expect((screen.getByLabelText('Hours') as HTMLInputElement).value).toBe('17');
  expect(mocks.switchCompany).not.toHaveBeenCalled();
});
it('changes scope only after Leave and does not ask a second navigation question', async () => {
  await setup();
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
  fireEvent.click(screen.getByText('Change client'));
  await waitFor(() => expect(screen.getByTestId('scope').textContent).toBe('2'));
  expect(mocks.switchCompany).toHaveBeenCalledExactlyOnceWith(2, 1);
  expect(confirm).toHaveBeenCalledOnce();
});
