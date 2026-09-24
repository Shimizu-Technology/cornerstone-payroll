// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { CheckSettingsPage } from './CheckSettings';

const apiMocks = vi.hoisted(() => ({
  getSettings: vi.fn(),
  updateSettings: vi.fn(),
  getLayout: vi.fn(),
  listProfiles: vi.fn(),
  createProfile: vi.fn(),
  selectProfile: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  checksApi: {
    getSettings: apiMocks.getSettings,
    updateSettings: apiMocks.updateSettings,
    getLayout: apiMocks.getLayout,
  },
  printerProfilesApi: {
    list: apiMocks.listProfiles,
    create: apiMocks.createProfile,
    selectForMe: apiMocks.selectProfile,
  },
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ hasCapability: () => true }),
}));

vi.mock('@/components/documents/PdfPreview', () => ({ PdfPreview: () => null }));
vi.mock('@/components/checks/CheckLayoutEditor', () => ({ CheckLayoutEditor: () => null }));

const savedSettings = {
  next_check_number: 1002,
  check_stock_type: 'bottom_check',
  check_offset_x: 0,
  check_offset_y: 0,
  bank_name: null,
  bank_address: null,
  check_memo_template: null,
  auto_create_fit_check: false,
  require_distinct_check_print_confirmer: false,
  check_layout_config: {},
  active_printer_profile_id: null,
  active_printer_profile_name: null,
  active_printer_profile_lock_version: null,
};

const topProfile = {
  id: 17,
  name: 'Top stock test',
  check_stock_type: 'top_check',
  check_offset_x: 0,
  check_offset_y: 0,
  check_layout_config: {},
  lock_version: 0,
};

describe('CheckSettingsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.getSettings.mockResolvedValue({ check_settings: savedSettings });
    apiMocks.getLayout.mockResolvedValue({ check_layout: {} });
    apiMocks.listProfiles.mockResolvedValue({ printer_profiles: [], selections: [], active_printer_profile_id: null });
    apiMocks.createProfile.mockResolvedValue({ printer_profile: topProfile });
    apiMocks.selectProfile.mockResolvedValue({ selection: {
      id: 1,
      check_stock_type: 'top_check',
      printer_profile_id: topProfile.id,
      printer_profile_name: topProfile.name,
    } });
    apiMocks.updateSettings.mockResolvedValue({ check_settings: {
      ...savedSettings,
      check_stock_type: 'top_check',
      active_printer_profile_id: topProfile.id,
      active_printer_profile_name: topProfile.name,
      active_printer_profile_lock_version: 1,
    } });
  });

  afterEach(cleanup);

  it('keeps a newly selected draft-stock profile and sends its version when saving the stock change', async () => {
    render(<MemoryRouter><CheckSettingsPage /></MemoryRouter>);
    await screen.findByText('No printer profile selected');

    fireEvent.change(screen.getByLabelText('Stock Type'), { target: { value: 'top_check' } });
    fireEvent.click(screen.getByRole('button', { name: '+ Save Current as Profile' }));
    fireEvent.change(screen.getByPlaceholderText('e.g., Office HP LaserJet'), { target: { value: topProfile.name } });
    apiMocks.listProfiles.mockResolvedValue({
      printer_profiles: [topProfile],
      selections: [{ check_stock_type: 'top_check', printer_profile_id: topProfile.id, printer_profile_name: topProfile.name }],
      active_printer_profile_id: null,
    });
    fireEvent.click(screen.getByRole('button', { name: 'Save Profile' }));

    expect(await screen.findByRole('heading', { name: topProfile.name })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Save Client Check Settings' }));
    await waitFor(() => expect(apiMocks.updateSettings).toHaveBeenCalledWith(expect.objectContaining({
      check_stock_type: 'top_check',
      printer_profile_lock_version: 0,
    })));
  });
});
