// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { ReplaceCheckModal } from './ReplaceCheckModal';
import type { PayPeriod, PayrollItem } from '@/types';

const mocks = vi.hoisted(() => ({ replaceCheckPreview: vi.fn(), replaceCheck: vi.fn() }));
vi.mock('@/services/api', () => ({ checksApi: mocks }));
afterEach(cleanup);
beforeEach(() => { mocks.replaceCheckPreview.mockReset(); mocks.replaceCheck.mockReset(); });

it.each([{ rates: [25] }, { rates: [25, 25] }, { rates: [10, 25] }])('describes saved earning entries for captured rates $rates without claiming multiple rates', async ({ rates }) => {
  const user = userEvent.setup();
  const buckets = rates.map((rate, index) => ({ employee_wage_rate_id: 1, source_bucket_key: `entry-${index}`,
    label: `Saved earning ${index + 1}`, rate, regular_hours: index === 0 ? 4 : 2, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, active: true }));
  const original = JSON.stringify(buckets);
  const gross = buckets.reduce((sum, bucket) => sum + bucket.rate * bucket.regular_hours, 0);
  const item = { id: 8, employee_id: 2, employee_name: 'Synthetic Employee', employment_type: 'hourly', pay_rate: 25,
    hours_worked: buckets.reduce((sum, bucket) => sum + bucket.regular_hours, 0), overtime_hours: 0,
    gross_pay: gross, net_pay: ({ 100: 92.35, 150: 138.52, 90: 83.11 } as Record<number, number>)[gross],
    check_number: '1001', wage_rate_hours: buckets } as PayrollItem;
  const onOpenChange = vi.fn();
  render(<ReplaceCheckModal open onOpenChange={onOpenChange} payPeriod={{ id: 12, status: 'committed' } as PayPeriod} payrollItem={item} onReplaced={vi.fn()} />);
  expect(screen.getByText(/Gross is recalculated using each entry's saved rate/)).toBeTruthy();
  expect(screen.queryByText(/paid at multiple rates/)).toBeNull();
  for (const bucket of buckets) expect(screen.getByText(bucket.label)).toBeTruthy();
  expect(screen.getAllByText(/\$\d+\.00\/hr/)).toHaveLength(buckets.length);
  await user.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(onOpenChange).toHaveBeenCalledWith(false);
  expect(mocks.replaceCheckPreview).not.toHaveBeenCalled();
  expect(mocks.replaceCheck).not.toHaveBeenCalled();
  expect(JSON.stringify(buckets)).toBe(original);
});
