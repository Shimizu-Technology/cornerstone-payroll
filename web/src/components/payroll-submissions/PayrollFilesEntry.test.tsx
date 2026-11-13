// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { PayrollFilesEntry } from './PayrollFilesEntry';
import { currentSubmissionPeriod } from '@/lib/payrollSubmissionFormat';
import type { PeriodSummary } from '@/services/payrollSubmissions';

const mocks = vi.hoisted(() => ({ list: vi.fn() }));
vi.mock('@/services/payrollSubmissions', async original => ({
  ...await original<typeof import('@/services/payrollSubmissions')>(),
  clientPayrollSubmissionsApi: { list: mocks.list },
}));
afterEach(() => { cleanup(); vi.clearAllMocks(); });

const period = (overrides: Partial<PeriodSummary>): PeriodSummary => ({
  ref: '2026-10-19_2026-11-01', id: null, start_date: '2026-10-19', end_date: '2026-11-01', label: 'Oct 19 – Nov 1, 2026', pay_date: '2026-11-05',
  status: 'waiting_for_files', status_label: 'Waiting for files', open_for_files: true, opens_on: '2026-11-01',
  current_revision: null, last_submitted_at: null, status_changed_at: null, ...overrides,
});
const renderEntry = () => render(<MemoryRouter><PayrollFilesEntry /></MemoryRouter>);

it('leads the client Home to the current period with its status and the Pay Periods difference', async () => {
  mocks.list.mockResolvedValue({ data: [
    period({ ref: '2026-11-16_2026-11-29', label: 'Nov 16 – Nov 29, 2026', open_for_files: false, opens_on: '2026-11-29', pay_date: '2026-12-03' }),
    period({}),
  ], meta: { derives_from_schedule: true } });
  renderEntry();
  expect(await screen.findByText('Payroll Oct 19 – Nov 1, 2026')).toBeTruthy();
  expect(screen.getByText('Waiting for files')).toBeTruthy();
  expect(screen.getByText(/Pay date Nov 5, 2026/)).toBeTruthy();
  const send = screen.getByRole('link', { name: 'Send payroll files' });
  expect(send.getAttribute('href')).toBe('/payroll-files/2026-10-19_2026-11-01');
  expect(screen.getByText(/shows payrolls Cornerstone has already processed/)).toBeTruthy();
  expect(screen.getByRole('link', { name: 'See all pay periods for files' }).getAttribute('href')).toBe('/payroll-files');
});

it('shows the status after files are sent and names the next step when a draft is ready', async () => {
  mocks.list.mockResolvedValue({ data: [period({ status: 'draft_ready', status_label: 'Draft ready to review', current_revision: 2 })], meta: { derives_from_schedule: true } });
  renderEntry();
  expect(await screen.findByText('Draft ready to review')).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Review the draft' })).toBeTruthy();
});

it('says when a period has not opened yet instead of offering to send', async () => {
  mocks.list.mockResolvedValue({ data: [period({ open_for_files: false, opens_on: '2026-11-29', end_date: '2026-11-29' })], meta: { derives_from_schedule: true } });
  renderEntry();
  expect(await screen.findByText(/Opens for files Nov 29, 2026/)).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Open payroll files' })).toBeTruthy();
});

it('still links to Payroll Files and offers a retry when the status cannot load', async () => {
  mocks.list.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ data: [period({})], meta: { derives_from_schedule: true } });
  renderEntry();
  expect((await screen.findByRole('alert')).textContent).toMatch(/could not load your current pay period/);
  expect(screen.getByRole('link', { name: 'Open Payroll Files' }).getAttribute('href')).toBe('/payroll-files');
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  await waitFor(() => expect(screen.getByRole('link', { name: 'Send payroll files' })).toBeTruthy());
});

it('explains an empty list', async () => {
  mocks.list.mockResolvedValue({ data: [], meta: { derives_from_schedule: false } });
  renderEntry();
  expect(await screen.findByText(/No pay period is open for files yet/)).toBeTruthy();
});

it('picks the period that waits on the client before newer or paid ones', () => {
  const rows = [
    period({ ref: 'c', status: 'paid', status_label: 'Paid' }),
    period({ ref: 'b', status: 'submitted', status_label: 'Sent' }),
    period({ ref: 'a', status: 'waiting_for_files' }),
  ];
  expect(currentSubmissionPeriod(rows)?.ref).toBe('a');
  expect(currentSubmissionPeriod([rows[0], rows[1]])?.ref).toBe('b');
  expect(currentSubmissionPeriod([rows[0]])?.ref).toBe('c');
  expect(currentSubmissionPeriod([])).toBeNull();
});
