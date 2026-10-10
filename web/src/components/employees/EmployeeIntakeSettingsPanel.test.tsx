// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeIntakeSettingsPanel } from './EmployeeIntakeSettingsPanel';

const mocks = vi.hoisted(() => ({ settings: vi.fn(), update: vi.fn() }));
vi.mock('@/services/employee-intake-api', () => ({ employeeIntakeApi: { settings: mocks.settings, updateSettings: mocks.update } }));
const strict = { enabled: false, can_manage: true, expires_at: null, reason: null, enabled_by_name: null };

describe('Company-scoped incomplete entry window', () => {
  afterEach(cleanup);
  beforeEach(() => { vi.restoreAllMocks(); vi.clearAllMocks(); mocks.settings.mockResolvedValue({ data: strict }); mocks.update.mockResolvedValue({ data: strict }); });

  it('requires a reason and submits an expiring window for the selected company', async () => {
    render(<EmployeeIntakeSettingsPanel companyId={4} isClient={false} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Allow incomplete entry temporarily' }));
    const enable = await screen.findByRole('button', { name: 'Enable incomplete entry' });
    expect(enable.hasAttribute('disabled')).toBe(true);
    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'Employer information pending' } });
    fireEvent.click(enable);
    await waitFor(() => expect(mocks.update).toHaveBeenCalledWith(4, expect.objectContaining({ enabled: true, reason: 'Employer information pending' })));
    expect(mocks.update.mock.calls[0][1]).toMatchObject({ duration_hours: 1 });
    expect(mocks.update.mock.calls[0][1]).not.toHaveProperty('expires_at');
  });

  it.each([1, 4, 24])('submits %s hours without a browser clock-derived expiration', async (hours) => {
    vi.spyOn(Date, 'now').mockReturnValue(new Date('2030-01-01T00:00:00Z').getTime());
    render(<EmployeeIntakeSettingsPanel companyId={4} isClient={false} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Allow incomplete entry temporarily' }));
    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'Employer information pending' } });
    fireEvent.change(screen.getByLabelText('Automatically require full details after'), { target: { value: String(hours) } });
    fireEvent.click(screen.getByRole('button', { name: 'Enable incomplete entry' }));
    await waitFor(() => expect(mocks.update).toHaveBeenCalledWith(4, { enabled: true, reason: 'Employer information pending', duration_hours: hours }));
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
