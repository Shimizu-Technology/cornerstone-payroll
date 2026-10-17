// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { TimecardOcrPanel } from './TimecardOcrPanel';
import type { TimecardData } from '@/services/api';

const mocks = vi.hoisted(() => ({ list: vi.fn(), employees: vi.fn(), show: vi.fn(), updatePunch: vi.fn(), review: vi.fn(), reprocess: vi.fn(), apply: vi.fn() }));
vi.mock('@/services/api', () => ({
  timecardsApi: { listPaginated: mocks.list, show: mocks.show, review: mocks.review, reprocess: mocks.reprocess, applyToPayroll: mocks.apply },
  punchEntriesApi: { update: mocks.updatePunch }, employeesApi: { list: mocks.employees },
}));
const card: TimecardData = {
  id: 1, company_id: 15, pay_period_id: 13, employee_name: 'Morgan P27', period_start: '2026-05-03', period_end: '2026-05-03',
  image_url: null, preprocessed_image_url: null, ocr_status: 'reviewed', overall_confidence: 0.6, ocr_error: null,
  reviewed_by_name: 'QA Admin', reviewed_at: '2026-10-17T00:00:00Z', applied_employee_id: null, applied_employee_name: null,
  applied_payroll_item_id: null, applied_to_payroll_at: null, created_at: '2026-10-17T00:00:00Z',
  review_summary: { severity: 'ok', priority_rank: 3, attention_count: 0, approved_attention_count: 1, low_confidence_count: 0, noted_entry_count: 0, missing_punch_count: 0, manual_edit_count: 0, reason_codes: [] },
  punch_entries: [{ id: 1, card_day: 3, date: '2026-05-03', day_of_week: 'Sun', clock_in: '08:00', lunch_out: '12:00', lunch_in: '13:00', clock_out: '17:00', in3: null, out3: null, hours_worked: 8, confidence: 0.6, notes: 'Synthetic anomaly', manually_edited: false, review_state: 'approved', reviewed_by_name: 'QA Admin', reviewed_at: '2026-10-17T00:00:00Z', needs_attention: true, blank_day: false }],
};
afterEach(cleanup);
beforeEach(() => {
  Object.values(mocks).forEach(mock => mock.mockReset());
  mocks.employees.mockResolvedValue({ data: [{ id: 32, first_name: 'Morgan', last_name: 'P27', employment_type: 'hourly', wage_rates: [] }] });
  mocks.updatePunch.mockResolvedValue({});
});
async function open(data = card) {
  mocks.list.mockResolvedValue({ timecards: [data], meta: { total_pages: 1, total_count: 1 } });
  render(<TimecardOcrPanel payPeriodId={13} onPayrollUpdated={vi.fn()} />);
  const user = userEvent.setup();
  await user.click(await screen.findByRole('button', { name: 'View Details' }));
  return user;
}
it('keeps Save outside the punch scroller and requires saved, reviewed edits before applying payroll', async () => {
  const user = await open();
  await user.click(screen.getByRole('button', { name: 'Hide image' }));
  expect(screen.getByRole('button', { name: 'Show image' }).getAttribute('aria-expanded')).toBe('false');
  const out = screen.getByRole('textbox', { name: 'Clock out after lunch on 2026-05-03' });
  await user.clear(out);
  await user.type(out, '5:30 PM');
  const apply = screen.getByRole('button', { name: 'Apply Hours to Payroll' }) as HTMLButtonElement;
  expect(apply.disabled).toBe(true);
  await user.click(apply);
  expect(mocks.apply).not.toHaveBeenCalled();
  const save = screen.getByRole('button', { name: 'Save All Changes' });
  expect(screen.getByRole('region', { name: 'Punch times' }).contains(save)).toBe(false);
  mocks.show.mockResolvedValue({ ...card, ocr_status: 'complete', reviewed_at: null, reviewed_by_name: null,
    review_summary: { ...card.review_summary, attention_count: 1 },
    punch_entries: [{ ...card.punch_entries[0], clock_out: '17:30', hours_worked: 8.5, review_state: 'unresolved' }],
  });
  let completeSave!: () => void;
  mocks.updatePunch.mockImplementationOnce(() => new Promise<void>(resolve => { completeSave = resolve; }));
  await user.click(save);
  await waitFor(() => expect(mocks.updatePunch).toHaveBeenCalledWith(1, { clock_out: '17:30' }));
  expect((out as HTMLInputElement).disabled).toBe(true);
  expect((screen.getByLabelText('Work date for day 3') as HTMLInputElement).disabled).toBe(true);
  expect(apply.disabled).toBe(true);
  await user.type(out, '6:00 PM');
  expect((out as HTMLInputElement).value).toBe('5:30 PM');
  completeSave();
  expect(await screen.findByRole('button', { name: 'Approve All Flagged' })).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Apply Hours to Payroll' })).toBeNull();
  expect((screen.getByRole('textbox', { name: 'Clock out after lunch on 2026-05-03' }) as HTMLInputElement).value).toBe('5:30 PM');
});
it('blocks review and reprocessing while punch edits are unsaved', async () => {
  const user = await open({ ...card, ocr_status: 'complete' });
  const out = screen.getByRole('textbox', { name: 'Clock out after lunch on 2026-05-03' });
  await user.clear(out);
  await user.type(out, '5:30 PM');
  for (const name of ['Mark Reviewed', 'Re-run OCR']) {
    const button = screen.getByRole('button', { name }) as HTMLButtonElement;
    expect(button.disabled).toBe(true);
    await user.click(button);
  }
  expect(mocks.review).not.toHaveBeenCalled();
  expect(mocks.reprocess).not.toHaveBeenCalled();
});
