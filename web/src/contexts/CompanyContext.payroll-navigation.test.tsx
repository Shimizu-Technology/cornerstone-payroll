// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { useState } from 'react';
import { createMemoryRouter, RouterProvider, useNavigate, useLocation, Routes, Route } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { CompanyProvider, useCompany } from './CompanyContext';
import { UnsavedPayrollChangesGuard } from '@/components/routing/UnsavedPayrollChangesGuard';
import { CompanySwitcher } from '@/components/layout/CompanySwitcher';
import { OrganizationSwitcher } from '@/components/layout/OrganizationSwitcher';
import { CompanyScopedRoute } from '@/components/routing/CompanyScopedRoute';

const mocks = vi.hoisted(() => {
  const defaultCompaniesResponse = {
    companies: [
      { id: 1, organization_id: 1, name: 'First', payroll_environment: 'production' },
      { id: 2, organization_id: 1, name: 'Second', payroll_environment: 'production' },
      { id: 3, organization_id: 2, name: 'Other firm', payroll_environment: 'production' },
    ],
    current_company_id: 1,
    can_manage_clients: true,
    can_switch_company: true,
  };
  return {
    defaultCompaniesResponse,
    getActiveCompanyId: vi.fn<() => number | null>(() => 1),
    switchCompany: vi.fn(),
    listCompanies: vi.fn(async () => defaultCompaniesResponse),
    companySwitchAnalytics: vi.fn(),
  };
});
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ isAuthenticated: true, isLoading: false, user: { id: 1, organization_id: 1, role: 'super_admin' } }) }));
vi.mock('@/lib/analytics', () => ({ analytics: { companySwitch: mocks.companySwitchAnalytics } }));
vi.mock('@/services/api', () => ({ companiesApi: {
  getActiveCompanyId: mocks.getActiveCompanyId, clearActiveCompanyId: vi.fn(), switchCompany: mocks.switchCompany,
  list: mocks.listCompanies,
} }));
afterEach(() => {
  cleanup();
  mocks.companySwitchAnalytics.mockClear();
  mocks.getActiveCompanyId.mockReset().mockReturnValue(1);
  mocks.listCompanies.mockReset().mockImplementation(async () => mocks.defaultCompaniesResponse);
  vi.restoreAllMocks();
});
function Worksheet() {
  const [hours, setHours] = useState('');
  return <><UnsavedPayrollChangesGuard dirty={hours !== ''} /><input aria-label="Hours" value={hours} onChange={e => setHours(e.target.value)} /></>;
}
function Host() {
  const { activeCompanyId, loading, switchCompany, switchOrganization } = useCompany();
  const navigate = useNavigate();
  const location = useLocation();
  if (loading) return <p>Loading</p>;
  return <><span data-testid="scope">{activeCompanyId}</span><span data-testid="path">{location.pathname}</span><CompanySwitcher /><OrganizationSwitcher /><Worksheet key={activeCompanyId} /><button onClick={() => { if (switchCompany(2) !== false) void navigate('/second'); }}>Change client</button><button onClick={() => { if (switchOrganization(2) !== false) void navigate('/other-firm'); }}>Change organization</button></>;
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

it.each(['client', 'organization'])('keeps the real %s control, route and mounted worksheet on Stay, then switches on Leave', async (scope) => {
  await setup();
  const input = screen.getByLabelText('Hours');
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
  const select = () => {
    if (scope === 'organization') {
      fireEvent.change(screen.getByLabelText('Organization'), { target: { value: '2' } });
    } else {
      fireEvent.click(screen.getByRole('button', { name: /First/ }));
      fireEvent.click(screen.getByRole('button', { name: 'Second' }));
    }
  };
  select();
  expect(screen.getByTestId('scope').textContent).toBe('1');
  expect(screen.getByTestId('path').textContent).toBe('/work');
  expect(screen.getByLabelText('Hours')).toBe(input);
  expect((input as HTMLInputElement).value).toBe('17');
  expect(mocks.switchCompany).not.toHaveBeenCalled();
  if (scope === 'organization') expect((screen.getByLabelText('Organization') as HTMLSelectElement).value).toBe('1');
  confirm.mockReturnValue(true);
  select();
  await waitFor(() => expect(screen.getByTestId('scope').textContent).toBe(scope === 'client' ? '2' : '3'));
  expect(mocks.switchCompany).toHaveBeenCalledExactlyOnceWith(scope === 'client' ? 2 : 3, scope === 'client' ? 1 : 2);
  expect(confirm).toHaveBeenCalledTimes(2);
});

function ScopedApplication() {
  const { activeCompanyId, activeOrganizationId, loading } = useCompany();
  if (loading) return <p>Loading</p>;
  // AppFeedback remounts the route subtree on company/organization changes.
  return <div key={`${activeOrganizationId}:${activeCompanyId}`}>
    <span data-testid="scope">{activeCompanyId}</span>
    <CompanySwitcher /><OrganizationSwitcher />
    <Routes>
      <Route path="companies/:companyId" element={<CompanyScopedRoute />}>
        <Route path="pay-runs/:id/work" element={<Worksheet />} />
        <Route path="pay-runs" element={<p>Pay runs</p>} />
      </Route>
      <Route path="app" element={<p>Dashboard</p>} />
    </Routes>
  </div>;
}

it.each(['client', 'organization'])('preserves edits on Stay and retains the accepted %s scope through the route remount', async (scope) => {
  const router = createMemoryRouter([{ path: '*', element: <CompanyProvider><ScopedApplication /></CompanyProvider> }], { initialEntries: ['/companies/1/pay-runs/4/work'] });
  render(<RouterProvider router={router} />);
  const input = await screen.findByLabelText('Hours');
  fireEvent.change(input, { target: { value: '17' } });
  mocks.switchCompany.mockClear();
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
  const select = () => {
    if (scope === 'organization') fireEvent.change(screen.getByLabelText('Organization'), { target: { value: '2' } });
    else {
      fireEvent.click(screen.getByRole('button', { name: /First/ }));
      fireEvent.click(screen.getByRole('button', { name: 'Second' }));
    }
  };
  select();
  expect(screen.getByLabelText('Hours')).toBe(input);
  expect((input as HTMLInputElement).value).toBe('17');
  expect(router.state.location.pathname).toBe('/companies/1/pay-runs/4/work');
  expect(mocks.switchCompany).not.toHaveBeenCalled();

  confirm.mockReturnValue(true);
  select();
  await screen.findByText(scope === 'client' ? 'Pay runs' : 'Dashboard');
  expect(screen.getByTestId('scope').textContent).toBe(scope === 'client' ? '2' : '3');
  expect(mocks.switchCompany).toHaveBeenCalledExactlyOnceWith(scope === 'client' ? 2 : 3, scope === 'client' ? 1 : 2);
  expect(confirm).toHaveBeenCalledTimes(2);
});

it('opens the client in the URL on Back and Forward after a switch, without getting stuck', async () => {
  const router = createMemoryRouter([{ path: '*', element: <CompanyProvider><ScopedApplication /></CompanyProvider> }], { initialEntries: ['/companies/1/pay-runs'] });
  render(<RouterProvider router={router} />);
  await screen.findByText('Pay runs');
  const expectOpen = async (companyId: string) => {
    await waitFor(() => expect(screen.getByTestId('scope').textContent).toBe(companyId));
    await screen.findByText('Pay runs');
    expect(router.state.location.pathname).toBe(`/companies/${companyId}/pay-runs`);
    expect(screen.queryByText('Opening client workspace')).toBeNull();
  };
  fireEvent.click(screen.getByRole('button', { name: /First/ }));
  fireEvent.click(screen.getByRole('button', { name: 'Second' }));
  await expectOpen('2');
  mocks.switchCompany.mockClear();
  await act(async () => { await router.navigate(-1); });
  await expectOpen('1');
  expect(mocks.switchCompany).toHaveBeenLastCalledWith(1, 1);
  await act(async () => { await router.navigate(1); });
  await expectOpen('2');
  expect(mocks.switchCompany).toHaveBeenLastCalledWith(2, 1);
  // Returning to the same entries again must behave the same way.
  await act(async () => { await router.navigate(-1); });
  await expectOpen('1');
  await act(async () => { await router.navigate(1); });
  await expectOpen('2');
});

it('resets analytics identity on every company switch path (picker, organization switch, and company-scoped navigation) and skips cancelled or no-op switches', async () => {
  // 1. Cancelled switch and no-op same-company switch do not reset analytics.
  await setup();
  mocks.companySwitchAnalytics.mockClear();
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
  fireEvent.click(screen.getByText('Change client'));
  fireEvent.click(screen.getByText('Change organization'));
  expect(mocks.companySwitchAnalytics).not.toHaveBeenCalled();

  // 2. Confirmed organization switch resets analytics via CompanyContext.
  confirm.mockReturnValue(true);
  fireEvent.click(screen.getByText('Change organization'));
  await waitFor(() => expect(screen.getByTestId('scope').textContent).toBe('3'));
  expect(mocks.companySwitchAnalytics).toHaveBeenCalledTimes(1);

  // 3. Re-selecting the same organization is a no-op and does not reset again.
  fireEvent.click(screen.getByText('Change organization'));
  expect(mocks.companySwitchAnalytics).toHaveBeenCalledTimes(1);

  cleanup();
  mocks.companySwitchAnalytics.mockClear();

  // 4. CompanyScopedRoute navigation (deep-link and Back/Forward) resets analytics on each company change.
  const router = createMemoryRouter(
    [{ path: '*', element: <CompanyProvider><ScopedApplication /></CompanyProvider> }],
    { initialEntries: ['/companies/2/pay-runs'] },
  );
  render(<RouterProvider router={router} />);
  await waitFor(() => expect(screen.getByTestId('scope').textContent).toBe('2'));
  await screen.findByText('Pay runs');
  expect(mocks.companySwitchAnalytics).toHaveBeenCalledTimes(1);

  mocks.companySwitchAnalytics.mockClear();
  await act(async () => { await router.navigate('/companies/1/pay-runs'); });
  await waitFor(() => expect(screen.getByTestId('scope').textContent).toBe('1'));
  expect(mocks.companySwitchAnalytics).toHaveBeenCalledTimes(1);

  mocks.companySwitchAnalytics.mockClear();
  await act(async () => { await router.navigate(-1); });
  await waitFor(() => expect(screen.getByTestId('scope').textContent).toBe('2'));
  expect(mocks.companySwitchAnalytics).toHaveBeenCalledTimes(1);
});

it('resets analytics identity when refreshCompanies falls back from an unavailable active company to the server default', async () => {
  function RefreshHost() {
    const { activeCompanyId, loading, refreshCompanies } = useCompany();
    if (loading) return <p>Loading</p>;
    return (
      <>
        <span data-testid="scope">{activeCompanyId}</span>
        <button onClick={() => void refreshCompanies()}>Refresh companies</button>
      </>
    );
  }

  // Initial load with no stored company does not trigger a company-switch reset.
  mocks.getActiveCompanyId.mockReturnValue(null);
  render(
    <RouterProvider
      router={createMemoryRouter([{ path: '*', element: <CompanyProvider><RefreshHost /></CompanyProvider> }], { initialEntries: ['/work'] })}
    />,
  );
  await waitFor(() => expect(screen.getByTestId('scope').textContent).toBe('1'));
  expect(mocks.companySwitchAnalytics).not.toHaveBeenCalled();

  // Refresh while stored company 1 is still available does not reset.
  mocks.getActiveCompanyId.mockReturnValue(1);
  fireEvent.click(screen.getByText('Refresh companies'));
  await waitFor(() => expect(mocks.listCompanies).toHaveBeenCalledTimes(2));
  expect(screen.getByTestId('scope').textContent).toBe('1');
  expect(mocks.companySwitchAnalytics).not.toHaveBeenCalled();

  // Refresh when stored company 1 is no longer available falls back to server default 2 and resets analytics.
  mocks.switchCompany.mockClear();
  mocks.listCompanies.mockResolvedValueOnce({
    companies: [
      { id: 2, organization_id: 1, name: 'Second', payroll_environment: 'production' },
      { id: 3, organization_id: 2, name: 'Other firm', payroll_environment: 'production' },
    ],
    current_company_id: 2,
    can_manage_clients: true,
    can_switch_company: true,
  });
  fireEvent.click(screen.getByText('Refresh companies'));
  await waitFor(() => expect(screen.getByTestId('scope').textContent).toBe('2'));
  expect(mocks.switchCompany).toHaveBeenCalledWith(2, 1);
  expect(mocks.companySwitchAnalytics).toHaveBeenCalledTimes(1);
});
