// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { YearEnd } from './YearEnd';
import type { YearEndClientRow, YearEndClientsOverview } from '@/lib/year-end';

const mocks = vi.hoisted(() => ({ clients: vi.fn() }));
vi.mock('@/services/api', () => ({ yearEndApi: { clients: mocks.clients }, filingSubmitterApi: { get: vi.fn().mockResolvedValue({ profile: {}, missing_fields: [], can_edit: false }) } }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: { id: 1, name: 'Tumon Bakery' }, activeCompanyId: 1 }) }));

function row(overrides: Partial<YearEndClientRow>): YearEndClientRow {
  return {
    company_id: 1, name: 'Tumon Bakery', active: true, status: 'needs_action', issue_count: 1,
    issue_summary: [{ code: 'FILER_NOT_CHOSEN', label: 'Choose who files', count: 1 }],
    w2: null, form_1099: null, w2_employee_count: 4, employee_details: null, marked_ready_at: null, check_reason: null,
    ...overrides,
    checklist_path: overrides.checklist_path ?? `/companies/${overrides.company_id ?? 1}/year-end?year=2026`,
  };
}

function overview(clients: YearEndClientRow[], hidden = { test_workspaces: 0, inactive_without_payroll: 0 }, taxYear = 2026): { data: YearEndClientsOverview } {
  return {
    data: {
      tax_year: taxYear, clients, hidden,
      counts: {
        needs_action: clients.filter((client) => client.status === 'needs_action').length,
        check_needed: clients.filter((client) => client.status === 'check_needed').length,
        ready: clients.filter((client) => client.status === 'ready').length,
        not_filing: clients.filter((client) => client.status === 'not_filing').length,
      },
    },
  };
}

function renderPage(path = '/year-end?year=2026') {
  render(<MemoryRouter initialEntries={[path]}><YearEnd /></MemoryRouter>);
}

describe('Year-end clients list', () => {
  afterEach(cleanup);
  beforeEach(() => {
    vi.clearAllMocks();
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-11-19T12:00:00+10:00'));
  });
  afterEach(() => vi.useRealTimers());

  it('hides the previous year while the newly chosen year loads', async () => {
    vi.setSystemTime(new Date('2027-03-01T12:00:00+10:00'));
    let resolve2026: (value: { data: YearEndClientsOverview }) => void = () => {};
    mocks.clients.mockImplementation((year: number) => year === 2027
      ? Promise.resolve(overview([row({ company_id: 9, name: 'Yigo Yogurt', issue_count: 5, checklist_path: '/companies/9/year-end?year=2027' })], undefined, 2027))
      : new Promise((resolve) => { resolve2026 = resolve; }));

    renderPage('/year-end?year=2027');
    expect((await screen.findAllByText('Yigo Yogurt')).length).toBeGreaterThan(0);

    fireEvent.change(screen.getByLabelText('Tax year'), { target: { value: '2026' } });

    expect(await screen.findByRole('status', { name: 'Loading clients' })).toBeTruthy();
    expect(screen.queryByText('Yigo Yogurt')).toBeNull();
    expect(screen.queryByRole('link', { name: /Yigo Yogurt|Fix|Open/ })).toBeNull();

    resolve2026(overview([row({ company_id: 2, name: 'Agana Auto' })]));
    expect((await screen.findAllByText('Agana Auto')).length).toBeGreaterThan(0);
    expect(screen.queryByText('Yigo Yogurt')).toBeNull();
  });

  it('lists clients with issues first, then ready and not-filed clients, each with one action', async () => {
    mocks.clients.mockResolvedValue(overview([
      row({ company_id: 2, name: 'Agana Auto', issue_count: 4, w2: { responsible_party: 'cornerstone', label: 'Cornerstone files', prior_provider_through: null }, form_1099: { responsible_party: 'no_filing', label: 'No forms this year', prior_provider_through: null },
        issue_summary: [{ code: 'EMPLOYER_EIN_MISSING', label: 'EIN missing', count: 1 }, { code: 'EMPLOYEE_DETAILS_MISSING', label: 'Employees missing an SSN or address', count: 3 }] }),
      row({ company_id: 3, name: 'Dededo Dental', status: 'ready', issue_count: 0, issue_summary: [], marked_ready_at: '2026-11-18T01:00:00Z', checklist_path: '/companies/3/year-end?year=2026' }),
      row({ company_id: 4, name: 'Old trial', active: false, status: 'not_filing', issue_count: 0, issue_summary: [], checklist_path: '/companies/4/year-end?year=2026' }),
    ], { test_workspaces: 2, inactive_without_payroll: 1 }));

    renderPage();

    const toDo = await screen.findByRole('region', { name: /To do/ });
    expect(within(toDo).getAllByText('Agana Auto').length).toBeGreaterThan(0);
    expect(within(toDo).getAllByText('4 things to fix').length).toBeGreaterThan(0);
    expect(within(toDo).getAllByText('3 employees need an SSN or address').length).toBeGreaterThan(0);
    expect(within(toDo).getAllByText('W-2s: Cornerstone files · 1099s: No forms this year').length).toBeGreaterThan(0);
    expect(within(toDo).getAllByRole('link', { name: 'Fix Agana Auto' })[0].getAttribute('href')).toBe('/companies/2/year-end?year=2026');

    const ready = screen.getByRole('region', { name: /Ready/ });
    expect(within(ready).getAllByText('Ready').length).toBeGreaterThan(0);
    expect(within(ready).getAllByRole('link', { name: 'Open Dededo Dental' }).length).toBeGreaterThan(0);

    const notFiling = screen.getByRole('region', { name: /Not filed by Cornerstone/ });
    expect(within(notFiling).getAllByText('Inactive record').length).toBeGreaterThan(0);
    expect(screen.getByText('Hidden: 2 test workspaces and 1 inactive record with no 2026 payroll.')).toBeTruthy();
    expect(mocks.clients).toHaveBeenCalledWith(2026);
  });

  it('puts a client that changed after it was marked ready on the to-do list as Check needed, not Ready', async () => {
    mocks.clients.mockResolvedValue(overview([
      row({ company_id: 5, name: 'Yigo Market', status: 'check_needed', issue_count: 0, issue_summary: [], marked_ready_at: '2026-11-18T01:00:00Z',
        check_reason: 'Something changed since the W-2s were marked ready. Open the checklist to re-check.' }),
    ]));

    renderPage();

    const toDo = await screen.findByRole('region', { name: /To do/ });
    expect(within(toDo).getAllByText('Check needed').length).toBeGreaterThan(0);
    expect(within(toDo).getAllByText(/Something changed since the W-2s were marked ready/).length).toBeGreaterThan(0);
    expect(within(toDo).getAllByRole('link', { name: 'Check Yigo Market' }).length).toBeGreaterThan(0);
    expect(screen.queryByRole('region', { name: /^Ready/ })).toBeNull();
  });

  it('shows a plain empty state', async () => {
    mocks.clients.mockResolvedValue(overview([]));

    renderPage();

    expect(await screen.findByText('No clients to show for 2026')).toBeTruthy();
  });

  it('shows the error and retries', async () => {
    mocks.clients.mockRejectedValueOnce(new Error('Network unavailable')).mockResolvedValueOnce(overview([row({})]));

    renderPage();

    const alert = await screen.findByRole('alert');
    expect(within(alert).getByText('Network unavailable')).toBeTruthy();
    fireEvent.click(within(alert).getByRole('button', { name: 'Try again' }));
    expect((await screen.findAllByText('Tumon Bakery')).length).toBeGreaterThan(0);
    expect(mocks.clients).toHaveBeenCalledTimes(2);
  });

  it('falls back to the current tax year for an unsupported year in the link', async () => {
    mocks.clients.mockResolvedValue(overview([]));

    renderPage('/year-end?year=1999');

    await screen.findByText('No clients to show for 2026');
    expect(mocks.clients).toHaveBeenCalledWith(2026);
  });
});
