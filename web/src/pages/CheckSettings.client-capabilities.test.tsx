// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CompanyListItem } from '@/services/api';
import { CheckSettingsPage } from './CheckSettings';
const mocks = vi.hoisted(() => ({
  company: null as CompanyListItem | null, id: 1,
  get: vi.fn(), update: vi.fn(), layout: vi.fn(), profiles: vi.fn(), next: vi.fn(),
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { role: 'accountant' }, hasCapability: () => false }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: mocks.company, activeCompanyId: mocks.id }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/documents/PdfPreview', () => ({ PdfPreview: () => null }));
vi.mock('@/components/checks/CheckLayoutEditor', () => ({ CheckLayoutEditor: () => null }));
vi.mock('@/services/api', () => ({
  checksApi: { getSettings: mocks.get, updateSettings: mocks.update, getLayout: mocks.layout, updateNextCheckNumber: mocks.next },
  printerProfilesApi: { list: mocks.profiles },
}));
const settings = { check_stock_type: 'top_check', check_offset_x: 0, check_offset_y: 0, bank_name: 'Synthetic bank', bank_address: '', check_layout_config: {}, next_check_number: 1001 };
beforeEach(() => {
  vi.clearAllMocks(); mocks.id = 1;
  mocks.company = { id: 1, client_capabilities: ['manage_client_check_settings'] } as CompanyListItem;
  mocks.get.mockResolvedValue({ check_settings: settings }); mocks.update.mockResolvedValue({ check_settings: settings });
  mocks.layout.mockResolvedValue({ check_layout: null }); mocks.profiles.mockResolvedValue({ printer_profiles: [], selections: [] });
});
afterEach(cleanup);
describe('selected client check controls', () => {
  it('allows a delegated accountant to save client check settings without granting printer-library management', async () => {
    const user = userEvent.setup();
    render(<CheckSettingsPage />);
    await user.click(await screen.findByRole('button', { name: 'Save Client Check Settings' }));
    await screen.findByText('Client check settings saved. Select a printer profile to keep calibration with your printer.');
    expect(mocks.update).toHaveBeenCalledOnce();
    expect(screen.queryByRole('button', { name: 'Edit details' })).toBeNull();
  });
  it('removes client controls immediately on client switch and fails closed until the new client grants access', async () => {
    const view = render(<CheckSettingsPage />);
    await screen.findByRole('button', { name: 'Save Client Check Settings' });
    mocks.id = 2;
    view.rerender(<CheckSettingsPage />);
    expect(screen.queryByRole('button', { name: 'Save Client Check Settings' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Update Next Number' })).toBeNull();
    mocks.company = { id: 2 } as CompanyListItem;
    view.rerender(<CheckSettingsPage />);
    expect(screen.queryByRole('button', { name: 'Save Client Check Settings' })).toBeNull();
    expect(mocks.update).not.toHaveBeenCalled();
  });
  it.each<Partial<CompanyListItem>>([
    { test_workspace: true, workspace_can_write: true, workspace_write_permissions: { payroll_operations: true, manage_client_check_settings: false } },
    { test_workspace: true, workspace_can_write: true, workspace_write_permissions: { payroll_operations: true } },
    { test_workspace_expired: true }, { test_workspace_sealed_at: '2026-10-01T00:00:00Z' },
  ])('retains workspace write restrictions despite a client grant: %j', async restrictions => {
    mocks.company = { ...mocks.company!, ...restrictions };
    render(<CheckSettingsPage />);
    await screen.findByRole('button', { name: 'Save Calibration as New Profile' });
    expect(screen.queryByRole('button', { name: 'Save Client Check Settings' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Update Next Number' })).toBeNull();
  });
});
