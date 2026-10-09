// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeIntakeSettingsPanel } from './EmployeeIntakeSettingsPanel';

const mocks = vi.hoisted(() => ({ settings: vi.fn(), update: vi.fn() }));
vi.mock('@/services/employee-intake-api', () => ({ employeeIntakeApi: { settings: mocks.settings, updateSettings: mocks.update } }));
const strict = { enabled: false, can_manage: true, expires_at: null, reason: null, enabled_by_name: null };

describe('Company-scoped incomplete entry window', () => {
  afterEach(cleanup);
  beforeEach(() => { vi.clearAllMocks(); mocks.settings.mockResolvedValue({ data: strict }); mocks.update.mockResolvedValue({ data: strict }); });

  it('requires a reason and submits an expiring window for the selected company', async () => {
    render(<EmployeeIntakeSettingsPanel companyId={4} isClient={false} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Allow incomplete entry temporarily' }));
    const enable = await screen.findByRole('button', { name: 'Enable incomplete entry' });
    expect(enable.hasAttribute('disabled')).toBe(true);
    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'Employer information pending' } });
    fireEvent.click(enable);
    await waitFor(() => expect(mocks.update).toHaveBeenCalledWith(4, expect.objectContaining({ enabled: true, reason: 'Employer information pending' })));
    const expiry = new Date(mocks.update.mock.calls[0][1].expires_at).getTime();
    expect(expiry - Date.now()).toBeGreaterThan(3_500_000);
    expect(expiry - Date.now()).toBeLessThanOrEqual(3_600_000);
  });

  it('fails closed when entry settings cannot be loaded', async () => {
    mocks.settings.mockRejectedValue(new Error('Unavailable'));
    render(<EmployeeIntakeSettingsPanel companyId={4} isClient={false} />);
    expect(await screen.findByRole('button', { name: 'Retry entry settings' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Enable incomplete entry' })).toBeNull();
  });

  it('does not offer the toggle to an operator', async () => {
    mocks.settings.mockResolvedValue({ data: { ...strict, can_manage: false } });
    render(<EmployeeIntakeSettingsPanel companyId={4} isClient={false} />);
    await screen.findByText('Full employee details required');
    expect(screen.queryByText('Allow incomplete entry temporarily')).toBeNull();
  });

  it('never carries another company’s enabled settings into the new company', async () => {
    let resolve!: (value: { data: typeof strict }) => void;
    mocks.settings.mockImplementation((id: number) => id === 4 ? Promise.resolve({ data: { ...strict, enabled: true, expires_at: new Date(Date.now() + 3_600_000).toISOString() } }) : new Promise((done) => { resolve = done; }));
    const view = render(<EmployeeIntakeSettingsPanel companyId={4} isClient={false} />);
    await screen.findByText('Incomplete employee entry is temporarily enabled');
    view.rerender(<EmployeeIntakeSettingsPanel companyId={5} isClient={false} />);
    expect(screen.queryByText('Incomplete employee entry is temporarily enabled')).toBeNull();
    resolve({ data: strict });
    await screen.findByText('Full employee details required');
  });
});
