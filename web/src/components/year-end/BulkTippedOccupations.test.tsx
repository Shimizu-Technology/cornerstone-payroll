// @vitest-environment jsdom

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { BulkTippedOccupations } from './BulkTippedOccupations';

const { bulkSet } = vi.hoisted(() => ({ bulkSet: vi.fn().mockResolvedValue({ count: 1 }) }));
vi.mock('@/services/api', () => ({
  tippedOccupationsApi: { catalog: async () => ({ codes: { '000': 'Nonqualifying occupation', '102': 'Wait Staff' } }), bulkSet },
}));

afterEach(() => vi.restoreAllMocks());

it('confirms the selected count and refreshes the Year-End warnings after saving', async () => {
  const confirm = vi.spyOn(window, 'confirm').mockReturnValueOnce(false).mockReturnValueOnce(true);
  const onSaved = vi.fn().mockResolvedValue(undefined);
  render(<BulkTippedOccupations companyId={7} year={2026} onSaved={onSaved} employees={[
    { employee_id: 1, name: 'Worker One', edit_path: '/one' },
    { employee_id: 2, name: 'Worker Two', edit_path: '/two' },
  ]} />);

  fireEvent.click(screen.getByRole('button', { name: 'Set tipped occupation codes' }));
  fireEvent.click(await screen.findByLabelText('Select all 2 employees'));
  expect(screen.getByRole('button', { name: 'Apply to 2 selected' })).toBeTruthy();
  fireEvent.click(screen.getByLabelText('Worker Two'));
  fireEvent.change(screen.getByLabelText('Treasury occupation code'), { target: { value: '102' } });
  const apply = screen.getByRole('button', { name: 'Apply to 1 selected' });

  fireEvent.click(apply);
  expect(bulkSet).not.toHaveBeenCalled();
  expect(confirm).toHaveBeenCalledWith(expect.stringContaining('for 1 employee from 2026-01-01'));

  fireEvent.click(apply);
  await waitFor(() => expect(onSaved).toHaveBeenCalledWith('Saved the tipped occupation code for 1 employee.'));
  expect(bulkSet).toHaveBeenCalledWith(7, { tax_year: 2026, employee_ids: [1], occupation_code: '102', effective_from: '2026-01-01' });
});
