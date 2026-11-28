// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '@/services/api';
import { operatingProfileApi, type CatalogEntry, type OperatingProfileResponse } from '@/services/operating-profile';
import { ClientOperatingProfile } from './ClientOperatingProfile';

const lifecycleMocks = vi.hoisted(() => ({ retry: vi.fn(), revert: vi.fn() }));
vi.mock('@/services/staff-employee-lifecycle', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/services/staff-employee-lifecycle')>(),
  staffEmployeeLifecycleApi: { retryActivation: lifecycleMocks.retry, revertActivation: lifecycleMocks.revert },
}));
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
  { ...baseEntry, requires: ['client_portal_enabled'], id: 'client_portal.employee_lifecycle_mode',
    label: 'Employee lifecycle mode', section: 'client_portal', storage: 'option', type: 'enum',
    default: 'approval_first', allowed: ['approval_first', 'client_managed'], locked_until_milestone: 4 },
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
  catalog, editable_keys: catalog.map((field) => field.id), locked_keys: ['client_portal.employee_lifecycle_mode', 'employee_portal_enabled', 'employee_portal.former_access_years'],
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
    expect(await screen.findByText('Version 2 saved, effective Nov 16, 2026.')).toBeTruthy();
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
    expect(screen.getByText('Cornerstone approves first · Available in Milestone 4')).toBeTruthy();
    expect(screen.queryByText(/Available in Milestone undefined/)).toBeNull();
    expect(screen.queryByRole('combobox', { name: 'Employee lifecycle mode' })).toBeNull();
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

describe('Employee lifecycle controls', () => {
  const lifecycle = 'client_portal.employee_lifecycle_mode';
  const pendingChecks = {
    pending_non_address_change_requests_count: 2,
    active_intake_window: true,
    qualifying_staff_notification_recipients_count: 0,
    ready: false,
    blockers: [],
    lifecycle_mode_activation_status: 'blocked' as const,
    lifecycle_mode_activation_blockers: {
      pending_non_address_change_requests_count: 1, active_intake_window: true, qualifying_staff_notification_recipients_count: 0,
    },
    scheduled_effective_on: '2026-11-16',
  };

  it('keeps the mode control locked and hides deprecated review-first settings', async () => {
    const deprecated = { ...catalog.find(field => field.id === lifecycle)!, id: 'client_portal.review_first.pay', label: 'Legacy review-first pay', deprecated: true };
    const catalogDeprecated = { ...deprecated, id: 'client_portal.retired_option', label: 'Retired option' };
    vi.mocked(operatingProfileApi.get).mockResolvedValue({ ...fixture, catalog: [...catalog, deprecated, catalogDeprecated],
      editable_keys: [...fixture.editable_keys, catalogDeprecated.id] });
    open();
    await screen.findByText(/Cornerstone approves first · Available in Milestone 4/);
    expect(screen.queryByRole('combobox', { name: 'Employee lifecycle mode' })).toBeNull();
    expect(screen.queryByText('Legacy review-first pay')).toBeNull();
    expect(screen.queryByText('Retired option')).toBeNull();
    expect(screen.queryByText('Scheduled employee lifecycle switch blocked')).toBeNull();
  });

  it('renders each preflight requirement and retries through the activation endpoint', async () => {
    lifecycleMocks.retry.mockResolvedValue({ ...fixture, employee_lifecycle_preflight: { ...pendingChecks, lifecycle_mode_activation_status: 'active' } });
    vi.mocked(operatingProfileApi.get).mockResolvedValue({ ...fixture, locked_keys: [], employee_lifecycle_preflight: pendingChecks });
    open();
    const blocked = (await screen.findByRole('heading', { name: 'Scheduled employee lifecycle switch blocked' })).closest('[role=status]') as HTMLElement;
    const preflight = screen.getByRole('heading', { name: 'Before switching to client-managed mode' }).parentElement!;
    expect(within(blocked).getByText('1 pending employee change request to review.')).toBeTruthy();
    expect(within(preflight).getByText('2 pending employee change requests to review.')).toBeTruthy();
    for (const section of [blocked, preflight]) {
      expect(within(section).getByRole('link', { name: 'Review change requests' })).toHaveProperty('pathname', '/companies/34/client-change-requests');
      expect(within(section).getByRole('link', { name: 'Open employee entry settings' })).toHaveProperty('pathname', '/companies/34/employees');
      expect(within(section).getByRole('link', { name: 'Manage notification recipients' }).getAttribute('href')).toBe('/companies/34/client-documents#portal-alert-recipients');
    }
    fireEvent.click(screen.getByRole('button', { name: 'Retry activation' }));
    await screen.findByText('Client-managed mode is active.');
    expect(lifecycleMocks.retry).toHaveBeenCalledWith(34);
  });

  it('explains by Save why the selected mode cannot be saved', async () => {
    vi.mocked(operatingProfileApi.get).mockResolvedValue({ ...fixture, locked_keys: [], employee_lifecycle_preflight: {
      ...pendingChecks, lifecycle_mode_activation_status: 'inactive',
    } });
    open();
    await fillDraft();
    fireEvent.change(screen.getByRole('combobox', { name: 'Employee lifecycle mode' }), { target: { value: 'client_managed' } });
    const save = screen.getByRole('button', { name: 'Save operating profile' });
    expect(save).toHaveProperty('disabled', true);
    expect(within(save.parentElement!).getByText(/Resolve the employee lifecycle preflight checks above/)).toBeTruthy();
  });

  it('reverts the blocked scheduled version using its effective date, reason and lock token', async () => {
    lifecycleMocks.revert.mockResolvedValue({ ...fixture, employee_lifecycle_preflight: { ...pendingChecks, lifecycle_mode_activation_status: 'inactive' } });
    vi.mocked(operatingProfileApi.get).mockResolvedValue({ ...fixture, lock_version: 4, locked_keys: [], employee_lifecycle_preflight: pendingChecks });
    open();
    fireEvent.click(await screen.findByRole('button', { name: 'Revert to Cornerstone approval' }));
    fireEvent.change(screen.getByLabelText('Reason for reverting'), { target: { value: 'Keep current employee approvals.' } });
    fireEvent.click(screen.getByRole('button', { name: 'Revert mode' }));
    await screen.findByText('The scheduled switch was reverted.');
    expect(lifecycleMocks.revert).toHaveBeenCalledWith(34, {
      effective_on: '2026-11-16', lock_version: 4, reason: 'Keep current employee approvals.',
    });
  });

  it('rebases untouched settings from the activation response while preserving local edits', async () => {
    const serverChanged = {
      ...version,
      id: 11,
      version: 2,
      hours_source: 'connected_app',
      options: { tips: { default: 'paid_in_check' }, client_portal: { employee_lifecycle_mode: 'client_managed' } },
    };
    const activatedResponse: OperatingProfileResponse = {
      ...fixture,
      lock_version: 2,
      locked_keys: [],
      effective: serverChanged,
      history: [serverChanged, version],
      employee_lifecycle_preflight: { ...pendingChecks, lifecycle_mode_activation_status: 'active' },
    };
    const saved = {
      ...serverChanged,
      id: 12,
      version: 3,
      effective_on: '2026-11-16',
      options: { tips: { default: 'already_paid_out' }, client_portal: { employee_lifecycle_mode: 'client_managed' } },
    };
    lifecycleMocks.retry.mockResolvedValue(activatedResponse);
    vi.mocked(operatingProfileApi.get).mockResolvedValue({
      ...fixture,
      lock_version: 1,
      locked_keys: [],
      employee_lifecycle_preflight: pendingChecks,
    });
    vi.mocked(operatingProfileApi.update).mockResolvedValue({ ...activatedResponse, lock_version: 3, effective: saved, history: [saved, serverChanged], saved });

    open();
    const user = userEvent.setup();
    await user.selectOptions(await screen.findByRole('combobox', { name: 'Tips default' }), 'already_paid_out');
    await user.click(screen.getByRole('button', { name: 'Retry activation' }));
    await screen.findByText('Client-managed mode is active.');

    expect((screen.getByRole('combobox', { name: 'Hours source' }) as HTMLSelectElement).value).toBe('connected_app');
    expect((screen.getByRole('combobox', { name: 'Tips default' }) as HTMLSelectElement).value).toBe('already_paid_out');

    fireEvent.change(screen.getByLabelText('Effective date'), { target: { value: '2026-11-16' } });
    await user.type(screen.getByLabelText('Reason for change'), 'Preserve local tips edit without overwriting hours source');
    await user.click(screen.getByRole('button', { name: 'Save operating profile' }));

    expect(operatingProfileApi.update).toHaveBeenCalledWith(34, {
      effective_on: '2026-11-16',
      reason: 'Preserve local tips edit without overwriting hours source',
      lock_version: 2,
      changes: { 'tips.default': 'already_paid_out' },
    });
  });

  it('lets an authorized user select client_managed when preflights pass and enforces mode-change capability', async () => {
    const readyPreflight = {
      ...pendingChecks,
      pending_non_address_change_requests_count: 0,
      active_intake_window: false,
      qualifying_staff_notification_recipients_count: 2,
      ready: true,
      lifecycle_mode_activation_status: 'inactive' as const,
      lifecycle_mode_activation_blockers: {},
      scheduled_effective_on: null,
    };
    const saved = {
      ...version, id: 13, version: 2, effective_on: '2026-11-16', client_portal_enabled: true,
      options: { tips: { default: 'paid_in_check' }, client_portal: { employee_lifecycle_mode: 'client_managed' } },
    };
    vi.mocked(operatingProfileApi.get).mockResolvedValue({
      ...fixture,
      effective: { ...version, client_portal_enabled: true },
      history: [{ ...version, client_portal_enabled: true }],
      locked_keys: ['employee_portal_enabled', 'employee_portal.former_access_years'],
      employee_lifecycle_preflight: readyPreflight,
    });
    vi.mocked(operatingProfileApi.update).mockResolvedValue({
      ...fixture,
      locked_keys: ['employee_portal_enabled', 'employee_portal.former_access_years'],
      effective: saved,
      history: [saved, version],
      lock_version: 1,
      employee_lifecycle_preflight: { ...readyPreflight, lifecycle_mode_activation_status: 'active' },
      saved,
    });

    open();
    const user = userEvent.setup();
    const modeSelect = await screen.findByRole('combobox', { name: 'Employee lifecycle mode' }) as HTMLSelectElement;
    expect(modeSelect.disabled).toBe(false);
    expect(modeSelect.value).toBe('approval_first');
    expect(screen.getByText('No pending employee change requests')).toBeTruthy();
    expect(screen.getByText('2 staff notification recipients configured')).toBeTruthy();

    await user.selectOptions(modeSelect, 'client_managed');
    fireEvent.change(screen.getByLabelText('Effective date'), { target: { value: '2026-11-16' } });
    await user.type(screen.getByLabelText('Reason for change'), 'Enable client-managed mode after preflights');
    await user.click(screen.getByRole('button', { name: 'Save operating profile' }));

    expect(operatingProfileApi.update).toHaveBeenCalledWith(34, {
      effective_on: '2026-11-16',
      reason: 'Enable client-managed mode after preflights',
      lock_version: 0,
      changes: { [lifecycle]: 'client_managed' },
    });

    cleanup();

    // Without mode-change capability (e.g., manager), the unlocked selector stays disabled while preflights remain visible.
    vi.mocked(operatingProfileApi.get).mockResolvedValue({
      ...fixture,
      locked_keys: ['employee_portal_enabled', 'employee_portal.former_access_years'],
      editable_keys: fixture.editable_keys.filter(key => key !== lifecycle),
      employee_lifecycle_preflight: readyPreflight,
    });
    open();
    const readOnlySelect = await screen.findByRole('combobox', { name: 'Employee lifecycle mode' }) as HTMLSelectElement;
    expect(readOnlySelect.disabled).toBe(true);
    expect(screen.getByText('No pending employee change requests')).toBeTruthy();
  });
});
