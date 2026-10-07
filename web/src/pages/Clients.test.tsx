// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { Clients } from './Clients';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import type { MigrationPromotionPreview } from '@/services/api';

const apiMocks = vi.hoisted(() => ({
  list: vi.fn(),
  get: vi.fn(),
  create: vi.fn(),
  update: vi.fn(),
  migrationPromotionPreview: vi.fn(),
  createMigrationPromotionBackup: vi.fn(),
  applyMigrationPromotion: vi.fn(),
  migrationRehearsalPreview: vi.fn(),
  createMigrationRehearsal: vi.fn(),
  retryMigrationRehearsal: vi.fn(),
  trainingReplayPreview: vi.fn(),
  createTrainingReplay: vi.fn(),
  retryTrainingReplay: vi.fn(),
  testWorkspacePreview: vi.fn(),
  createTestWorkspace: vi.fn(),
  retryTestWorkspace: vi.fn(),
  archiveTestWorkspace: vi.fn(),
  restoreTestWorkspace: vi.fn(),
  auth: { isAdmin: true, isAccountant: false, isManager: false },
}));

const refreshCompanies = vi.fn();

vi.mock('react-router', () => ({ useNavigate: () => vi.fn() }));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ refreshCompanies, switchCompany: vi.fn() }),
}));
vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => apiMocks.auth,
}));
vi.mock('@/services/api', () => ({
  companiesApi: apiMocks,
  ApiError: class ApiError extends Error {},
}));

const target = {
  id: 6,
  name: "MoSa's Hotbox, Inc. — Clean Migration",
  active: true,
  active_employees: 57,
  total_employees: 114,
  pay_frequency: 'biweekly',
  historical_payroll_enabled: true,
  payroll_environment: 'live' as const,
};

const rehearsal = {
  id: 7,
  name: "MoSa's Migration Test",
  active: true,
  active_employees: 58,
  total_employees: 58,
  pay_frequency: 'biweekly',
  historical_payroll_enabled: true,
  payroll_environment: 'migration_rehearsal' as const,
  test_workspace: true,
  test_workspace_purpose: 'migration_rehearsal' as const,
  test_workspace_purpose_label: 'Migration rehearsal',
  migration_rehearsal_status: 'ready' as const,
  migration_source_company_id: 6,
  migration_source_company_name: target.name,
  test_workspace_manifest: {},
};

const basePreview: Omit<MigrationPromotionPreview, 'ready_to_back_up' | 'ready_to_apply'> = {
  rehearsal: { id: 7, name: rehearsal.name, status: 'ready' as const, employee_count: 58 },
  target_company: { id: 6, name: target.name, status: null, employee_count: 114 },
  blockers: ['Create and verify a read-only backup before applying rehearsal data'],
  warnings: [],
  employee_mapping: { matched: 57, new: 1, blockers: [] },
  source_periods: [
    { id: 70, start_date: '2026-08-24', end_date: '2026-09-06', pay_date: '2026-09-10', status: 'calculated' as const, employee_count: 58, gross_pay: '74292.10', net_pay: '53209.87' },
    { id: 71, start_date: '2026-09-07', end_date: '2026-09-20', pay_date: '2026-09-24', status: 'approved' as const, employee_count: 58, gross_pay: '73251.36', net_pay: '53557.65' },
  ],
  replaceable_drafts: [
    { id: 60, start_date: '2026-08-24', end_date: '2026-09-06', pay_date: '2026-09-10', status: 'draft' as const, employee_count: 0, gross_pay: 0, net_pay: 0 },
  ],
  backup: null,
};

const generalWorkspacePreview = {
  source_company: { id: target.id, name: target.name },
  ready: true,
  blockers: [],
  warnings: ['The production client stays unchanged.'],
  copy_mode: 'all_committed' as const,
  excluded_payrolls: 0,
  cutoff_pay_period_id: null,
  copy_summary: {
    employees: 114,
    active_employees: 57,
    committed_payrolls_available: 20,
    payrolls_to_copy: 20,
    recent_payrolls_excluded: 0,
    open_payrolls_not_copied: 1,
    other_open_payrolls_not_copied: 1,
  },
  recent_payrolls: [
    { id: 62, start_date: '2026-09-07', end_date: '2026-09-20', pay_date: '2026-09-24', status: 'calculated' as const, employee_count: 57 },
    { id: 61, start_date: '2026-08-24', end_date: '2026-09-06', pay_date: '2026-09-10', status: 'committed' as const, employee_count: 57 },
  ],
  assignable_staff: [{ id: 4, name: 'Training Accountant', email: 'training@example.com', role: 'accountant' as const }],
};

afterEach(() => cleanup());

describe('Clients migration promotion', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.auth = { isAdmin: true, isAccountant: false, isManager: false };
    apiMocks.list.mockResolvedValue({ companies: [target, rehearsal] });
    apiMocks.testWorkspacePreview.mockResolvedValue({ test_workspace: generalWorkspacePreview });
    refreshCompanies.mockResolvedValue(undefined);
  });

  it('uses one guided entry point for test workspace creation', async () => {
    const user = userEvent.setup();
    render(<Clients />);

    const createWorkspace = await screen.findByRole('button', { name: 'Create test workspace' });
    expect(screen.queryByRole('button', { name: 'Migration test' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Training replay' })).toBeNull();

    await user.click(createWorkspace);
    await user.selectOptions(screen.getByLabelText('Production client'), String(target.id));

    await waitFor(() => expect(apiMocks.testWorkspacePreview).toHaveBeenCalledWith(target.id, expect.objectContaining({ copy_mode: 'all_committed' })));
    expect(await screen.findByText('Setup + committed payroll history')).toBeTruthy();
    expect(screen.getByText('Leave out the latest payrolls')).toBeTruthy();
    expect(await screen.findByText('Access levels')).toBeTruthy();
    expect(screen.getByText('Operator')).toBeTruthy();
    expect(screen.getByText('Reviewer')).toBeTruthy();
    expect(screen.getByText('Workspace admin')).toBeTruthy();
  });

  it('creates an unstructured workspace that leaves the latest two payrolls out', async () => {
    const user = userEvent.setup();
    apiMocks.createTestWorkspace.mockResolvedValue({ company: { id: 20 } });
    render(<Clients />);

    await user.click(await screen.findByRole('button', { name: 'Create test workspace' }));
    await user.selectOptions(screen.getByLabelText('Production client'), String(target.id));
    await screen.findByText('Setup + committed payroll history');
    await user.click(screen.getByRole('radio', { name: /Leave out the latest payrolls/i }));
    await user.click(screen.getByRole('checkbox', { name: /Training Accountant/i }));
    await user.click(screen.getByRole('checkbox', { name: /I understand this copy contains protected/i }));
    await user.click(screen.getAllByRole('button', { name: 'Create test workspace' }).at(-1)!);

    await waitFor(() => expect(apiMocks.createTestWorkspace).toHaveBeenCalledWith(target.id, expect.objectContaining({
      copy_mode: 'exclude_recent',
      excluded_payrolls: 2,
      expiration_days: 90,
      acknowledgement: 'CREATE TEST WORKSPACE',
      assignments: [{ user_id: 4, workspace_access_level: 'operator' }],
    })));
  });

  it('offers every supported recent-payroll exclusion count', async () => {
    const user = userEvent.setup();
    render(<Clients />);

    await user.click(await screen.findByRole('button', { name: 'Create test workspace' }));
    await user.selectOptions(screen.getByLabelText('Production client'), String(target.id));
    await screen.findByText('Setup + committed payroll history');
    await user.click(screen.getByRole('radio', { name: /Leave out the latest payrolls/i }));

    const selector = screen.getByLabelText('Recent payrolls to leave out');
    expect(within(selector).getByRole('option', { name: '1 payroll' })).toBeTruthy();
    expect(within(selector).getByRole('option', { name: '12 payrolls' })).toBeTruthy();
  });

  it('disables creation while a changed copy option is being previewed', async () => {
    const user = userEvent.setup();
    render(<Clients />);

    await user.click(await screen.findByRole('button', { name: 'Create test workspace' }));
    await user.selectOptions(screen.getByLabelText('Production client'), String(target.id));
    await screen.findByText('Setup + committed payroll history');
    await user.click(screen.getByRole('checkbox', { name: /I understand this copy contains protected/i }));
    expect((screen.getAllByRole('button', { name: 'Create test workspace' }).at(-1) as HTMLButtonElement).disabled).toBe(false);

    apiMocks.testWorkspacePreview.mockImplementationOnce(() => new Promise(() => undefined));
    await user.click(screen.getByRole('radio', { name: /Leave out the latest payrolls/i }));

    expect(await screen.findByText('Checking what will be copied…')).toBeTruthy();
    expect((screen.getAllByRole('button', { name: 'Create test workspace' }).at(-1) as HTMLButtonElement).disabled).toBe(true);
  });

  it('routes the guided migration choice into the rehearsal preview', async () => {
    const user = userEvent.setup();
    apiMocks.migrationRehearsalPreview.mockResolvedValue({
      migration_rehearsal: {
        source_company: { id: target.id, name: target.name },
        historical_import_batch_id: 12,
        ready: true,
        blockers: [],
        warnings: ['The live client remains unchanged.'],
        existing_rehearsal: null,
        copy_summary: {
          employees: 114,
          active_employees: 57,
          imported_pay_periods: 2,
          imported_paychecks: 114,
          retained_source_files: 3,
          source_file_bytes: 4096,
        },
      },
    });

    render(<Clients />);

    await user.click(await screen.findByRole('button', { name: 'Create test workspace' }));
    await user.selectOptions(screen.getByLabelText('Production client'), String(target.id));
    await screen.findByText('Setup + committed payroll history');
    await user.click(screen.getByRole('button', { name: /Need an exact migration rehearsal/i }));

    await waitFor(() => expect(apiMocks.migrationRehearsalPreview).toHaveBeenCalledWith(target.id));
    expect(await screen.findByRole('heading', { name: 'Create a migration rehearsal' })).toBeTruthy();
    expect(screen.queryByRole('heading', { name: 'Create a test workspace' })).toBeNull();
  });

  it('explains workspace types and statuses in the expandable guide', async () => {
    const user = userEvent.setup();
    render(<Clients />);

    await user.click(await screen.findByText('Test workspace guide'));
    expect(screen.getByText('Production client')).toBeTruthy();
    expect(screen.getByText('Read-only backup')).toBeTruthy();
    expect(screen.getByText('Preparing')).toBeTruthy();
    expect(screen.getByText('Needs attention')).toBeTruthy();
  });

  it('keeps test-workspace creation and its admin guide out of accountant access', async () => {
    apiMocks.auth = { isAdmin: false, isAccountant: true, isManager: false };
    apiMocks.list.mockResolvedValue({ companies: [target] });

    render(<Clients />);

    expect((await screen.findAllByRole('button', { name: 'Edit' })).length).toBeGreaterThan(0);
    expect(screen.queryByRole('button', { name: 'Create test workspace' })).toBeNull();
    expect(screen.queryByText('Test workspace guide')).toBeNull();
  });

  it('explains why test-workspace creation is unavailable without a production client', async () => {
    apiMocks.list.mockResolvedValue({ companies: [rehearsal] });

    render(<Clients />);

    const createWorkspace = await screen.findByRole('button', { name: 'Create test workspace' });
    expect((createWorkspace as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText('Add a production client before creating a test workspace.')).toBeTruthy();
  });

  it('closes the workspace builder before opening client editing', async () => {
    const user = userEvent.setup();
    apiMocks.get.mockResolvedValue({ company: target });
    render(<Clients />);

    await user.click(await screen.findByRole('button', { name: 'Create test workspace' }));
    expect(screen.getByRole('heading', { name: 'Create a test workspace' })).toBeTruthy();
    await user.click((await screen.findAllByRole('button', { name: 'Edit' }))[0]);

    expect(await screen.findByRole('heading', { name: 'Edit Client' })).toBeTruthy();
    expect(screen.queryByRole('heading', { name: 'Create a test workspace' })).toBeNull();
  });

  it('closes an open workspace preview before editing a client', async () => {
    const user = userEvent.setup();
    apiMocks.get.mockResolvedValue({ company: target });
    apiMocks.migrationRehearsalPreview.mockResolvedValue({
      migration_rehearsal: {
        source_company: { id: target.id, name: target.name },
        historical_import_batch_id: 12,
        ready: true,
        blockers: [],
        warnings: [],
        existing_rehearsal: null,
        copy_summary: { employees: 114, imported_pay_periods: 2 },
      },
    });
    render(<Clients />);

    await user.click(await screen.findByRole('button', { name: 'Create test workspace' }));
    await user.selectOptions(screen.getByLabelText('Production client'), String(target.id));
    await screen.findByText('Setup + committed payroll history');
    await user.click(screen.getByRole('button', { name: /Need an exact migration rehearsal/i }));
    expect(await screen.findByRole('heading', { name: 'Create a migration rehearsal' })).toBeTruthy();

    await user.click((await screen.findAllByRole('button', { name: 'Edit' }))[0]);
    expect(await screen.findByRole('heading', { name: 'Edit Client' })).toBeTruthy();
    expect(screen.queryByRole('heading', { name: 'Create a migration rehearsal' })).toBeNull();
  });

  it('guides an admin through the backup gate before live application', async () => {
    const user = userEvent.setup();
    apiMocks.migrationPromotionPreview.mockResolvedValue({
      migration_promotion: { ...basePreview, ready_to_back_up: true, ready_to_apply: false },
    });
    apiMocks.createMigrationPromotionBackup.mockResolvedValue({ company: { id: 8 } });

    render(<Clients />);
    await user.click(await screen.findByRole('button', { name: 'Create test workspace' }));
    expect(screen.getByRole('heading', { name: 'Create a test workspace' })).toBeTruthy();
    await user.click((await screen.findAllByRole('button', { name: /promote rehearsal/i }))[0]);

    expect(await screen.findByText('Move rehearsal results to the clean client')).toBeTruthy();
    expect(screen.queryByRole('heading', { name: 'Create a test workspace' })).toBeNull();
    expect(screen.getAllByText('57').length).toBeGreaterThan(0);
    const newEmployeeSummary = screen.getByText('New employees to add').parentElement;
    expect(newEmployeeSummary).not.toBeNull();
    expect(within(newEmployeeSummary as HTMLElement).getByText('1')).toBeTruthy();
    expect(screen.getByText('$74,292.10')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /apply to clean client/i })).toBeNull();

    await user.click(screen.getByRole('checkbox'));
    await user.click(screen.getByRole('button', { name: /create read-only backup/i }));

    expect(apiMocks.createMigrationPromotionBackup).toHaveBeenCalledWith(7, 'CREATE READ-ONLY BACKUP');
  });

  it('uses a second explicit confirmation to apply a current verified backup', async () => {
    const user = userEvent.setup();
    apiMocks.migrationPromotionPreview.mockResolvedValue({
      migration_promotion: {
        ...basePreview,
        ready_to_back_up: false,
        ready_to_apply: true,
        blockers: [],
        backup: { id: 8, name: 'Clean Migration — Backup', status: 'ready', employee_count: 114, current: true },
      },
    });
    apiMocks.applyMigrationPromotion.mockResolvedValue({
      company: target,
      promoted_pay_period_ids: [80, 81],
    });

    render(<Clients />);
    await user.click((await screen.findAllByRole('button', { name: /promote rehearsal/i }))[0]);
    await screen.findByText(/is verified and read only/i);
    expect(screen.getByText(/Choose a payment status for every payroll/)).toBeTruthy();
    expect((screen.getByRole('button', { name: /apply to clean client/i }) as HTMLButtonElement).disabled).toBe(true);
    const recordOnlyChoices = screen.getAllByRole('radio', { name: /Already paid elsewhere/i });
    const processChoices = screen.getAllByRole('radio', { name: /Unpaid — process in Cornerstone/i });
    await user.click(recordOnlyChoices[0]);
    await user.click(processChoices[1]);
    await user.click(screen.getByRole('checkbox'));
    await user.click(screen.getByRole('button', { name: /apply to clean client/i }));

    await waitFor(() => expect(apiMocks.applyMigrationPromotion).toHaveBeenCalledWith(
      7,
      'APPLY REHEARSAL TO LIVE CLIENT',
      { 70: 'record_only', 71: 'process_in_cornerstone' },
    ));
    expect(await screen.findByText(/now has the verified rehearsal setup and both migrated payrolls/i)).toBeTruthy();
  });

  it('presents a sealed rehearsal as read-only and does not offer promotion again', async () => {
    apiMocks.list.mockResolvedValue({
      companies: [
        target,
        {
          ...rehearsal,
          test_workspace_sealed_at: '2026-09-22T07:30:00Z',
          test_workspace_manifest: {},
        },
      ],
    });

    render(<Clients />);

    expect((await screen.findAllByRole('button', { name: /open read-only/i })).length).toBeGreaterThan(0);
    expect(screen.queryByRole('button', { name: /promote rehearsal/i })).toBeNull();
  });
});


describe('Clients name-only rename', () => {
  afterEach(() => vi.restoreAllMocks());
  beforeEach(() => {
    vi.clearAllMocks();
    // jsdom reports no rendered offsetParent; finish dialog focus before typing.
    vi.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => { callback(0); return 0; });
    apiMocks.auth = { isAdmin: true, isAccountant: false, isManager: false };
    apiMocks.list.mockResolvedValue({ companies: [target] });
    apiMocks.update.mockResolvedValue({ company: target });
    refreshCompanies.mockResolvedValue(undefined);
  });
  const renderClients = () => render(<FeedbackProvider scopeKey="rename-test"><Clients /></FeedbackProvider>);
  const openRename = async (user: ReturnType<typeof userEvent.setup>) => {
    const actions = await screen.findAllByRole('button', { name: `Rename ${target.name}` });
    expect(actions).toHaveLength(2); // Mobile card and desktop table.
    await user.click(actions[0]);
    return screen.getByRole('dialog', { name: 'Rename client' });
  };
  const changeName = async (user: ReturnType<typeof userEvent.setup>, dialog: HTMLElement, name = 'Updated employer') => {
    await user.clear(within(dialog).getByLabelText('Client name'));
    await user.type(within(dialog).getByLabelText('Client name'), name);
    await user.click(within(dialog).getByRole('button', { name: 'Save client name' }));
  };

  it('saves only a trimmed name and publishes success before refresh completes', async () => {
    const user = userEvent.setup();
    let resolveRefresh!: () => void;
    refreshCompanies.mockImplementation(() => new Promise<void>(resolve => { resolveRefresh = resolve; }));
    renderClients();
    const dialog = await openRename(user);
    expect((within(dialog).getByLabelText('Client name') as HTMLInputElement).value).toBe(target.name);
    await changeName(user, dialog, "  MoSa's Hotbox, Inc.  ");
    await waitFor(() => expect(apiMocks.update).toHaveBeenCalledWith(6, { name: "MoSa's Hotbox, Inc." }));
    expect(apiMocks.update).toHaveBeenCalledTimes(1);
    expect(await screen.findByText('Client name updated.')).toBeTruthy();
    expect(screen.queryByRole('dialog', { name: 'Rename client' })).toBeNull();
    resolveRefresh();
  });

  it('rejects blank names and closes unchanged names without a request', async () => {
    const user = userEvent.setup();
    renderClients();
    let dialog = await openRename(user);
    await changeName(user, dialog, '   ');
    expect(await screen.findByText('Enter a client name. This name appears on reports and earnings statements.')).toBeTruthy();
    expect(apiMocks.update).not.toHaveBeenCalled();
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }));
    dialog = await openRename(user);
    await user.click(within(dialog).getByRole('button', { name: 'Save client name' }));
    expect(apiMocks.update).not.toHaveBeenCalled();
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('keeps failed saves available without reporting success', async () => {
    const user = userEvent.setup();
    apiMocks.update.mockRejectedValue(new Error('Client name cannot be saved.'));
    renderClients();
    await changeName(user, await openRename(user));
    expect(await screen.findByText('Client name cannot be saved.')).toBeTruthy();
    expect(screen.getByRole('dialog')).toBeTruthy();
    expect(screen.queryByText('Client name updated.')).toBeNull();
    expect(refreshCompanies).not.toHaveBeenCalled();
  });

  it('warns about failed refresh separately from the successful save', async () => {
    const user = userEvent.setup();
    renderClients();
    const dialog = await openRename(user);
    apiMocks.list.mockRejectedValueOnce(new Error('List unavailable'));
    await changeName(user, dialog);
    expect(await screen.findByText('Client name updated.')).toBeTruthy();
    expect(await screen.findByText('The client name was saved, but the client list could not fully refresh. Refresh the page before opening a report.')).toBeTruthy();
    expect(screen.getAllByText('Updated employer')).toHaveLength(2);
    expect(apiMocks.update).toHaveBeenCalledTimes(1);
  });

  it('blocks duplicate submission and dismissal during save', async () => {
    const user = userEvent.setup();
    let resolveSave!: () => void;
    apiMocks.update.mockImplementation(() => new Promise<void>(resolve => { resolveSave = resolve; }));
    renderClients();
    const dialog = await openRename(user);
    await changeName(user, dialog);
    expect((within(dialog).getByRole('button', { name: 'Saving…' }) as HTMLButtonElement).disabled).toBe(true);
    expect((within(dialog).getByRole('button', { name: 'Cancel' }) as HTMLButtonElement).disabled).toBe(true);
    await user.keyboard('{Escape}');
    expect(screen.getByRole('dialog')).toBeTruthy();
    expect(apiMocks.update).toHaveBeenCalledTimes(1);
    resolveSave();
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  });

  it('ignores pending save after unmount', async () => {
    const user = userEvent.setup();
    let resolveSave!: () => void;
    apiMocks.update.mockImplementation(() => new Promise<void>(resolve => { resolveSave = resolve; }));
    const rendered = renderClients();
    await changeName(user, await openRename(user));
    rendered.unmount();
    resolveSave();
    await new Promise(resolve => setTimeout(resolve, 0));
    expect(refreshCompanies).not.toHaveBeenCalled();
    expect(apiMocks.list).toHaveBeenCalledTimes(1);
  });

  it('ignores completion after the admin scope changes', async () => {
    const user = userEvent.setup();
    let resolveSave!: () => void;
    apiMocks.update.mockImplementation(() => new Promise<void>(resolve => { resolveSave = resolve; }));
    const rendered = renderClients();
    await changeName(user, await openRename(user));
    apiMocks.auth = { isAdmin: false, isAccountant: true, isManager: false };
    rendered.rerender(<FeedbackProvider scopeKey="rename-test"><Clients /></FeedbackProvider>);
    resolveSave();
    await new Promise(resolve => setTimeout(resolve, 0));
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(screen.queryByText('Client name updated.')).toBeNull();
    expect(refreshCompanies).not.toHaveBeenCalled();
    expect(apiMocks.list).toHaveBeenCalledTimes(1);
  });

  it('hides rename from non-admin staff and read-only workspaces', async () => {
    apiMocks.auth = { isAdmin: false, isAccountant: true, isManager: false };
    const rendered = renderClients();
    await screen.findAllByText(target.name);
    expect(screen.queryByRole('button', { name: `Rename ${target.name}` })).toBeNull();
    rendered.unmount();
    apiMocks.auth = { isAdmin: true, isAccountant: false, isManager: false };
    apiMocks.list.mockResolvedValue({ companies: [{ ...rehearsal, test_workspace_sealed_at: '2026-10-07T00:00:00Z' }] });
    renderClients();
    await screen.findAllByText(rehearsal.name);
    expect(screen.queryByRole('button', { name: `Rename ${rehearsal.name}` })).toBeNull();
  });
});
