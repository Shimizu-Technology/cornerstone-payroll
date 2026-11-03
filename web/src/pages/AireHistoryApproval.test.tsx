// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AireHistoryApproval } from './AireHistoryApproval';

const mocks = vi.hoisted(() => ({ preview: vi.fn(), approve: vi.fn(), list: vi.fn(), companyId: 2, role: 'accountant' }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: mocks.companyId }) }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 7, role: mocks.role } }) }));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title }: { title: string }) => <h1>{title}</h1> }));
vi.mock('@/services/api', () => ({ timeTrackingSourcesApi: { list: mocks.list } }));
vi.mock('@/services/aireHistoryApproval', () => ({ aireHistoryApprovalApi: { preview: mocks.preview, approve: mocks.approve } }));

const entry = { id: '1804', employee: 'Source person', work_date: '2026-08-14', hours: '4.25', category: 'Maintenance', approval_status: 'approved', disposition: 'owed' };
const summary = () => ({
  review_id: 5, digest: 'a'.repeat(64), source_name: 'AIRE', through_work_date: '2026-10-31', attestation: 'I reviewed this exact accounting history.',
  approved_at: null, approved_by: null, history_coverage_verified: true, blockers: [],
  mappings: [{ source_user_uuid: 'uuid-1', source_name: 'Source person', employee_id: 8, employee_name: 'Payroll person', existing: true, confirmation_required: false, options: [{ id: 8, name: 'Payroll person' }] }],
  dispositions: [{ type: 'historical_baseline', label: 'Already represented in manual payroll', count: 134, hours: '599.06' }],
  rounding_variances: [{ employee: 'Payroll person', employee_id: 8, run_id: 61, category: 'OT', source_category: { name: 'Ground' }, source_total: '20.57', paid_total: '20.60', signed_difference: '0.03', within_limit: true }],
  owed: [entry], pending_review: [{ ...entry, id: '42', hours: '2.5', approval_status: null, disposition: 'pending_review' }],
  solo_decisions: [{ employee_id: 8, employee: 'Payroll person', hours: '7.70', options: [{ id: 9, label: 'Approved client earning', rate: '12.5' }] }],
});

beforeEach(() => {
  vi.clearAllMocks(); mocks.companyId = 2; mocks.role = 'accountant';
  mocks.list.mockResolvedValue({ time_tracking_sources: [{ id: 1, active: true, source_type: 'aire_services' }] });
  mocks.preview.mockResolvedValue(summary());
  mocks.approve.mockResolvedValue({ ...summary(), approved_at: '2026-11-03T03:00:00Z', approved_by: 'Chels' });
});
afterEach(cleanup);
const view = () => render(<MemoryRouter><AireHistoryApproval /></MemoryRouter>);

describe('one-summary AIRE history approval', () => {
  it('shows truthful counts, rounding, owed 1804, pending work and an open Solo decision', async () => {
    view();
    expect(await screen.findByText('599.06')).toBeTruthy();
    expect(screen.getByText('+0.03')).toBeTruthy();
    expect(screen.getByText('1804')).toBeTruthy();
    expect(screen.getByText('Undetermined')).toBeTruthy();
    expect((screen.getByRole('option', { name: /Decision still open/ }) as HTMLOptionElement).selected).toBe(true);
    expect(screen.getByRole('button', { name: 'Approve history' }).hasAttribute('disabled')).toBe(true);
    expect(mocks.preview).toHaveBeenCalledWith(1, 2, [], expect.anything());
  });

  it('uses one attestation and one approval, and leaves Solo open without blocking history', async () => {
    const user = userEvent.setup(); view();
    await user.click(await screen.findByRole('checkbox', { name: /I reviewed/ }));
    await user.click(screen.getByRole('button', { name: 'Approve history' }));
    expect(mocks.approve).toHaveBeenCalledOnce();
    expect(mocks.approve).toHaveBeenCalledWith(1, 2, { review_id: 5, digest: 'a'.repeat(64), attestation: summary().attestation, confirmed_mapping_uuids: [], solo_choices: [] }, expect.anything());
    expect(await screen.findByText('History approved')).toBeTruthy();
    expect(screen.getByText(/no calendar was published/)).toBeTruthy();
  });

  it('requires explicit confirmation of a nonexact employee match', async () => {
    const page = summary(); page.mappings[0].existing = false; page.mappings[0].confirmation_required = true;
    mocks.preview.mockResolvedValue(page);
    const user = userEvent.setup(); view();
    await user.click(await screen.findByRole('checkbox', { name: /I reviewed/ }));
    expect(screen.getByRole('button', { name: 'Approve history' }).hasAttribute('disabled')).toBe(true);
    await user.click(screen.getByRole('checkbox', { name: /I confirm Source person/ }));
    await user.click(screen.getByRole('button', { name: 'Approve history' }));
    expect(mocks.approve.mock.calls[0][2].confirmed_mapping_uuids).toEqual(['uuid-1']);
  });

  it('shows exactly what changed, clears the attestation and requires refresh after failure', async () => {
    mocks.approve.mockRejectedValue(new Error('History changed: AIRE entries 42 changed. Nothing was applied.'));
    const user = userEvent.setup(); view();
    await user.click(await screen.findByRole('checkbox', { name: /I reviewed/ }));
    await user.click(screen.getByRole('button', { name: 'Approve history' }));
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('AIRE entries 42 changed'));
    expect(screen.getByRole('button', { name: 'Approve history' }).hasAttribute('disabled')).toBe(true);
    expect(screen.queryByText('History approved')).toBeNull();
    await user.click(screen.getByRole('button', { name: 'Refresh summary' }));
    await waitFor(() => expect(mocks.preview).toHaveBeenCalledTimes(2));
  });

  it('cannot approve unsupported coverage and displays its actual blocker', async () => {
    mocks.preview.mockResolvedValue({ ...summary(), history_coverage_verified: false, blockers: ['Entry 41: immutable checksum changed'] });
    view();
    expect(await screen.findByText('Entry 41: immutable checksum changed')).toBeTruthy();
    expect(screen.getByRole('checkbox', { name: /I reviewed/ }).hasAttribute('disabled')).toBe(true);
    expect(mocks.approve).not.toHaveBeenCalled();
  });

  it('sends a Solo choice only when explicitly selected from real supplied components', async () => {
    const user = userEvent.setup(); view();
    await user.selectOptions(await screen.findByLabelText(/7.70 Solo h/), '9');
    await user.click(screen.getByRole('checkbox', { name: /I reviewed/ }));
    await user.click(screen.getByRole('button', { name: 'Approve history' }));
    expect(mocks.approve.mock.calls[0][2].solo_choices).toEqual([{ employee_id: 8, employee_wage_rate_id: 9 }]);
  });

  it('clears approval state when the selected client changes and ignores an old in-flight approval', async () => {
    let finish!: (value: unknown) => void;
    mocks.approve.mockReturnValue(new Promise((resolve) => { finish = resolve; }));
    const user = userEvent.setup(); const screenView = view();
    await user.click(await screen.findByRole('checkbox', { name: /I reviewed/ }));
    await user.click(screen.getByRole('button', { name: 'Approve history' }));
    mocks.companyId = 3; screenView.rerender(<MemoryRouter><AireHistoryApproval /></MemoryRouter>);
    await waitFor(() => expect(mocks.preview).toHaveBeenCalledWith(1, 3, [], expect.anything()));
    finish({ ...summary(), approved_at: '2026-11-03', approved_by: 'Other client' });
    await waitFor(() => expect(screen.queryByText('History approved')).toBeNull());
  });

  it('requires a refreshed summary after editing a suggested match', async () => {
    const page = summary(); page.mappings[0].existing = false; page.mappings[0].options.push({ id: 10, name: 'Another person' });
    mocks.preview.mockResolvedValue(page);
    view();
    fireEvent.change(await screen.findByLabelText('Payroll employee for Source person'), { target: { value: '10' } });
    expect(screen.getByRole('button', { name: 'Approve history' }).hasAttribute('disabled')).toBe(true);
    expect(screen.getByRole('button', { name: 'Update summary with these matches' })).toBeTruthy();
  });

  it('denies managers without fetching a client history', () => {
    mocks.role = 'manager'; view();
    expect(screen.getByRole('alert').textContent).toMatch(/assigned payroll accountant/);
    expect(mocks.list).not.toHaveBeenCalled();
  });
});
