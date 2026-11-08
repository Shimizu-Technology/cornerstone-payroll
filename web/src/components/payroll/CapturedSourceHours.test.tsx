// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { CapturedSourceHours } from './CapturedSourceHours';
import type { PayPeriod, PayrollItem } from '@/types';

const api = vi.hoisted(() => ({ read: vi.fn(), period: vi.fn() }));
vi.mock('@/services/api', () => ({ payPeriodsApi: { airePayrollTimeEntries: api.read, get: api.period } }));
const payPeriod = { id: 119, company_id: 1, start_date: '2026-10-16', end_date: '2026-10-31', pay_date: '2026-11-15', time_tracking: { aire_calendar: { source_id: 1 } } } as PayPeriod;
const line = { source_time_entry_id: '1804', line_key: 'admin', source_kind: 'carryover', original_work_date: '2026-09-15', total_hours: 4.25, regular_hours: 4.25, overtime_hours: 0 };
const item = { id: 1, import_source: 'time_tracking:aire_services:1:BATCH', wage_rate_hours: [{ source_bucket_key: 'prior', label: 'Admin Duties', rate: 10, regular_hours: 4.25, overtime_hours: 0, source_lines: [line] }] } as PayrollItem;
const entry = { id: '1804', work_date: '2026-09-15', created_at: '2026-09-23T03:14:22Z', category: { name: 'Admin Duties' }, capture: { entry_method: 'manual' }, state: { approval_status: 'approved', overtime_status: 'none' }, approval: { actor: { name: 'Manager' }, occurred_at: '2026-10-07T03:07:36Z', note: 'Reviewed the missing day.' } };
const response = { time_entries: [entry], pagination: { current_page: 1, total_pages: 1 } };
beforeEach(() => { api.read.mockReset(); api.period.mockReset(); api.read.mockResolvedValue(response); api.period.mockResolvedValue({ pay_period: payPeriod }); });
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

it('does not link another time source to the AIRE entry with the same numeric ID', () => {
  render(<CapturedSourceHours item={{ ...item, import_source: 'time_tracking:custom:2:BATCH', time_tracking_provenance: { source: 'aire_services' } } as PayrollItem} payPeriod={payPeriod} />);
  expect(screen.queryByRole('button', { name: 'Review source entry #1804' })).toBeNull();
  expect(screen.getByText(/review history in the original time system/)).toBeTruthy();
  expect(api.read).not.toHaveBeenCalled();
});

it('retains captured evidence when the current calendar belongs to a different source installation', () => {
  render(<CapturedSourceHours item={item} payPeriod={{ ...payPeriod, time_tracking: { aire_calendar: { source_id: 2 } } } as PayPeriod} />);
  expect(screen.queryByRole('button', { name: 'Review source entry #1804' })).toBeNull();
  expect(screen.getByText('Prior-period hours · Sep 15, 2026')).toBeTruthy();
});

it('verifies the requested origin installation when a supplemental run has no calendar', async () => {
  api.period.mockResolvedValue({ pay_period: { ...payPeriod, time_tracking: { aire_calendar: { source_id: 2 } } } });
  render(<CapturedSourceHours item={item} payPeriod={{ ...payPeriod, id: 120, late_hours_origin_pay_period_id: 119, time_tracking: undefined }} />);
  fireEvent.click(screen.getByText('Review source entry #1804'));
  expect(await screen.findByText(/source installation could not be verified/)).toBeTruthy();
  expect(api.period).toHaveBeenCalledWith(119, 1);
  expect(api.read).not.toHaveBeenCalled();
});

it('reads a verified origin when the supplemental calendar summary is missing', async () => {
  render(<CapturedSourceHours item={item} payPeriod={{ ...payPeriod, id: 120, late_hours_origin_pay_period_id: 119, time_tracking: undefined }} />);
  fireEvent.click(screen.getByText('Review source entry #1804'));
  expect(await screen.findByText('Reviewed the missing day.')).toBeTruthy();
  expect(api.period).toHaveBeenCalledWith(119, 1);
  expect(api.read).toHaveBeenCalledWith(119, { page: 1 });
});

it('removes cached approval details when a page-one refresh fails', async () => {
  render(<CapturedSourceHours item={item} payPeriod={payPeriod} />);
  fireEvent.click(screen.getByText('Review source entry #1804'));
  expect(await screen.findByText('Reviewed the missing day.')).toBeTruthy();
  api.read.mockRejectedValueOnce(new Error('Source unavailable'));
  fireEvent.click(screen.getByText('Review source entry #1804'));
  expect(await screen.findByText(/Saved work dates and hours remain available/)).toBeTruthy();
  expect(screen.queryByText('Reviewed the missing day.')).toBeNull();
  expect(screen.queryByText(/Oct 7, 2026.*Manager/)).toBeNull();
});
