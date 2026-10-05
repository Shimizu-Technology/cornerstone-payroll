// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AireAccountConnection } from './AireAccountConnection';

const mocks = vi.hoisted(() => ({
  allowed: true, companyId: 7, switchCompany: vi.fn(), list: vi.fn(), read: vi.fn(), create: vi.fn(), disconnect: vi.fn(),
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ hasCapability: (name: string) => mocks.allowed && name === 'manage_own_aire_account_link' }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({
  activeCompanyId: mocks.companyId, activeCompany: { id: mocks.companyId, name: 'Assigned client' },
  companies: [{ id: 7 }, { id: 8 }], loading: false, switchCompany: mocks.switchCompany,
}) }));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title }: { title: string }) => <header>{title}</header> }));
vi.mock('@/services/api', () => ({ timeTrackingSourcesApi: {
  list: mocks.list, getAireAccountLink: mocks.read, createAireAccountLink: mocks.create, disconnectAireAccountLink: mocks.disconnect,
} }));
const source = { id: 4, company_id: 7, name: 'Assigned AIRE', source_type: 'aire_services', active: true };
const linked = { connected: true, aire_user_name: 'AIRE operator', aire_user_email: 'operator@example.test' };
const url = 'https://aire.example.test/admin/payroll-link?token=synthetic';
function view(path = '/app/aire-account-connection?source_id=4', navigate = vi.fn()) {
  return render(<MemoryRouter initialEntries={[path]}><AireAccountConnection navigateToAuthorization={navigate} /></MemoryRouter>);
}
beforeEach(() => {
  vi.clearAllMocks(); sessionStorage.clear(); mocks.allowed = true; mocks.companyId = 7;
  mocks.list.mockResolvedValue({ time_tracking_sources: [source] });
  mocks.read.mockResolvedValue({ account_link: { connected: false } });
  mocks.create.mockResolvedValue({ authorization_url: url, expires_at: '2026-10-04T00:10:00Z' });
  mocks.disconnect.mockResolvedValue({ account_link: { connected: false } });
});
afterEach(cleanup);

describe('Personal AIRE connection', () => {
  it('connects an assigned accountant without configuration controls and preserves the work context', async () => {
    const user = userEvent.setup(); const navigate = vi.fn();
    view('/app/aire-account-connection?source_id=4&return_to=%2Fcompanies%2F7%2Fpay-runs%2F67%2Fwork', navigate);
    await user.click(await screen.findByRole('button', { name: 'Connect my time tracking account' }));
    expect(mocks.create).toHaveBeenCalledWith(4);
    expect(navigate).toHaveBeenCalledWith(url);
    expect(JSON.parse(sessionStorage.getItem('aire-own-link-return:4')!)).toEqual({ companyId: 7, returnTo: '/companies/7/pay-runs/67/work' });
    expect(screen.getByRole('link', { name: 'Return to payroll' }).getAttribute('href')).toBe('/companies/7/pay-runs/67/work');
    expect(screen.queryByLabelText(/secret|backend|delegation token|calendar/i)).toBeNull();
    expect(screen.getByText(/does not change your Payroll role/)).toBeTruthy();
    expect(screen.getByText(/your own account that has payroll access/)).toBeTruthy();
    expect(screen.queryByText(/your administrator account/)).toBeNull();
  });
  it('does not read data or show commands without the own-link capability', () => {
    mocks.allowed = false; view();
    expect(screen.getByRole('alert').textContent).toMatch(/cannot manage/);
    expect(mocks.list).not.toHaveBeenCalled();
    expect(mocks.read).not.toHaveBeenCalled();
  });
  it('offers only active AIRE sources for the selected company', async () => {
    mocks.list.mockResolvedValue({ time_tracking_sources: [source,
      { ...source, id: 5, active: false, name: 'Inactive AIRE' },
      { ...source, id: 6, source_type: 'custom', name: 'Custom source' },
      { ...source, id: 7, company_id: 8, name: 'Other client AIRE' }] });
    view(); await screen.findByRole('button', { name: 'Connect my time tracking account' });
    expect(screen.getByRole('option', { name: 'Assigned AIRE' })).toBeTruthy();
    expect(screen.queryByRole('option', { name: 'Inactive AIRE' })).toBeNull();
    expect(screen.queryByRole('option', { name: 'Custom source' })).toBeNull();
    expect(screen.queryByRole('option', { name: 'Other client AIRE' })).toBeNull();
    expect(mocks.read).toHaveBeenCalledWith(4);
  });
  it('does not silently substitute a stale or foreign requested source', async () => {
    view('/app/aire-account-connection?source_id=900');
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('unavailable for this company'));
    expect(mocks.read).not.toHaveBeenCalled();
    expect(screen.queryByRole('button', { name: 'Connect my time tracking account' })).toBeNull();
    await userEvent.setup().selectOptions(screen.getByLabelText('Active time tracking source'), '4');
    await screen.findByRole('button', { name: 'Connect my time tracking account' });
    expect(mocks.read).toHaveBeenCalledWith(4);
  });
  it('gives an explicit administrator next step when the company has no active source', async () => {
    mocks.list.mockResolvedValue({ time_tracking_sources: [] }); view('/app/aire-account-connection');
    expect(await screen.findByText(/no active time tracking source/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Connect my time tracking account' })).toBeNull();
  });
  it('leaves connection state unknown during an outage and recovers through refresh', async () => {
    mocks.read.mockRejectedValueOnce(new Error('AIRE is unavailable')).mockResolvedValue({ account_link: linked });
    view(); expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'AIRE is unavailable');
    expect(screen.queryByText('Not connected')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Connect my time tracking account' })).toBeNull();
    await userEvent.setup().click(screen.getByRole('button', { name: 'Refresh connection status' }));
    expect(await screen.findByText('Connected as AIRE operator')).toBeTruthy();
  });
  it('confirms the own disconnection and permits reconnection without touching configuration', async () => {
    mocks.read.mockResolvedValue({ account_link: linked }); view(); const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Disconnect my account' }));
    expect(mocks.disconnect).not.toHaveBeenCalled();
    await user.click(screen.getByRole('button', { name: 'Keep connected' }));
    expect(mocks.disconnect).not.toHaveBeenCalled();
    await user.click(screen.getByRole('button', { name: 'Disconnect my account' }));
    await user.click(screen.getByRole('button', { name: 'Confirm disconnection' }));
    expect(mocks.disconnect).toHaveBeenCalledWith(4);
    expect(await screen.findByRole('button', { name: 'Connect my time tracking account' })).toBeTruthy();
  });
  it('does not claim OAuth success based on a query parameter', async () => {
    view('/app/aire-account-connection?source_id=4&aire_link=connected');
    expect(await screen.findByText(/connection is not active/)).toBeTruthy();
    expect(screen.queryByText('Connected')).toBeNull();
  });
  it('shows cancellation alongside the freshly checked connection', async () => {
    view('/app/aire-account-connection?source_id=4&aire_link=cancelled');
    expect(await screen.findByText(/connection was cancelled/)).toBeTruthy();
    expect(screen.getByText('Not connected')).toBeTruthy();
  });
  it.each(['javascript:alert(1)', 'https://user:password@aire.example.test/admin/payroll-link?token=x',
    'https://aire.example.test/other?token=x', 'http://aire.example.test/admin/payroll-link?token=x',
    'https://aire.example.test/admin/payroll-link'])('blocks unsafe authorization response %s', async value => {
    mocks.create.mockResolvedValue({ authorization_url: value }); const navigate = vi.fn(); view(undefined, navigate);
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Connect my time tracking account' }));
    await screen.findByRole('alert'); expect(navigate).not.toHaveBeenCalled();
    expect(screen.queryByRole('button', { name: 'Connect my time tracking account' })).toBeNull();
  });
  it('permits a compatible producer only at its approved authorization origin', async () => {
    mocks.list.mockResolvedValue({ time_tracking_sources: [{ ...source, source_type: 'custom',
      supported_operations: ['account_linking'], authorization_origin: 'https://neutral.example.test' }] });
    const authorized = 'https://neutral.example.test/consent?token=synthetic';
    mocks.create.mockResolvedValue({ authorization_url: authorized });
    const navigate = vi.fn(); view(undefined, navigate);
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Connect my time tracking account' }));
    expect(navigate).toHaveBeenCalledWith(authorized);
  });
  it.each([
    ['https://neutral.example.test', 'https://foreign.example.test/consent?token=synthetic'],
    ['invalid stored origin', 'https://neutral.example.test/consent?token=synthetic'],
  ])('refuses a custom link outside its valid configured origin %s', async (origin, response) => {
    mocks.list.mockResolvedValue({ time_tracking_sources: [{ ...source, source_type: 'custom',
      supported_operations: ['account_linking'], authorization_origin: origin }] });
    mocks.create.mockResolvedValue({ authorization_url: response });
    const navigate = vi.fn(); view(undefined, navigate);
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Connect my time tracking account' }));
    expect((await screen.findByRole('alert')).textContent).toContain('Time tracking returned an invalid connection link');
    expect(navigate).not.toHaveBeenCalled();
    expect(sessionStorage.getItem('aire-own-link-return:4')).toBeNull();
  });
  it('never returns to another company or an external location supplied in a query', async () => {
    view('/app/aire-account-connection?source_id=4&return_to=%2Fcompanies%2F8%2Fpay-runs%2F67');
    await screen.findByText('Not connected');
    expect(screen.getByRole('link', { name: 'Return to payroll' }).getAttribute('href')).toBe('/companies/7/pay-runs');
  });
  it('restores the authorized company and work context after AIRE redirects back', async () => {
    sessionStorage.setItem('aire-own-link-return:5', JSON.stringify({ companyId: 8, returnTo: '/companies/8/pay-runs/68/work' }));
    mocks.list.mockResolvedValue({ time_tracking_sources: [{ ...source, id: 5, company_id: 8 }] });
    const rendered = view('/app/aire-account-connection?source_id=5&aire_link=connected');
    await waitFor(() => expect(mocks.switchCompany).toHaveBeenCalledWith(8));
    expect(mocks.list).not.toHaveBeenCalled();
    mocks.companyId = 8;
    rendered.rerender(<MemoryRouter initialEntries={['/app/aire-account-connection?source_id=5&aire_link=connected']}><AireAccountConnection /></MemoryRouter>);
    await screen.findByText('Not connected');
    expect(mocks.read).toHaveBeenCalledWith(5);
    expect(screen.getByRole('link', { name: 'Return to payroll' }).getAttribute('href')).toBe('/companies/8/pay-runs/68/work');
  });
  it('restores OAuth company context once and then permits a deliberate company switch', async () => {
    sessionStorage.setItem('aire-own-link-return:4', JSON.stringify({ companyId: 7, returnTo: '/companies/7/pay-runs/67/work' }));
    const rendered = view('/app/aire-account-connection?source_id=4&aire_link=connected');
    await screen.findByText('Not connected');
    mocks.companyId = 8; mocks.list.mockResolvedValue({ time_tracking_sources: [] });
    rendered.rerender(<MemoryRouter initialEntries={['/app/aire-account-connection?source_id=4&aire_link=connected']}><AireAccountConnection /></MemoryRouter>);
    await screen.findByText(/no active time tracking source/);
    expect(mocks.switchCompany).not.toHaveBeenCalled();
    expect(screen.getByRole('link', { name: 'Return to payroll' }).getAttribute('href')).toBe('/companies/8/pay-runs');
  });
  it('ignores a completed connection request after switching companies', async () => {
    let complete!: (result: { authorization_url: string }) => void;
    mocks.create.mockReturnValue(new Promise(resolve => { complete = resolve; }));
    const navigate = vi.fn(); const rendered = view(undefined, navigate);
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Connect my time tracking account' }));
    mocks.companyId = 8; mocks.list.mockResolvedValue({ time_tracking_sources: [] });
    rendered.rerender(<MemoryRouter initialEntries={['/app/aire-account-connection?source_id=4']}><AireAccountConnection navigateToAuthorization={navigate} /></MemoryRouter>);
    complete({ authorization_url: url });
    await screen.findByText(/no active time tracking source/);
    expect(navigate).not.toHaveBeenCalled();
    expect(sessionStorage.getItem('aire-own-link-return:4')).toBeNull();
  });
});
