// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { CapturedSourceHours } from './CapturedSourceHours';
import type { PayPeriod, PayrollItem } from '@/types';

const api = vi.hoisted(() => ({ read: vi.fn() }));
vi.mock('@/services/api', () => ({ payPeriodsApi: { airePayrollTimeEntries: api.read } }));
const payPeriod = { id: 119, start_date: '2026-10-16', end_date: '2026-10-31', pay_date: '2026-11-15' } as PayPeriod;
const line = { source_time_entry_id: '1804', line_key: 'admin', source_kind: 'carryover', original_work_date: '2026-09-15', total_hours: 4.25, regular_hours: 4.25, overtime_hours: 0 };
const item = { id: 1, import_source: 'time_tracking:aire_services:1:BATCH', wage_rate_hours: [{ source_bucket_key: 'prior', label: 'Admin Duties', rate: 10, regular_hours: 4.25, overtime_hours: 0, source_lines: [line] }] } as PayrollItem;
const entry = { id: '1804', work_date: '2026-09-15', created_at: '2026-09-23T03:14:22Z', category: { name: 'Admin Duties' }, capture: { entry_method: 'manual' }, state: { approval_status: 'approved', overtime_status: 'none' }, approval: { actor: { name: 'Manager' }, occurred_at: '2026-10-07T03:07:36Z', note: 'Reviewed the missing day.' } };
const response = { time_entries: [entry], pagination: { current_page: 1, total_pages: 1 } };
beforeEach(() => { api.read.mockReset(); api.read.mockResolvedValue(response); });
afterEach(cleanup);

it('shows the original work date and paying period without fetching or modifying the source', () => {
  render(<CapturedSourceHours item={item} payPeriod={payPeriod} />);
  expect(screen.getByText('Prior-period hours · Sep 15, 2026')).toBeTruthy();
  expect(screen.getByText(/Paying payroll:/).textContent).toContain('Nov 15, 2026');
  expect(screen.getByText(/4.25 regular hrs/).textContent).toContain('$10.00');
  expect(api.read).not.toHaveBeenCalled();
});

it('opens the exact entry and its recorded approval history on request', async () => {
  render(<CapturedSourceHours item={item} payPeriod={payPeriod} />);
  fireEvent.click(screen.getByText('Review source entry #1804'));
  expect(await screen.findByText('Reviewed the missing day.')).toBeTruthy();
  expect(screen.getByText(/Oct 7, 2026.*Manager/)).toBeTruthy();
  expect(screen.getByText(/Sep 23, 2026/)).toBeTruthy();
  expect(api.read).toHaveBeenCalledWith(119, { page: 1 });
});

it('retains saved evidence when the source is unavailable and recovers on retry', async () => {
  api.read.mockRejectedValueOnce(new Error('Time tracking is unavailable'));
  render(<CapturedSourceHours item={item} payPeriod={payPeriod} />);
  fireEvent.click(screen.getByText('Review source entry #1804'));
  expect(await screen.findByText(/Saved work dates and hours remain available/)).toBeTruthy();
  expect(screen.getByText('Prior-period hours · Sep 15, 2026')).toBeTruthy();
  fireEvent.click(screen.getByText('Try source again'));
  expect(await screen.findByText('Reviewed the missing day.')).toBeTruthy();
});

it('reads additional source pages instead of declaring an omitted entry missing', async () => {
  api.read.mockResolvedValueOnce({ time_entries: [], pagination: { current_page: 1, total_pages: 2 } });
  render(<CapturedSourceHours item={item} payPeriod={payPeriod} />);
  fireEvent.click(screen.getByText('Review source entry #1804'));
  fireEvent.click(await screen.findByText('Read next source page'));
  expect(await screen.findByText('Reviewed the missing day.')).toBeTruthy();
  expect(api.read).toHaveBeenLastCalledWith(119, { page: 2 });
});

it('does not imply a reason or dates for payroll without captured source hours', () => {
  const view = render(<CapturedSourceHours item={{ id: 1 } as PayrollItem} payPeriod={payPeriod} />);
  expect(view.container.textContent).toBe('');
});
