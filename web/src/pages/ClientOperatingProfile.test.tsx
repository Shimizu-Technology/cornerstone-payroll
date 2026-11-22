// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '@/services/api';
import { operatingProfileApi, type CatalogEntry, type OperatingProfileResponse } from '@/services/operating-profile';
import { ClientOperatingProfile } from './ClientOperatingProfile';

vi.mock('@/components/layout/Header', () => ({ Header: ({ title }: { title: string }) => <h1>{title}</h1> }));
vi.mock('@/services/operating-profile', () => ({
  operatingProfileApi: { get: vi.fn(), update: vi.fn() },
}));

const baseEntry = { section: 'core', storage: 'column', type: 'enum', what: 'How this setting works.', example: 'Example', effect: 'Effect', requires: [] } as const;
const catalog: CatalogEntry[] = [
  { ...baseEntry, requires: [], id: 'offering', label: 'Service offering', default: 'payroll_service', allowed: ['payroll_service', 'workforce_suite'] },
  { ...baseEntry, requires: [], id: 'hours_source', label: 'Hours source', default: 'manual', allowed: ['manual', 'connected_app', 'intake_adapter'] },
  { ...baseEntry, requires: ['hours_source=intake_adapter'], id: 'intake_adapter', label: 'Intake adapter',
    type: 'nullable_enum', default: null, allowed: ['mosa_revel'] },
  { ...baseEntry, requires: ['hours_source=intake_adapter'], id: 'intake.required_sources', label: 'Required intake sources',
    section: 'intake', storage: 'option', type: 'nullable_string_array', default: null, allowed: null },
  { ...baseEntry, requires: ['client_portal_enabled'], id: 'client_portal.uploaders', label: 'Allowed client portal uploaders',
    section: 'client_portal', storage: 'option', type: 'uploaders', default: 'all_client_users', allowed: null },
  { ...baseEntry, requires: [], id: 'employee_portal_enabled', label: 'Employee portal enabled', section: 'employee_portal', type: 'boolean', default: false, allowed: [true, false], locked_until_milestone: 4 },
  { ...baseEntry, requires: ['employee_portal_enabled'], id: 'employee_portal.former_access_years',
    label: 'Former employee portal access window (years)', section: 'employee_portal', storage: 'option',
    type: 'integer', default: 6, allowed: { min: 1, max: 10 }, locked_until_milestone: 4 },
  { ...baseEntry, requires: [], id: 'tips.default', label: 'Tips default', section: 'intake', storage: 'option', default: 'paid_in_check', allowed: ['paid_in_check', 'already_paid_out'] },
];

const version = {
  id: 9, effective_on: '2026-01-01', ends_on: null, version: 1, persisted: true, reason: null,
  offering: 'payroll_service', hours_source: 'manual', intake_adapter: null, client_portal_enabled: false,
  employee_portal_enabled: false, options: { tips: { default: 'paid_in_check' } },
};
const fixture: OperatingProfileResponse = {
  client_name: 'Fictional Test Client', as_of: '2026-11-23', lock_version: 0, effective: version, history: [version],
  catalog, editable_keys: catalog.map((field) => field.id), locked_keys: ['employee_portal_enabled', 'employee_portal.former_access_years'],
  available_effective_dates: ['2026-11-16', '2026-11-30'],
  offering_presets: { workforce_suite: { hours_source: 'connected_app' } }, connected_source_active: false,
};

function open() {
  render(
    <MemoryRouter initialEntries={['/companies/34/operating-profile']}>
      <Routes><Route path="/companies/:companyId/operating-profile" element={<ClientOperatingProfile />} /></Routes>
    </MemoryRouter>,
  );
}

async function fillDraft() {
  const user = userEvent.setup();
  await user.selectOptions(await screen.findByRole('combobox', { name: 'Tips default' }), 'already_paid_out');
  fireEvent.change(screen.getByLabelText('Effective date'), { target: { value: '2026-11-16' } });
  await user.type(screen.getByLabelText('Reason for change'), 'Document the tips payment workflow');
  return user;
}

beforeEach(() => {
  vi.resetAllMocks();
  vi.mocked(operatingProfileApi.get).mockResolvedValue(fixture);
});

afterEach(cleanup);

describe('Client operating profile editor', () => {
  it('submits only changed settings with the lock token and displays the saved version', async () => {
    const saved = { ...version, id: 10, version: 2, effective_on: '2026-11-16', options: { tips: { default: 'already_paid_out' } } };
    vi.mocked(operatingProfileApi.update).mockResolvedValue({ ...fixture, history: [saved, version], effective: saved, lock_version: 1, saved });
    open();

    const user = await fillDraft();
    await user.click(screen.getByRole('button', { name: 'Save operating profile' }));

    expect(operatingProfileApi.update).toHaveBeenCalledWith(34, {
      effective_on: '2026-11-16',
      reason: 'Document the tips payment workflow',
      lock_version: 0,
      changes: { 'tips.default': 'already_paid_out' },
    });
    expect(await screen.findByText('Version 2 saved, effective 2026-11-16.')).toBeTruthy();
    expect(screen.getByText('Active version 2')).toBeTruthy();
    expect((screen.getByRole('combobox', { name: 'Tips default' }) as HTMLSelectElement).value).toBe('already_paid_out');
  });

  it('applies the offering preset and warns when there is no active connected source', async () => {
    open();
    const user = userEvent.setup();
    await user.selectOptions(await screen.findByRole('combobox', { name: 'Service offering preset' }), 'workforce_suite');

    expect((screen.getByRole('combobox', { name: 'Hours source' }) as HTMLSelectElement).value).toBe('connected_app');
    expect(screen.getByText('This client has no active connected time source.')).toBeTruthy();
    expect(screen.getByText('Off · Available in Milestone 4')).toBeTruthy();
    expect(screen.queryByRole('combobox', { name: 'Employee portal enabled' })).toBeNull();
    expect(screen.queryByRole('spinbutton', { name: /Former employee/ })).toBeNull();
    expect(screen.getByText('6 · Available in Milestone 4')).toBeTruthy();
    expect(operatingProfileApi.update).not.toHaveBeenCalled();
  });

  it('keeps the manager’s hours source when applying a preset', async () => {
    vi.mocked(operatingProfileApi.get).mockResolvedValue({ ...fixture, editable_keys: ['offering'] });
    open();
    await userEvent.setup().selectOptions(await screen.findByRole('combobox', { name: 'Service offering preset' }), 'workforce_suite');

    const hoursSource = screen.getByRole('combobox', { name: 'Hours source' }) as HTMLSelectElement;
    expect(hoursSource.disabled).toBe(true);
    expect(hoursSource.value).toBe('manual');
    expect(screen.getByText(/Kept Hours source/)).toBeTruthy();
  });

  it('shows read-only settings and exposes help explaining the setting, effect and example', async () => {
    vi.mocked(operatingProfileApi.get).mockResolvedValue({ ...fixture, editable_keys: [] });
    open();

    expect(await screen.findByText('You have read-only access to this operating profile.')).toBeTruthy();
    expect((screen.getByRole('combobox', { name: 'Hours source' }) as HTMLSelectElement).disabled).toBe(true);
    expect(screen.queryByRole('button', { name: 'Save operating profile' })).toBeNull();

    const help = screen.getByRole('button', { name: 'Help for Hours source' });
    const popoverId = help.getAttribute('popovertarget');
    const popover = document.getElementById(popoverId ?? '');
    expect(popover?.getAttribute('popover')).toBe('auto');
    expect(popover?.textContent).toContain('How this setting works.');
    expect(popover?.textContent).toContain('Effect');
    expect(popover?.textContent).toContain('Example');
  });

  it('clears the adapter and any specific source requirements when switching away from intake', async () => {
    const intake = { ...version, hours_source: 'intake_adapter', intake_adapter: 'mosa_revel',
      options: { intake: { required_sources: ['revel_pdf'] } } };
    vi.mocked(operatingProfileApi.get).mockResolvedValue({ ...fixture, effective: intake, history: [intake] });
    vi.mocked(operatingProfileApi.update).mockResolvedValue({ ...fixture, saved: version });
    open();

    const user = await fillDraft();
    await user.selectOptions(screen.getByRole('combobox', { name: 'Hours source' }), 'manual');
    await user.click(screen.getByRole('button', { name: 'Save operating profile' }));

    expect(operatingProfileApi.update).toHaveBeenCalledWith(34, expect.objectContaining({
      changes: { 'tips.default': 'already_paid_out', hours_source: 'manual', intake_adapter: null, 'intake.required_sources': null },
    }));
  });

  it.each([
    { mode: 'inherit', initial: ['revel_pdf'], expected: null },
    { mode: 'single', initial: null, expected: [] },
    { mode: 'list', initial: [], expected: ['revel_pdf', 'workbook'] },
  ])('submits the $mode source mode and trims blank list items', async ({ mode, initial, expected }) => {
    const intake = { ...version, hours_source: 'intake_adapter', intake_adapter: 'mosa_revel',
      options: { intake: { required_sources: initial } } };
    vi.mocked(operatingProfileApi.get).mockResolvedValue({ ...fixture, effective: intake, history: [intake] });
    vi.mocked(operatingProfileApi.update).mockResolvedValue({ ...fixture, saved: intake });
    open();

    const user = await fillDraft();
    const sourceMode = screen.getByRole('combobox', { name: 'Required intake sources' }) as HTMLSelectElement;
    expect(sourceMode.value).toBe(initial === null ? 'inherit' : initial.length === 0 ? 'single' : 'list');
    await user.selectOptions(sourceMode, mode);
    if (mode === 'list') {
      await user.type(screen.getByLabelText('Source roles'), ' revel_pdf, , workbook, ');
    }
    await user.type(screen.getByRole('textbox', { name: 'Allowed client portal uploaders' }), ' 42, , 43, ');
    await user.click(screen.getByRole('button', { name: 'Save operating profile' }));

    expect(operatingProfileApi.update).toHaveBeenCalledWith(34, expect.objectContaining({
      changes: { 'tips.default': 'already_paid_out', 'client_portal.uploaders': [42, 43], 'intake.required_sources': expected },
    }));
  });

  it('preserves the draft on rejection and asks for an explicit reload on conflict', async () => {
    vi.mocked(operatingProfileApi.update)
      .mockRejectedValueOnce(new ApiError('Use the start of a draft pay period.', 422))
      .mockRejectedValueOnce(new ApiError('The operating profile changed.', 409));
    open();

    const user = await fillDraft();
    await user.click(screen.getByRole('button', { name: 'Save operating profile' }));
    expect((await screen.findByRole('alert')).textContent).toContain('Use the start of a draft pay period.');
    expect((screen.getByLabelText('Reason for change') as HTMLTextAreaElement).value).toBe('Document the tips payment workflow');
    await user.click(screen.getByRole('button', { name: 'Save operating profile' }));
    await user.click(await screen.findByRole('button', { name: 'Reload and discard draft' }));
    await waitFor(() => expect(operatingProfileApi.get).toHaveBeenCalledTimes(2));
    expect((await screen.findByRole('combobox', { name: 'Tips default' }) as HTMLSelectElement).value).toBe('paid_in_check');
  });
});
