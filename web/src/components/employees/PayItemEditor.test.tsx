// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useState } from 'react';
import { afterEach, expect, it, vi } from 'vitest';
import { newPayItemDraft, type PayItemDraft } from '@/lib/pay-items';
import type { PayrollFieldDefinition } from '@/types';
import { PayItemEditor } from './PayItemEditor';

afterEach(cleanup);

it.each(['employee_only', 'client_wide'] as const)('retains the chosen payday limits and new-item scope %s after choosing an existing field', async (scope) => {
  const user = userEvent.setup();
  function Editor() {
    const [draft, setDraft] = useState<PayItemDraft>({ ...newPayItemDraft('addition'), scope,
      startDate: '2026-10-13', endDate: '2026-12-31' });
    return <PayItemEditor draft={draft} employeeName="Synthetic Person" companyName="Synthetic Client"
      availableFields={[{ id: 1, name: 'Shared allowance' } as PayrollFieldDefinition]}
      linkedLoan={false} duplicateName={false} saving={false} error={null}
      onChange={(patch) => setDraft((value) => ({ ...value, ...patch }))}
      onSelectField={vi.fn()} onSave={vi.fn()} onClose={vi.fn()} />;
  }
  render(<Editor />);
  await user.click(screen.getByRole('radio', { name: 'Use existing client field' }));
  await user.click(screen.getByRole('radio', { name: 'Create new item' }));
  expect((screen.getByRole('textbox', { name: 'Name' }) as HTMLInputElement).value).toBe('');
  expect((screen.getByLabelText('First payday') as HTMLInputElement).value).toBe('2026-10-13');
  expect((screen.getByLabelText('Last payday') as HTMLInputElement).value).toBe('2026-12-31');
  expect((screen.getByRole('radio', { name: scope === 'employee_only' ? 'Only Synthetic Person' : 'Reusable for Synthetic Client' }) as HTMLInputElement).checked).toBe(true);
});
