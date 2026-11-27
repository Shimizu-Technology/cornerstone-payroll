// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AppStatusReport, AppStatusRow } from '@/services/employee-app-status-api';
import { EmployeeAppStatus } from './EmployeeAppStatus';

const mocks = vi.hoisted(() => ({ get: vi.fn(), getBlobWithParams: vi.fn() }));
const saved = vi.hoisted(() => ({ saveBlob: vi.fn() }));
vi.mock('@/services/api', () => ({ apiClient: mocks }));
vi.mock('@/lib/save-blob', () => saved);
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: { id: 7, name: 'Example Bakery' }, companies: [] }) }));

function row(id: number, name: string, overrides: Partial<AppStatusRow> = {}): AppStatusRow {
  return {
    id, name, department: null, role: null,
    account: { status: 'not_invited', label: 'Not invited', signed_up: false, invite_sent_at: null, signed_up_at: null, last_opened_at: null },
    terms: { version: null, accepted_at: null, current: false },
    pay_statements: { answer: 'not_answered', answered_at: null },
    w2gu: { answer: 'not_answered', answered_at: null },
    ...overrides,
  };
}

const ana = row(1, 'Ana Sample', {
  department: { id: 3, name: 'Kitchen' }, role: 'Cook',
  account: { status: 'active', label: 'Signed up', signed_up: true, invite_sent_at: '2026-11-01T00:00:00Z', signed_up_at: '2026-11-05T00:00:00Z', last_opened_at: '2026-11-26T03:00:00Z' },
  terms: { version: 'terms-2026-11', accepted_at: '2026-11-05T00:00:00Z', current: true },
  pay_statements: { answer: 'paperless', answered_at: '2026-11-06T00:00:00Z' },
  w2gu: { answer: 'keep_paper', answered_at: '2026-11-07T00:00:00Z' },
});
const ben = row(2, 'Ben Example', {
  role: 'Server',
  account: { status: 'invite_expired', label: 'Invite expired', signed_up: false, invite_sent_at: '2026-11-01T00:00:00Z', invite_expires_at: '2026-11-20T00:00:00Z', invite_expired: true, signed_up_at: null, last_opened_at: null },
});
const cy = row(3, 'Cy Placeholder', { role: 'Server' });

function report(employees: AppStatusRow[]): AppStatusReport {
  return {
    enabled: true, delivery_consent_enabled: true, current_terms_version: 'terms-2026-11', opens_recorded_since: '2026-11-25',
    summary: {
      total: 3, signed_up: 1, opened: 1, not_signed_up: 2, signed_up_no_opens: 0,
      invite_expired: 1, terms_not_accepted: 2, no_paperless_answer: 2, kept_paper: 1,
    },
    departments: [{ id: 3, name: 'Kitchen' }], roles: ['Cook', 'Server'], employees,
  };
}

function openPage(audience: 'admin' | 'client' = 'client') {
  render(<MemoryRouter><EmployeeAppStatus audience={audience} /></MemoryRouter>);
  return userEvent.setup();
}

const lastQuery = () => mocks.get.mock.calls.at(-1)?.[1];

describe('Employee app status report', () => {
  beforeEach(() => {
    mocks.get.mockImplementation(async (_path: string, params: Record<string, string>) => {
      if (params.filter === 'not_signed_up') return { data: report([ben, cy]) };
      if (params.q === 'cy') return { data: report([cy]) };
      return { data: report([ben, cy, ana]) };
    });
  });
  afterEach(() => { cleanup(); vi.resetAllMocks(); });

  it('leads with how many signed in and shows each person’s account, terms and answers', async () => {
    openPage();
    const summary = await screen.findByRole('region', { name: 'Summary' });
    expect(summary.textContent).toContain('1 of 3 signed up · 1 has opened the app');
    expect(summary.textContent).toContain('App opens are recorded since Nov 25, 2026.');
    expect(mocks.get).toHaveBeenCalledWith('/client/employee_app_status/7', {}, { companyId: 7 });

    const table = screen.getByRole('table');
    const anaRow = within(table).getByRole('row', { name: /Ana Sample/ });
    expect(anaRow.textContent).toContain('Signed up');
    expect(anaRow.textContent).toContain('Last opened Nov 26, 2026');
    expect(anaRow.textContent).toContain('Kitchen · Cook');
    expect(anaRow.textContent).toContain('Accepted');
    expect(anaRow.textContent).toContain('terms-2026-11');
    expect(anaRow.textContent).toContain('Paperless');
    expect(anaRow.textContent).toContain('Keep paper');
    const benRow = within(table).getByRole('row', { name: /Ben Example/ });
    expect(benRow.textContent).toContain('Invite expired');
    expect(benRow.textContent).toMatch(/Sent Nov 1, 2026 · expired Nov 20, 2026/);
    expect(benRow.textContent).toContain('Not accepted');
    expect(within(table).getByRole('link', { name: 'Ana Sample' }).getAttribute('href')).toContain('/companies/7/employees/1');
    // The phone layout has the same people as cards.
    expect(within(screen.getByRole('list', { name: 'Employees' })).getAllByRole('listitem')).toHaveLength(3);
  });

  it('filters with one-click chips that show their counts, and a second click clears them', async () => {
    const user = openPage();
    const chip = await screen.findByRole('button', { name: 'Not signed up 2' });
    expect(screen.getByRole('button', { name: 'Kept paper (needs paper copies) 1' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Signed up, no recorded opens 0' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Hasn’t accepted terms 2' })).toBeTruthy();
    await user.click(chip);
    await waitFor(() => expect(lastQuery()).toEqual({ filter: 'not_signed_up' }));
    expect(chip.getAttribute('aria-pressed')).toBe('true');
    await waitFor(() => expect(screen.getByRole('status').textContent).toBe('Showing 2 employees'));
    await user.click(chip);
    await waitFor(() => expect(lastQuery()).toEqual({}));
    expect(screen.getByRole('button', { name: 'All active employees 3' }).getAttribute('aria-pressed')).toBe('true');
  });

  it('searches by name and filters by department and role through the API', async () => {
    const user = openPage();
    await user.type(await screen.findByLabelText('Search by name'), 'cy');
    await waitFor(() => expect(lastQuery()).toEqual({ q: 'cy' }));
    await waitFor(() => expect(screen.getByRole('status').textContent).toBe('Showing 1 employee'));
    await user.clear(screen.getByLabelText('Search by name'));
    await user.selectOptions(screen.getByLabelText('Department'), '3');
    await user.selectOptions(screen.getByLabelText('Role'), 'Server');
    await waitFor(() => expect(lastQuery()).toEqual({ department_id: '3', role: 'Server' }));
  });

  it('sorts by column, toggling direction', async () => {
    const user = openPage('admin');
    const table = await screen.findByRole('table');
    const names = () => within(table).getAllByRole('link').map((link) => link.textContent);
    expect(names()).toEqual(['Ana Sample', 'Ben Example', 'Cy Placeholder']);
    await user.click(within(table).getByRole('button', { name: 'Employee' }));
    expect(names()).toEqual(['Cy Placeholder', 'Ben Example', 'Ana Sample']);
    await user.click(within(table).getByRole('button', { name: 'App account' }));
    expect(names()).toEqual(['Cy Placeholder', 'Ben Example', 'Ana Sample']);
    expect(within(table).getByRole('columnheader', { name: 'App account' }).getAttribute('aria-sort')).toBe('ascending');
  });

  it('downloads CSV and Excel with the filters on screen', async () => {
    const user = openPage('admin');
    mocks.getBlobWithParams.mockResolvedValue({ blob: new Blob(['x']), filename: 'example-bakery-employee-app-status-2026-11-27.csv' });
    await user.click(await screen.findByRole('button', { name: 'Not signed up 2' }));
    await waitFor(() => expect(lastQuery()).toEqual({ filter: 'not_signed_up' }));
    await user.click(screen.getByRole('button', { name: 'CSV' }));
    expect(mocks.getBlobWithParams).toHaveBeenCalledWith('/admin/employee_app_status/7/csv', { filter: 'not_signed_up' }, { companyId: 7 });
    expect(saved.saveBlob).toHaveBeenCalledWith(expect.any(Blob), 'example-bakery-employee-app-status-2026-11-27.csv');
    await user.click(screen.getByRole('button', { name: 'Excel' }));
    expect(mocks.getBlobWithParams).toHaveBeenLastCalledWith('/admin/employee_app_status/7/xlsx', { filter: 'not_signed_up' }, { companyId: 7 });
  });

  it('waits to export until the result for the new filters is on screen, then exports exactly those params', async () => {
    let finish: (value: { data: AppStatusReport }) => void = () => {};
    const user = openPage('admin');
    mocks.getBlobWithParams.mockResolvedValue({ blob: new Blob(['x']), filename: 'status.csv' });
    await screen.findByRole('table');
    mocks.get.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    await user.click(screen.getByRole('button', { name: 'Not signed up 2' }));
    expect(screen.getByRole('status').textContent).toBe('Updating…');
    expect((screen.getByRole('button', { name: 'CSV' }) as HTMLButtonElement).disabled).toBe(true);
    await user.click(screen.getByRole('button', { name: 'CSV' }));
    expect(mocks.getBlobWithParams).not.toHaveBeenCalled();

    finish({ data: report([ben, cy]) });
    await waitFor(() => expect(screen.getByRole('status').textContent).toBe('Showing 2 employees'));
    await user.click(screen.getByRole('button', { name: 'CSV' }));
    expect(mocks.getBlobWithParams).toHaveBeenCalledWith('/admin/employee_app_status/7/csv', { filter: 'not_signed_up' }, { companyId: 7 });
  });

  it('sorts the phone cards with a Sort by control', async () => {
    const user = openPage();
    const list = await screen.findByRole('list', { name: 'Employees' });
    const names = () => within(list).getAllByRole('link').map((link) => link.textContent);
    expect(names()).toEqual(['Ana Sample', 'Ben Example', 'Cy Placeholder']);
    await user.selectOptions(screen.getByLabelText('Sort by'), 'name:desc');
    expect(names()).toEqual(['Cy Placeholder', 'Ben Example', 'Ana Sample']);
    await user.selectOptions(screen.getByLabelText('Sort by'), 'account:asc');
    expect(names()).toEqual(['Cy Placeholder', 'Ben Example', 'Ana Sample']);
  });

  it('says "No recorded opens" for someone signed up without a recorded open', async () => {
    const quiet = row(4, 'Dee Quiet', {
      account: { status: 'active', label: 'Signed up', signed_up: true, invite_sent_at: null, signed_up_at: '2026-11-10T00:00:00Z', last_opened_at: null },
    });
    mocks.get.mockResolvedValue({ data: report([quiet]) });
    openPage();
    const table = await screen.findByRole('table');
    expect(within(table).getByRole('row', { name: /Dee Quiet/ }).textContent).toContain('No recorded opens');
    expect(document.body.textContent).not.toMatch(/Never|Hasn’t opened/);
  });

  it('says so when nobody matches and when paperless isn’t being asked yet', async () => {
    mocks.get.mockResolvedValue({ data: { ...report([]), delivery_consent_enabled: false } });
    openPage();
    expect(await screen.findByText('No employees match these filters.')).toBeTruthy();
    expect(screen.getByText(/Employees aren’t asked about paperless pay stubs or W-2GU yet/)).toBeTruthy();
  });
});
