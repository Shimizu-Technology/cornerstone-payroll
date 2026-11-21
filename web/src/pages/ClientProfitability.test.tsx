// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ProfitabilityLine, ProfitabilityOverview, ProfitabilityReport } from '@/services/clientProfitability';
import { ReportView } from '@/components/client-profitability/ReportView';
import { ClientProfitability } from './ClientProfitability';

const state = vi.hoisted(() => ({
  overview: vi.fn(),
  updateSettings: vi.fn(),
  refresh: vi.fn(),
  importStatus: vi.fn(),
  links: vi.fn(),
  linkClient: vi.fn(),
  unlinkClient: vi.fn(),
  linkStaff: vi.fn(),
  unlinkStaff: vi.fn(),
  report: vi.fn(),
  exportCsv: vi.fn(),
}));

vi.mock('@/services/clientProfitability', () => ({ clientProfitabilityApi: state }));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title }: { title: string }) => <h1>{title}</h1> }));

function overview(overrides: Partial<ProfitabilityOverview> = {}): ProfitabilityOverview {
  return {
    connection: { connected: true, missing: [], problem: null, tax_host: 'tax.example.test' },
    settings: { practice_company_id: 1, finance_book_id: null, effective_finance_book_id: 3, tax_prep_service_names: ['Tax Preparation'],
      default_cost_pending: false, default_spread_overhead: false, default_period: 'month', cost_basis: 'pay_date' },
    options: { companies: [{ id: 1, name: 'Cornerstone' }, { id: 2, name: 'Acme Bakery' }], finance_books: [{ id: 3, name: 'Cornerstone' }], service_names: ['Bookkeeping', 'Tax Preparation'] },
    imports: [],
    has_hours: true,
    needs_linking: { clients: 1, staff: 0 },
    ...overrides,
  };
}

function line(overrides: Partial<ProfitabilityLine>): ProfitabilityLine {
  return {
    key: 'company:2', kind: 'company', company_id: 2, tax_client_id: null, name: 'Acme Bakery', hours: '10.00', pending_hours: '2.00',
    direct_cost: '1937.70', overhead_cost: '0.00', cost: '1937.70', fees: '1500.00', tax_prep_fees: '500.00', other_fees: '1000.00',
    margin: '-437.70', margin_percent: '-29.2', effective_rate: '150.00',
    people: [{ tax_user_id: 12, name: 'Mark Santos', linked: true, hours: '6.00', approved_hours: '6.00', pending_hours: '2.00', cost: '1937.70',
      categories: [{ category: 'Bookkeeping', task: 'Bank reconciliation', hours: '6.00', pending_hours: '0.00' }] }],
    ...overrides,
  };
}

function report(): ProfitabilityReport {
  return {
    period: { from: '2026-10', through: '2026-10', start_date: '2026-10-01', end_date: '2026-10-31', label: 'October 2026' },
    options: { cost_pending: false, spread_overhead: false, cost_basis: 'pay_date' },
    cost_basis: { basis: 'pay_date', cost: '6459.00', annual_payroll_summary_cost: '6459.00', difference: '0.00' },
    practice_company: { id: 1, name: 'Cornerstone' },
    finance_book: { id: 3, name: 'Cornerstone' },
    coverage: { missing_months: [], missing_month_labels: [], last_refreshed_at: null, pending_hours: '2.00' },
    clients: [line({})],
    overhead: line({ key: 'overhead', kind: 'overhead', company_id: null, name: 'Internal / overhead', fees: '0.00', tax_prep_fees: '0.00', people: [] }),
    unassigned: [line({ key: 'tax_client:999', kind: 'unlinked_client', company_id: null, tax_client_id: 999, name: 'Gamma LLC', fees: '0.00', tax_prep_fees: '0.00', people: [] })],
    unlinked_fees: { fees: '300.00', tax_prep_fees: '0.00' },
    unallocated_costs: [{ employee_id: 9, name: 'Loreen Reyes', reason: 'not_linked', cost: '1076.50' }],
    imported_pay_not_linked: { paycheck_count: 1, cost: '303.00' },
    staff: [],
    totals: { hours: '22.00', pending_hours: '2.00', cost: '6459.00', fees: '2600.00', tax_prep_fees: '500.00', other_fees: '2100.00', margin: '-3859.00', margin_percent: '-148.4', effective_rate: '118.18' },
    connection: { connected: true, missing: [], problem: null, tax_host: 'tax.example.test' },
  };
}

function renderPage(path = '/reports/client-profitability') {
  return render(<MemoryRouter initialEntries={[path]}><ClientProfitability /></MemoryRouter>);
}

describe('ClientProfitability', () => {
  beforeEach(() => {
    Object.values(state).forEach((mock) => mock.mockReset());
    state.report.mockResolvedValue(report());
  });
  afterEach(cleanup);

  it('explains the setup steps and stays usable when Tax is not connected', async () => {
    state.overview.mockResolvedValue(overview({
      connection: { connected: false, missing: ['CORNERSTONE_TAX_API_URL', 'PAYROLL_WORK_HOURS_SECRET'], problem: null, tax_host: null },
      has_hours: false,
    }));
    renderPage();
    expect(await screen.findByText('Cornerstone Tax isn’t connected yet')).toBeTruthy();
    expect(screen.getByText(/Still missing: CORNERSTONE_TAX_API_URL, PAYROLL_WORK_HOURS_SECRET/)).toBeTruthy();
    expect((screen.getByRole('button', { name: /Refresh hours from Tax/ }) as HTMLButtonElement).disabled).toBe(true);
    expect(state.report).not.toHaveBeenCalled();
    // The app layout supplies the one <main> landmark.
    expect(screen.queryByRole('main')).toBeNull();
  });

  it('shows clients, drills into people and tasks, and re-asks with the toggles', async () => {
    state.overview.mockResolvedValue(overview());
    renderPage('/reports/client-profitability?tab=report');
    expect(await screen.findByRole('heading', { name: 'October 2026' })).toBeTruthy();
    expect(screen.getAllByText('Acme Bakery').length).toBeGreaterThan(0);
    expect(screen.getByText(/Loreen Reyes/)).toBeTruthy();
    expect(screen.getByText(/\$300\.00 in fees are on invoices/)).toBeTruthy();

    const table = screen.getByRole('table', { name: 'Profit by client' });
    await userEvent.click(within(table).getByRole('button', { name: /Acme Bakery/ }));
    expect(within(table).getByText('Mark Santos')).toBeTruthy();
    expect(within(table).getByText('Bookkeeping · Bank reconciliation')).toBeTruthy();

    await userEvent.click(screen.getByRole('checkbox', { name: /Count pending hours in cost/ }));
    await waitFor(() => expect(state.report).toHaveBeenLastCalledWith(expect.objectContaining({ cost_pending: true, spread_overhead: false })));
    await userEvent.click(screen.getByRole('checkbox', { name: /Spread internal/ }));
    await waitFor(() => expect(state.report).toHaveBeenLastCalledWith(expect.objectContaining({ cost_pending: true, spread_overhead: true })));

    await userEvent.click(screen.getByRole('radio', { name: 'Quarter' }));
    await waitFor(() => {
      const query = state.report.mock.lastCall?.[0] as { from: string; through: string };
      expect(Number(query.through.slice(5)) - Number(query.from.slice(5))).toBe(2);
    });
  });

  it('confirms a suggested link from the queue', async () => {
    state.overview.mockResolvedValue(overview());
    state.links.mockResolvedValue({
      clients: [{ tax_client_id: 345, name: 'Acme Bakery', hours: '5.00', last_worked_on: '2026-10-05', internal_in_tax: false, handled_automatically: false,
        link: null, suggestion: { disposition: 'company', company_id: 2, label: 'Acme Bakery', match: 'exact' } }],
      staff: [{ tax_user_id: 12, email: 'mark@example.com', hours: '5.00', link: null, suggestion: null }],
      companies: [{ id: 2, name: 'Acme Bakery' }],
      recipients: [],
      employees: [{ id: 5, name: 'Mark Santos', status: 'active' }],
    });
    state.linkClient.mockResolvedValue({ ok: true });
    state.linkStaff.mockResolvedValue({ ok: true });
    renderPage('/reports/client-profitability?tab=link');

    await userEvent.click(await screen.findByRole('button', { name: 'Use suggestion' }));
    expect(state.linkClient).toHaveBeenCalledWith(345, { disposition: 'company', company_id: 2, tax_client_name: 'Acme Bakery' });

    await userEvent.selectOptions(screen.getByLabelText('Their pay comes from'), 'no_payroll');
    await userEvent.click(screen.getAllByRole('button', { name: 'Save link' }).at(-1)!);
    expect(state.linkStaff).toHaveBeenCalledWith(12, { disposition: 'no_payroll', email: 'mark@example.com' });
  });

  it('saves the staff payroll client and tax-prep services', async () => {
    state.overview.mockResolvedValue(overview({ has_hours: false }));
    state.updateSettings.mockResolvedValue(overview());
    renderPage();
    await userEvent.click(await screen.findByRole('checkbox', { name: 'Bookkeeping' }));
    await userEvent.click(screen.getByRole('button', { name: 'Save settings' }));
    expect(state.updateSettings).toHaveBeenCalledWith({ practice_company_id: 1, finance_book_id: null, tax_prep_service_names: ['Tax Preparation', 'Bookkeeping'],
      default_cost_pending: false, default_spread_overhead: false, default_period: 'month', cost_basis: 'pay_date' });
    expect(await screen.findByText('Settings saved.')).toBeTruthy();
  });

  it('clears the report and its CSV when the report for new options fails', async () => {
    state.overview.mockResolvedValue(overview());
    state.report.mockResolvedValueOnce(report()).mockRejectedValueOnce(new Error('Server error'));
    renderPage('/reports/client-profitability?tab=report');
    expect(await screen.findByRole('heading', { name: 'October 2026' })).toBeTruthy();

    await userEvent.click(screen.getByRole('checkbox', { name: /Count pending hours in cost/ }));
    expect(await screen.findByText('Server error')).toBeTruthy();
    expect(screen.queryByRole('table', { name: 'Profit by client' })).toBeNull();
    expect((screen.getByRole('button', { name: /Download CSV/ }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('downloads the CSV for the report on screen', async () => {
    state.overview.mockResolvedValue(overview());
    state.exportCsv.mockResolvedValue({ blob: new Blob(['x']), filename: 'client-profitability.csv' });
    const createObjectURL = vi.fn(() => 'blob:x');
    Object.assign(URL, { createObjectURL, revokeObjectURL: vi.fn() });
    renderPage('/reports/client-profitability?tab=report');
    expect(await screen.findByRole('heading', { name: 'October 2026' })).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: /Download CSV/ }));
    await waitFor(() => expect(state.exportCsv).toHaveBeenCalledWith(state.report.mock.lastCall?.[0]));
  });

  it('keeps the newest link reload when two saves finish out of order', async () => {
    const queue = (staffLink: boolean) => ({
      clients: [{ tax_client_id: 345, name: 'Acme Bakery', hours: '5.00', last_worked_on: null, internal_in_tax: false, handled_automatically: false,
        link: null, suggestion: { disposition: 'company' as const, company_id: 2, label: 'Acme Bakery', match: 'exact' as const } }],
      staff: [{ tax_user_id: 12, email: 'mark@example.com', hours: '5.00',
        link: staffLink ? { disposition: 'no_payroll' as const, employee_id: null, employee_name: null, in_practice_company: true } : null, suggestion: null }],
      companies: [{ id: 2, name: 'Acme Bakery' }],
      recipients: [],
      employees: [],
    });
    let resolveOlder!: (value: ReturnType<typeof queue>) => void;
    let resolveNewer!: (value: ReturnType<typeof queue>) => void;
    state.overview.mockResolvedValue(overview());
    state.links.mockResolvedValueOnce(queue(false))
      .mockImplementationOnce(() => new Promise((resolve) => { resolveOlder = resolve; }))
      .mockImplementationOnce(() => new Promise((resolve) => { resolveNewer = resolve; }));
    state.linkClient.mockResolvedValue({ ok: true });
    state.linkStaff.mockResolvedValue({ ok: true });
    renderPage('/reports/client-profitability?tab=link');

    await userEvent.click(await screen.findByRole('button', { name: 'Use suggestion' }));
    await userEvent.selectOptions(screen.getByLabelText('Their pay comes from'), 'no_payroll');
    await userEvent.click(screen.getAllByRole('button', { name: 'Save link' }).at(-1)!);
    await waitFor(() => expect(state.links).toHaveBeenCalledTimes(3));

    resolveNewer(queue(true));
    expect(await screen.findByText(/Staff/)).toBeTruthy();
    await waitFor(() => expect(screen.getByText(/· 0 to link/)).toBeTruthy());
    resolveOlder(queue(false));
    await new Promise((resolve) => { window.setTimeout(resolve, 50); });
    expect(screen.getByText(/· 0 to link/)).toBeTruthy();
    expect(screen.getAllByText(/· 1 to link/)).toHaveLength(1);
  });

  it('recovers the link queue after a failed load', async () => {
    state.overview.mockResolvedValue(overview());
    state.links.mockRejectedValueOnce(new Error('Network down')).mockResolvedValueOnce({ clients: [], staff: [], companies: [], recipients: [], employees: [] });
    renderPage('/reports/client-profitability?tab=link');
    expect(await screen.findByText('Network down')).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByText(/No hours have been pulled from Tax yet/)).toBeTruthy();
    expect(screen.queryByText('Network down')).toBeNull();
  });

  it('keeps watching a refresh on another section and reloads the report when it ends', async () => {
    const queued = { id: 7, status: 'queued' as const, trigger: 'manual' as const, range_start: '2026-10-01', range_end: '2026-10-31',
      requested_by: 'Leon', created_at: null, started_at: null, finished_at: null, row_count: 0, total_hours: '0.0',
      pending_entries: 0, denied_entries: 0, open_clock_entries: 0, error_code: null, error_message: null };
    state.overview.mockResolvedValue(overview());
    state.refresh.mockResolvedValue({ import: queued });
    state.importStatus.mockRejectedValueOnce(new Error('blip')).mockResolvedValue({ import: { ...queued, status: 'succeeded' } });
    renderPage('/reports/client-profitability?tab=setup');

    await userEvent.click(await screen.findByRole('button', { name: /Refresh hours from Tax/ }));
    await waitFor(() => expect(state.refresh).toHaveBeenCalled());
    await userEvent.click(screen.getByRole('button', { name: 'Report' }));
    const reportsBefore = state.report.mock.calls.length;
    await waitFor(() => expect(state.importStatus).toHaveBeenCalledTimes(2), { timeout: 6000 });
    await waitFor(() => expect(state.report.mock.calls.length).toBeGreaterThan(reportsBefore), { timeout: 3000 });
    expect(state.overview.mock.calls.length).toBeGreaterThanOrEqual(2);
  }, 12000);

  it('picks up a refresh that is already running on the server', async () => {
    const running = { id: 9, status: 'running' as const, trigger: 'scheduled' as const, range_start: '2026-10-01', range_end: '2026-11-21',
      requested_by: null, created_at: null, started_at: null, finished_at: null, row_count: 0, total_hours: '0.0',
      pending_entries: 0, denied_entries: 0, open_clock_entries: 0, error_code: null, error_message: null };
    state.overview.mockResolvedValue(overview({ imports: [running] }));
    state.importStatus.mockResolvedValue({ import: running });
    renderPage('/reports/client-profitability?tab=setup');
    expect(await screen.findByText('Pulling hours from Cornerstone Tax…')).toBeTruthy();
    await waitFor(() => expect(state.importStatus).toHaveBeenCalledWith(9), { timeout: 3000 });
  });

  it('reloads the link queue when a refresh finishes while it is open', async () => {
    const running = { id: 11, status: 'running' as const, trigger: 'scheduled' as const, range_start: '2026-11-01', range_end: '2026-11-21',
      requested_by: null, created_at: null, started_at: null, finished_at: null, row_count: 0, total_hours: '0.0',
      pending_entries: 0, denied_entries: 0, open_clock_entries: 0, error_code: null, error_message: null };
    state.overview.mockResolvedValueOnce(overview({ imports: [running] })).mockResolvedValue(overview({ imports: [{ ...running, status: 'succeeded' }] }));
    state.importStatus.mockResolvedValue({ import: { ...running, status: 'succeeded' } });
    state.links.mockResolvedValueOnce({ clients: [], staff: [], companies: [], recipients: [], employees: [] }).mockResolvedValue({
      clients: [{ tax_client_id: 777, name: 'New Tax Client', hours: '3.00', last_worked_on: '2026-11-20', internal_in_tax: false,
        handled_automatically: false, link: null, suggestion: null }],
      staff: [], companies: [{ id: 2, name: 'Acme Bakery' }], recipients: [], employees: [],
    });
    renderPage('/reports/client-profitability?tab=link');

    expect(await screen.findByText(/No hours have been pulled from Tax yet/)).toBeTruthy();
    expect(await screen.findByText('New Tax Client', undefined, { timeout: 4000 })).toBeTruthy();
    expect(state.links).toHaveBeenCalledTimes(2);
  });

  it('saves report defaults and how pay is counted', async () => {
    state.overview.mockResolvedValue(overview({ has_hours: false }));
    state.updateSettings.mockResolvedValue(overview());
    renderPage('/reports/client-profitability?tab=setup');
    await userEvent.click(await screen.findByRole('radio', { name: /Work period/ }));
    await userEvent.click(screen.getByRole('checkbox', { name: /Count pending hours in cost/ }));
    await userEvent.click(screen.getByRole('checkbox', { name: /Spread internal\/overhead time/ }));
    await userEvent.selectOptions(screen.getByLabelText('Default period'), 'quarter');
    await userEvent.click(screen.getByRole('button', { name: 'Save settings' }));
    expect(state.updateSettings).toHaveBeenCalledWith(expect.objectContaining({
      cost_basis: 'work_period', default_cost_pending: true, default_spread_overhead: true, default_period: 'quarter',
    }));
  });

  it('starts the report from the saved defaults, which can still be changed for one view', async () => {
    state.overview.mockResolvedValue(overview({
      settings: { ...overview().settings, default_cost_pending: true, default_spread_overhead: true, default_period: 'quarter', cost_basis: 'work_period' },
    }));
    renderPage('/reports/client-profitability?tab=report');
    await waitFor(() => expect(state.report).toHaveBeenCalled());
    const first = state.report.mock.calls[0][0] as { from: string; through: string; cost_pending: boolean; spread_overhead: boolean; cost_basis: string };
    expect(first).toMatchObject({ cost_pending: true, spread_overhead: true, cost_basis: 'work_period' });
    expect(Number(first.through.slice(5)) - Number(first.from.slice(5))).toBe(2);
    expect((screen.getByRole('radio', { name: 'Quarter' }) as HTMLButtonElement).getAttribute('aria-checked')).toBe('true');

    await userEvent.click(screen.getByRole('checkbox', { name: /Count pending hours in cost/ }));
    await waitFor(() => expect(state.report).toHaveBeenLastCalledWith(expect.objectContaining({ cost_pending: false })));
  });

  it('explains the difference from the Annual Payroll Summary when counting by work period', async () => {
    state.overview.mockResolvedValue(overview());
    state.report.mockResolvedValue({
      ...report(),
      options: { cost_pending: false, spread_overhead: false, cost_basis: 'work_period' },
      cost_basis: { basis: 'work_period', cost: '3000.00', annual_payroll_summary_cost: '1500.00', difference: '1500.00' },
    });
    renderPage('/reports/client-profitability?tab=report');
    expect(await screen.findByText(/Pay is counted by work period: \$3,000\.00/)).toBeTruthy();
    expect(screen.getByText(/counts \$1,500\.00 for paychecks paid in these months, \$1,500\.00 less\. The difference is pay for work done in one range but paid in another\./)).toBeTruthy();
    await userEvent.click(screen.getByText('How this is calculated'));
    expect(screen.getByText(/Pay and hours are both matched by the days worked/)).toBeTruthy();
    expect(screen.queryByText(/Pay is matched by pay date and hours by work date/)).toBeNull();
  });

  it('keeps the cost basis of an open report until it is opened again', async () => {
    state.overview.mockResolvedValue(overview());
    const onGoTo = vi.fn();
    const defaults = { costPending: false, spreadOverhead: false, period: 'month' as const, costBasis: 'pay_date' as const };
    const view = render(<MemoryRouter><ReportView reloadKey={0} onGoTo={onGoTo} defaults={defaults} /></MemoryRouter>);
    await waitFor(() => expect(state.report).toHaveBeenCalledTimes(1));
    expect(state.report.mock.lastCall?.[0]).toMatchObject({ cost_basis: 'pay_date' });

    // An hours refresh finishes after someone saved "work period": the overview and reloadKey change.
    view.rerender(<MemoryRouter><ReportView reloadKey={1} onGoTo={onGoTo} defaults={{ ...defaults, costBasis: 'work_period' }} /></MemoryRouter>);
    await waitFor(() => expect(state.report).toHaveBeenCalledTimes(2));
    expect(state.report.mock.lastCall?.[0]).toMatchObject({ cost_basis: 'pay_date' });
    view.unmount();

    render(<MemoryRouter><ReportView reloadKey={1} onGoTo={onGoTo} defaults={{ ...defaults, costBasis: 'work_period' }} /></MemoryRouter>);
    await waitFor(() => expect(state.report).toHaveBeenCalledTimes(3));
    expect(state.report.mock.lastCall?.[0]).toMatchObject({ cost_basis: 'work_period' });
  });

  it('names what a client or staff member was linked to right after saving, and links to an invoice customer', async () => {
    state.overview.mockResolvedValue(overview());
    const queue = {
      clients: [
        { tax_client_id: 880, name: 'Roland’s Watch Repair – Zenaida Ponce', hours: '2.00', last_worked_on: '2026-10-05', internal_in_tax: false,
          handled_automatically: false, link: null,
          suggestion: { disposition: 'recipient' as const, invoice_recipient_id: 41, label: 'Roland’s Watch Repair (Ponce)', match: 'similar' as const } },
        { tax_client_id: 881, name: 'Acme Bakery', hours: '1.00', last_worked_on: null, internal_in_tax: false, handled_automatically: false,
          link: null, suggestion: null },
      ],
      staff: [{ tax_user_id: 12, email: 'mark@example.com', hours: '5.00', link: null, suggestion: null }],
      companies: [{ id: 2, name: 'Acme Bakery' }],
      recipients: [{ id: 41, name: 'Roland’s Watch Repair (Ponce)' }],
      employees: [{ id: 5, name: 'Mark Santos', status: 'active' }],
    };
    let finishReload!: (value: typeof queue) => void;
    state.links.mockResolvedValueOnce(queue).mockImplementation(() => new Promise((resolve) => { finishReload = resolve; }));
    state.linkClient.mockResolvedValue({ ok: true });
    state.linkStaff.mockResolvedValue({ ok: true });
    renderPage('/reports/client-profitability?tab=link');

    // The dropdown groups Payroll clients and invoice customers.
    const select = (await screen.findAllByLabelText('Count these hours for'))[1] as HTMLSelectElement;
    const groups = Array.from(select.querySelectorAll('optgroup')).map((group) => group.label);
    expect(groups).toEqual(['Payroll clients', 'Invoice customers (no payroll)']);

    // The suggested invoice customer, saved: the confirmation names it while the queue reloads.
    await userEvent.click(screen.getByRole('button', { name: 'Use suggestion' }));
    expect(state.linkClient).toHaveBeenCalledWith(880, { disposition: 'recipient', invoice_recipient_id: 41, tax_client_name: 'Roland’s Watch Repair – Zenaida Ponce' });
    expect(screen.getByText('Roland’s Watch Repair (Ponce)', { selector: 'strong' })).toBeTruthy();

    await userEvent.selectOptions(select, 'company:2');
    await userEvent.click(screen.getAllByRole('button', { name: 'Save link' })[0]);
    expect(state.linkClient).toHaveBeenLastCalledWith(881, { disposition: 'company', company_id: 2, tax_client_name: 'Acme Bakery' });
    expect(screen.getByText('Acme Bakery', { selector: 'strong' })).toBeTruthy();

    await userEvent.selectOptions(screen.getByLabelText('Their pay comes from'), '5');
    await userEvent.click(screen.getByRole('button', { name: 'Save link' }));
    expect(screen.getByText('Mark Santos', { selector: 'strong' })).toBeTruthy();
    // No confirmation is left reading just "Linked to".
    const confirmations = screen.getAllByRole('status').map((element) => element.textContent?.trim() ?? '');
    expect(confirmations.filter((text) => text.startsWith('Linked to'))).toEqual([
      'Linked to Roland’s Watch Repair (Ponce)', 'Linked to Acme Bakery',
    ]);
    finishReload(queue);
  });
});
