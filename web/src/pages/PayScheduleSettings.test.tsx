// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CompanyListItem, PayScheduleSettingsResponse, payScheduleSettingsApi } from '@/services/api';
import { PayScheduleSettings } from './PayScheduleSettings';

type ScheduleUpdate = Parameters<typeof payScheduleSettingsApi.update>[0];
const mocks = vi.hoisted(() => ({
  activeCompany: null as CompanyListItem | null,
  activeCompanyId: 2 as number | null,
  companyLoading: false,
  authLoading: false,
  capabilities: ['manage_client_configuration'],
  get: vi.fn<() => Promise<PayScheduleSettingsResponse>>(),
  update: vi.fn<(data: ScheduleUpdate) => Promise<PayScheduleSettingsResponse>>(),
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({
  isLoading: mocks.authLoading,
  hasCapability: (capability: string) => mocks.capabilities.includes(capability),
}) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({
  activeCompany: mocks.activeCompany && { ...mocks.activeCompany, client_capabilities: mocks.capabilities }, activeCompanyId: mocks.activeCompanyId, loading: mocks.companyLoading,
}) }));
vi.mock('@/services/api', () => ({ payScheduleSettingsApi: { get: mocks.get, update: mocks.update } }));

function company(overrides: Partial<CompanyListItem> = {}): CompanyListItem {
  return {
    id: 2, organization_id: 1, name: 'QA Schedule Workspace', active: true,
    active_employees: 1, total_employees: 1, pay_frequency: 'biweekly', historical_payroll_enabled: false,
    payroll_environment: 'migration_rehearsal', test_workspace: true, test_workspace_purpose: 'sandbox',
    workspace_can_write: true, workspace_write_permissions: { payroll_operations: true, manage_client_configuration: true },
    ...overrides,
  };
}
const retainedSettings: PayScheduleSettingsResponse = { pay_schedule_settings: {
  pay_schedule: {
    id: 11, effective_on: '2026-01-01', frequency: 'biweekly', period_rule: 'biweekly',
    period_start_weekday: 1, period_anchor_date: '2026-01-05', pay_date_rule: 'days_after_period_end',
    pay_date_offset_days: 5, payroll_cutoff_days_before: 7, time_tracking_cutoff_rule: 'before_pay_date',
    time_tracking_cutoff_days: 7, payroll_cutoff_at_minutes: 1020, timezone: 'Pacific/Guam',
    source: 'operator_confirmed', confirmation_status: 'confirmed', notes: 'Original employer confirmation',
  },
  workweek: {
    id: 12, effective_on: '2026-01-01', starts_on_weekday: 0, starts_at_minutes: 0,
    timezone: 'Pacific/Guam', source: 'operator_confirmed', confirmation_status: 'confirmed',
    notes: 'Original employer confirmation',
  },
} };
function savedSettings(data: ScheduleUpdate): PayScheduleSettingsResponse {
  return { pay_schedule_settings: {
    pay_schedule: { ...retainedSettings.pay_schedule_settings.pay_schedule, ...data.pay_schedule, id: 13, effective_on: data.effective_on },
    workweek: { ...retainedSettings.pay_schedule_settings.workweek, ...data.workweek, id: 14, effective_on: data.effective_on },
  } };
}
async function openPage() {
  const view = render(<PayScheduleSettings />);
  await screen.findByLabelText('Pay frequency');
  return view;
}
function change(label: string, value: string) {
  fireEvent.change(screen.getByLabelText(label), { target: { value } });
}
function assertReadOnly() {
  const group = screen.getByRole('group', { name: 'Pay schedule and legal workweek configuration' });
  const fields = group.querySelectorAll('input,select,textarea');
  expect(fields.length).toBeGreaterThan(8);
  // Native disabled fieldsets disable descendants even when .disabled is false.
  for (const field of fields) expect(field.matches(':disabled')).toBe(true);
  expect(screen.getByRole('button', { name: 'Confirm & save schedule' }).matches(':disabled')).toBe(true);
  expect(screen.getByRole('button', { name: 'Cancel' }).matches(':disabled')).toBe(false);
  expect(screen.getByText('Read-only schedule.')).toBeTruthy();
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.activeCompany = company();
  mocks.activeCompanyId = 2;
  mocks.companyLoading = false;
  mocks.authLoading = false;
  mocks.capabilities = ['manage_client_configuration'];
  mocks.get.mockResolvedValue(retainedSettings);
  mocks.update.mockImplementation(async (data) => savedSettings(data));
});
afterEach(cleanup);

describe('pay schedule effective configuration access', () => {
  it('lets a reviewer read saved values and Cancel while blocking native edits and Save', async () => {
    mocks.activeCompany = company({ workspace_can_write: false, workspace_write_permissions: { payroll_operations: false, manage_client_configuration: false } });
    const user = userEvent.setup();
    await openPage();
    assertReadOnly();
    expect((screen.getByLabelText('Pay frequency') as HTMLSelectElement).value).toBe('biweekly');
    expect((screen.getByLabelText('Known period start date') as HTMLInputElement).value).toBe('2026-01-05');
    expect((screen.getByLabelText('Lock time (Guam)') as HTMLInputElement).value).toBe('17:00');
    expect((screen.getByLabelText('Confirmation source / notes') as HTMLTextAreaElement).value).toBe('Original employer confirmation');
    expect(screen.getByText(/You have read-only access to this workspace/)).toBeTruthy();
    await user.selectOptions(screen.getByLabelText('Pay frequency'), 'weekly');
    await user.type(screen.getByLabelText('Confirmation source / notes'), ' accidental edit');
    expect((screen.getByLabelText('Pay frequency') as HTMLSelectElement).value).toBe('biweekly');
    expect((screen.getByLabelText('Confirmation source / notes') as HTMLTextAreaElement).value).toBe('Original employer confirmation');
    await user.click(screen.getByRole('button', { name: 'Confirm & save schedule' }));
    expect(mocks.update).not.toHaveBeenCalled();
    await user.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(mocks.get).toHaveBeenCalledTimes(1);
    expect(mocks.update).not.toHaveBeenCalled();
    expect(screen.getByRole('heading', { name: 'Pay Schedule & Workweek' })).toBeTruthy();
  });

  it.each([
    { label: 'payroll operator without configuration grant', setup: () => { mocks.activeCompany = company({ workspace_write_permissions: { payroll_operations: true, manage_client_configuration: false } }); } },
    { label: 'workspace with missing configuration grant', setup: () => { mocks.activeCompany = company({ workspace_write_permissions: { payroll_operations: true } }); } },
    { label: 'expired workspace', setup: () => { mocks.activeCompany = company({ test_workspace_expired: true }); } },
    { label: 'sealed workspace', setup: () => { mocks.activeCompany = company({ test_workspace_sealed_at: '2026-01-01T00:00:00Z' }); } },
    { label: 'preserved backup', setup: () => { mocks.activeCompany = company({ test_workspace_purpose: 'backup_snapshot' }); } },
    { label: 'explicitly read-only ordinary client', setup: () => { mocks.activeCompany = company({ test_workspace: false, payroll_environment: 'live', test_workspace_read_only: true }); } },
    { label: 'ordinary staff without configuration capability', setup: () => { mocks.activeCompany = company({ test_workspace: false, payroll_environment: 'live' }); mocks.capabilities = ['payroll_operations']; } },
    { label: 'loading auth', setup: () => { mocks.authLoading = true; } },
    { label: 'loading company', setup: () => { mocks.companyLoading = true; } },
    { label: 'missing company', setup: () => { mocks.activeCompany = null; } },
    { label: 'missing selected company ID', setup: () => { mocks.activeCompanyId = null; } },
    { label: 'mismatched company', setup: () => { mocks.activeCompany = company({ id: 9 }); } },
  ])('fails closed for $label while retaining read access', async ({ setup }) => {
    setup();
    await openPage();
    assertReadOnly();
    expect(mocks.get).toHaveBeenCalledTimes(1);
    expect(mocks.update).not.toHaveBeenCalled();
  });

  it.each(['workspace administrator', 'ordinary live manager'])('preserves an authorized %s combined schedule/workweek save', async (kind) => {
    if (kind === 'ordinary live manager') mocks.activeCompany = company({ test_workspace: false, payroll_environment: 'live', workspace_can_write: undefined, workspace_write_permissions: undefined });
    const user = userEvent.setup();
    await openPage();
    expect(screen.queryByText('Read-only schedule.')).toBeNull();
    expect(screen.getByLabelText('Pay frequency').matches(':disabled')).toBe(false);
    expect(screen.getByLabelText('Start time (Guam)').matches(':disabled')).toBe(true);
    change('Effective date', '2099-02-01');
    change('Pay frequency', 'weekly');
    change('Period boundary rule', 'weekly');
    change('Days after period end', '3');
    change('Time-tracking lock', 'after_previous_regular_payday');
    change('Calendar days after', '2');
    change('Lock time (Guam)', '16:30');
    change('Workweek starts on', '3');
    change('Confirmation source / notes', 'Confirmed revised employer agreement');
    await user.click(screen.getByRole('button', { name: 'Confirm & save schedule' }));
    await screen.findByText('The new effective-dated schedule and legal workweek are confirmed. Existing payroll runs were not changed.');
    expect(mocks.update).toHaveBeenCalledExactlyOnceWith({
      effective_on: '2099-02-01',
      pay_schedule: {
        frequency: 'weekly', period_rule: 'weekly', period_start_weekday: 1, period_anchor_date: null,
        pay_date_rule: 'days_after_period_end', pay_date_offset_days: 3, payroll_cutoff_days_before: 7,
        time_tracking_cutoff_rule: 'after_previous_regular_payday', time_tracking_cutoff_days: 2,
        payroll_cutoff_at_minutes: 990, timezone: 'Pacific/Guam', notes: 'Confirmed revised employer agreement',
      },
      workweek: { starts_on_weekday: 3, starts_at_minutes: 0, timezone: 'Pacific/Guam', notes: 'Confirmed revised employer agreement' },
    });
  });

  it('preserves the same-company draft through permission loss and restoration without reloading or auto-saving', async () => {
    const user = userEvent.setup();
    const view = await openPage();
    change('Effective date', '2099-02-01');
    change('Confirmation source / notes', 'Retained confirmation draft');
    change('Lock time (Guam)', '16:30');
    change('Workweek starts on', '3');
    mocks.activeCompany = company({ workspace_write_permissions: { payroll_operations: true, manage_client_configuration: false } });
    view.rerender(<PayScheduleSettings />);
    assertReadOnly();
    expect((screen.getByLabelText('Effective date') as HTMLInputElement).value).toBe('2099-02-01');
    expect((screen.getByLabelText('Confirmation source / notes') as HTMLTextAreaElement).value).toBe('Retained confirmation draft');
    expect((screen.getByLabelText('Lock time (Guam)') as HTMLInputElement).value).toBe('16:30');
    expect((screen.getByLabelText('Workweek starts on') as HTMLSelectElement).value).toBe('3');
    expect(mocks.get).toHaveBeenCalledTimes(1);
    expect(mocks.update).not.toHaveBeenCalled();
    mocks.activeCompany = company();
    view.rerender(<PayScheduleSettings />);
    expect(screen.getByRole('button', { name: 'Confirm & save schedule' }).matches(':disabled')).toBe(false);
    expect(mocks.update).not.toHaveBeenCalled();
    await user.click(screen.getByRole('button', { name: 'Confirm & save schedule' }));
    await waitFor(() => expect(mocks.update).toHaveBeenCalledTimes(1));
    expect(mocks.update.mock.calls[0][0]).toMatchObject({ effective_on: '2099-02-01', pay_schedule: { notes: 'Retained confirmation draft', payroll_cutoff_at_minutes: 990 }, workweek: { starts_on_weekday: 3 } });
    expect(mocks.get).toHaveBeenCalledTimes(1);
  });

  it.each([403, 422])('retains rejected draft and permits a deliberate retry after server%s', async (status) => {
    mocks.update.mockRejectedValueOnce(Object.assign(new Error(`Server ${status}: review schedule access or inputs`), { status }));
    const user = userEvent.setup();
    await openPage();
    change('Confirmation source / notes', 'Draft retained after server rejection');
    change('Lock time (Guam)', '16:30');
    await user.click(screen.getByRole('button', { name: 'Confirm & save schedule' }));
    await screen.findByText(`Server ${status}: review schedule access or inputs`);
    expect((screen.getByLabelText('Confirmation source / notes') as HTMLTextAreaElement).value).toBe('Draft retained after server rejection');
    expect((screen.getByLabelText('Lock time (Guam)') as HTMLInputElement).value).toBe('16:30');
    expect(screen.getByRole('button', { name: 'Confirm & save schedule' }).matches(':disabled')).toBe(false);
    await user.click(screen.getByRole('button', { name: 'Confirm & save schedule' }));
    await waitFor(() => expect(mocks.update).toHaveBeenCalledTimes(2));
    expect(mocks.update.mock.calls[1][0]).toEqual(mocks.update.mock.calls[0][0]);
  });

  it('blocks duplicate saving and edits while the one combined request is pending', async () => {
    let finish!: (response: PayScheduleSettingsResponse) => void;
    mocks.update.mockReturnValueOnce(new Promise((resolve) => { finish = resolve; }));
    const user = userEvent.setup();
    await openPage();
    await user.dblClick(screen.getByRole('button', { name: 'Confirm & save schedule' }));
    expect(mocks.update).toHaveBeenCalledTimes(1);
    expect(screen.getByRole('button', { name: 'Saving…' }).matches(':disabled')).toBe(true);
    expect(screen.getByRole('button', { name: 'Cancel' }).matches(':disabled')).toBe(true);
    expect(screen.getByLabelText('Confirmation source / notes').matches(':disabled')).toBe(true);
    await act(async () => { finish(savedSettings(mocks.update.mock.calls[0][0])); });
    expect(screen.getByRole('button', { name: 'Confirm & save schedule' }).matches(':disabled')).toBe(false);
  });

  it.each([
    { label: 'short confirmation note', field: 'Confirmation source / notes', value: '', message: 'Add a short confirmation note identifying who confirmed the schedule or what source was used.' },
    { label: 'missing biweekly anchor', field: 'Known period start date', value: '', message: 'Choose the first day of a known biweekly pay period so alternating weeks stay aligned.' },
    { label: 'wrong anchor weekday', field: 'Known period start date', value: '2026-01-06', message: 'The biweekly anchor must fall on Monday.' },
    { label: 'invalid cutoff clock', field: 'Lock time (Guam)', value: '', message: 'Choose a valid Guam payroll cutoff time.' },
    { label: 'invalid cutoff interval', field: 'Calendar days before', value: '32', message: 'Choose a time-tracking cutoff between zero and 31 calendar days.' },
  ])('keeps existing validation for $label', async ({ field, value, message }) => {
    await openPage();
    change(field, value);
    fireEvent.click(screen.getByRole('button', { name: 'Confirm & save schedule' }));
    expect(screen.getByText(message)).toBeTruthy();
    expect(mocks.update).not.toHaveBeenCalled();
  });
});
