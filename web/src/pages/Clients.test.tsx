// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { Clients } from './Clients';
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

afterEach(() => cleanup());

describe('Clients migration promotion', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.auth = { isAdmin: true, isAccountant: false, isManager: false };
    apiMocks.list.mockResolvedValue({ companies: [target, rehearsal] });
    refreshCompanies.mockResolvedValue(undefined);
  });

  it('uses one guided entry point for test workspace creation', async () => {
    const user = userEvent.setup();
    apiMocks.trainingReplayPreview.mockResolvedValue({
      training_replay: {
        source_company: { id: target.id, name: target.name },
        ready: true,
        blockers: [],
        warnings: [],
        existing_replay: null,
        practice_periods: [
          { id: 61, start_date: '2026-08-24', end_date: '2026-09-06', pay_date: '2026-09-10', status: 'committed', employee_count: 57 },
          { id: 62, start_date: '2026-09-07', end_date: '2026-09-20', pay_date: '2026-09-24', status: 'committed', employee_count: 57 },
        ],
        copy_summary: { employees: 114, active_employees: 57, baseline_pay_periods: 18, practice_pay_periods: 2 },
        assignable_staff: [{ id: 4, name: 'Training Accountant', email: 'training@example.com', role: 'accountant' }],
      },
    });

    render(<Clients />);

    const createWorkspace = await screen.findByRole('button', { name: 'Create test workspace' });
    expect(screen.queryByRole('button', { name: 'Migration test' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Training replay' })).toBeNull();

    await user.click(createWorkspace);
    await user.selectOptions(screen.getByLabelText('Choose a production client'), String(target.id));
    await user.click(screen.getByRole('button', { name: /Practice completed payrolls/i }));

    await waitFor(() => expect(apiMocks.trainingReplayPreview).toHaveBeenCalledWith(target.id));
    expect(await screen.findByText('Access levels')).toBeTruthy();
    expect(screen.getByText('Operator')).toBeTruthy();
    expect(screen.getByText('Reviewer')).toBeTruthy();
    expect(screen.getByText('Workspace admin')).toBeTruthy();
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

  it('guides an admin through the backup gate before live application', async () => {
    const user = userEvent.setup();
    apiMocks.migrationPromotionPreview.mockResolvedValue({
      migration_promotion: { ...basePreview, ready_to_back_up: true, ready_to_apply: false },
    });
    apiMocks.createMigrationPromotionBackup.mockResolvedValue({ company: { id: 8 } });

    render(<Clients />);
    await user.click((await screen.findAllByRole('button', { name: /promote rehearsal/i }))[0]);

    expect(await screen.findByText('Move rehearsal results to the clean client')).toBeTruthy();
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
    await user.click(screen.getByRole('checkbox'));
    await user.click(screen.getByRole('button', { name: /apply to clean client/i }));

    await waitFor(() => expect(apiMocks.applyMigrationPromotion).toHaveBeenCalledWith(7, 'APPLY REHEARSAL TO LIVE CLIENT'));
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
