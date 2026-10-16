// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { NonEmployeeCheck } from '@/types';
import { NonEmployeeChecksPanel } from './NonEmployeeChecksPanel';

const api = vi.hoisted(() => ({
  list: vi.fn(), create: vi.fn(), voidCheck: vi.fn(), delete: vi.fn(),
  updateCheckNumbers: vi.fn(), generateFitCheck: vi.fn(), company: vi.fn(),
}));
vi.mock('@/services/api', () => ({
  nonEmployeeChecksApi: { list: api.list, create: api.create, voidCheck: api.voidCheck, delete: api.delete },
  checksApi: { updateCheckNumbers: api.updateCheckNumbers },
  payPeriodsApi: { generateFitCheck: api.generateFitCheck },
  companiesApi: { get: api.company },
}));
vi.mock('./NonEmployeeCheckEditModal', () => ({ NonEmployeeCheckEditModal: () => null }));
vi.mock('./NonEmployeeCheckHistory', () => ({ NonEmployeeCheckHistory: () => null }));
vi.mock('@/components/form500/Form500EditorModal', () => ({ Form500EditorModal: () => null }));
vi.mock('@/components/documents/PdfPreview', () => ({ PdfPreview: () => null }));

const check: NonEmployeeCheck = {
  id: 42, pay_period_id: 8, company_id: 1, payable_to: 'Synthetic vendor', amount: 100,
  check_type: 'vendor', check_number: '8101', payment_period_type: 'pay_period', payment_method: 'check',
  line_items: [], print_count: 0, voided: false, check_status: 'unprinted',
  created_at: '2026-10-15T00:00:00Z', updated_at: '2026-10-15T00:00:00Z',
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((success, failure) => { resolve = success; reject = failure; });
  return { promise, resolve, reject };
}

const mutations = [
  {
    name: 'create', api: api.create,
    perform: () => {
      fireEvent.click(screen.getByRole('button', { name: '+ Add Check' }));
      fireEvent.change(screen.getByPlaceholderText('Payable To *'), { target: { value: 'New synthetic vendor' } });
      fireEvent.change(screen.getByPlaceholderText('Amount *'), { target: { value: '25' } });
      fireEvent.click(screen.getByRole('button', { name: 'Create Check' }));
    },
  },
  {
    name: 'void', api: api.voidCheck,
    perform: () => {
      fireEvent.click(screen.getByRole('button', { name: 'Void' }));
      fireEvent.change(screen.getByPlaceholderText('Reason...'), { target: { value: 'Synthetic replacement' } });
      fireEvent.click(screen.getByRole('button', { name: 'Confirm' }));
    },
  },
  {
    name: 'delete', api: api.delete,
    perform: () => { fireEvent.click(screen.getByRole('button', { name: 'Delete' })); },
  },
  {
    name: 'check-number update', api: api.updateCheckNumbers,
    perform: () => {
      fireEvent.change(screen.getByRole('textbox', { name: 'Check number for Synthetic vendor' }), { target: { value: '8102' } });
      fireEvent.click(screen.getByRole('button', { name: 'Save check numbers' }));
    },
  },
  {
    name: 'FIT generation', api: api.generateFitCheck,
    perform: () => { fireEvent.click(screen.getByRole('button', { name: 'Generate FIT Check' })); },
  },
];

async function renderChecks() {
  const onChecksLoaded = vi.fn();
  const onChecksChanged = vi.fn();
  const view = render(<NonEmployeeChecksPanel payPeriodId={8} companyId={1} payPeriodStatus="committed"
    onChecksLoaded={onChecksLoaded} onChecksChanged={onChecksChanged} />);
  await screen.findByText('Synthetic vendor');
  await waitFor(() => expect(onChecksLoaded).toHaveBeenLastCalledWith([check]));
  onChecksLoaded.mockClear();
  return { ...view, onChecksLoaded, onChecksChanged };
}

describe('NonEmployeeChecksPanel saved mutation invalidation', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    api.list.mockResolvedValue({ non_employee_checks: [check] });
    api.company.mockResolvedValue({ company: { id: 1, name: 'Synthetic company' } });
    for (const mutation of mutations) mutation.api.mockResolvedValue({});
    vi.stubGlobal('confirm', vi.fn(() => true));
  });
  afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

  it.each(mutations)('invalidates after $name succeeds, even while its list reload fails, and recovers without replaying the mutation', async mutation => {
    const { onChecksLoaded, onChecksChanged } = await renderChecks();
    const reload = deferred<{ non_employee_checks: NonEmployeeCheck[] }>();
    api.list.mockReturnValueOnce(reload.promise);
    mutation.perform();
    await waitFor(() => expect(onChecksChanged).toHaveBeenCalledOnce());
    expect(mutation.api).toHaveBeenCalledOnce();
    expect(api.list).toHaveBeenCalledTimes(2);
    expect(onChecksLoaded).not.toHaveBeenCalled();
    await act(async () => reload.reject(new Error('Synthetic list outage')));
    expect((await screen.findByRole('alert')).textContent).toContain('Saved changes are retained');
    expect(screen.queryByText('Synthetic vendor')).toBeNull();
    expect(screen.queryByText('No non-employee checks for this pay period.')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Save check numbers' })).toBeNull();
    expect((screen.getByRole('button', { name: '+ Add Check' }) as HTMLButtonElement).disabled).toBe(true);
    expect(onChecksLoaded).not.toHaveBeenCalled();
    expect(onChecksChanged).toHaveBeenCalledOnce();

    const recovered = { ...check, payable_to: 'Current saved vendor', check_number: '8102' };
    api.list.mockResolvedValueOnce({ non_employee_checks: [recovered] });
    fireEvent.click(screen.getByRole('button', { name: 'Reload checks' }));
    expect(await screen.findByText('Current saved vendor')).toBeTruthy();
    await waitFor(() => expect(onChecksLoaded).toHaveBeenLastCalledWith([recovered]));
    expect(screen.queryByRole('alert')).toBeNull();
    expect((screen.getByRole('button', { name: '+ Add Check' }) as HTMLButtonElement).disabled).toBe(false);
    expect(mutation.api).toHaveBeenCalledOnce();
    expect(onChecksChanged).toHaveBeenCalledOnce();
  });

  it.each(mutations)('does not report a saved change when $name is rejected', async mutation => {
    const { onChecksLoaded, onChecksChanged } = await renderChecks();
    mutation.api.mockRejectedValueOnce(new Error('Mutation rejected'));
    mutation.perform();
    await waitFor(() => expect(mutation.api).toHaveBeenCalledOnce());
    expect(onChecksChanged).not.toHaveBeenCalled();
    expect(onChecksLoaded).not.toHaveBeenCalled();
    expect(api.list).toHaveBeenCalledOnce();
    expect(screen.getByText('Synthetic vendor')).toBeTruthy();
  });

  it('preserves the loaded-check observer after a successful saved mutation and reload', async () => {
    const { onChecksLoaded, onChecksChanged } = await renderChecks();
    const remaining = { ...check, id: 43, payable_to: 'Remaining vendor' };
    api.list.mockResolvedValueOnce({ non_employee_checks: [remaining] });
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }));
    await screen.findByText('Remaining vendor');
    expect(onChecksChanged).toHaveBeenCalledOnce();
    await waitFor(() => expect(onChecksLoaded).toHaveBeenLastCalledWith([remaining]));
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it.each(['success', 'failure'] as const)('ignores an older list %s after the current list succeeds, preserving drafts and observers', async outcome => {
    const { rerender, onChecksLoaded, onChecksChanged } = await renderChecks();
    const older = deferred<{ non_employee_checks: NonEmployeeCheck[] }>();
    const current = deferred<{ non_employee_checks: NonEmployeeCheck[] }>();
    api.list.mockReturnValueOnce(older.promise).mockReturnValueOnce(current.promise);
    rerender(<NonEmployeeChecksPanel payPeriodId={8} companyId={1} payPeriodStatus="committed" refreshToken={1}
      onChecksLoaded={onChecksLoaded} onChecksChanged={onChecksChanged} />);
    await waitFor(() => expect(api.list).toHaveBeenCalledTimes(2));
    rerender(<NonEmployeeChecksPanel payPeriodId={8} companyId={1} payPeriodStatus="committed" refreshToken={2}
      onChecksLoaded={onChecksLoaded} onChecksChanged={onChecksChanged} />);
    await waitFor(() => expect(api.list).toHaveBeenCalledTimes(3));
    const saved = { ...check, payable_to: 'Current saved vendor' };
    await act(async () => current.resolve({ non_employee_checks: [saved] }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Check number for Current saved vendor' }), { target: { value: '8200' } });
    onChecksLoaded.mockClear();
    await act(async () => {
      if (outcome === 'success') older.resolve({ non_employee_checks: [{ ...check, payable_to: 'Obsolete vendor' }] });
      else older.reject(new Error('Obsolete outage'));
    });
    expect(screen.queryByText('Obsolete vendor')).toBeNull();
    expect(screen.queryByRole('alert')).toBeNull();
    expect((screen.getByRole('textbox', { name: 'Check number for Current saved vendor' }) as HTMLInputElement).value).toBe('8200');
    expect(onChecksLoaded).not.toHaveBeenCalled();
    expect(onChecksChanged).not.toHaveBeenCalled();
  });

  it('keeps a newer failed reload unavailable when an older successful response arrives', async () => {
    const { rerender, onChecksLoaded } = await renderChecks();
    const older = deferred<{ non_employee_checks: NonEmployeeCheck[] }>();
    const current = deferred<{ non_employee_checks: NonEmployeeCheck[] }>();
    api.list.mockReturnValueOnce(older.promise).mockReturnValueOnce(current.promise);
    rerender(<NonEmployeeChecksPanel payPeriodId={8} companyId={1} refreshToken={1} onChecksLoaded={onChecksLoaded} />);
    await waitFor(() => expect(api.list).toHaveBeenCalledTimes(2));
    rerender(<NonEmployeeChecksPanel payPeriodId={8} companyId={1} refreshToken={2} onChecksLoaded={onChecksLoaded} />);
    await waitFor(() => expect(api.list).toHaveBeenCalledTimes(3));
    await act(async () => current.reject(new Error('Current outage')));
    expect(await screen.findByRole('alert')).toBeTruthy();
    await act(async () => older.resolve({ non_employee_checks: [check] }));
    expect(screen.getByRole('alert')).toBeTruthy();
    expect(screen.queryByText('Synthetic vendor')).toBeNull();
    expect((screen.getByRole('button', { name: '+ Add Check' }) as HTMLButtonElement).disabled).toBe(true);
    expect(onChecksLoaded).not.toHaveBeenCalled();
  });

  it('does not end a current load when the previous pay run responds and ignores responses after unmount', async () => {
    const older = deferred<{ non_employee_checks: NonEmployeeCheck[] }>();
    const current = deferred<{ non_employee_checks: NonEmployeeCheck[] }>();
    const onChecksLoaded = vi.fn();
    api.list.mockReturnValueOnce(older.promise).mockReturnValueOnce(current.promise);
    const { rerender, unmount } = render(<NonEmployeeChecksPanel payPeriodId={8} companyId={1} onChecksLoaded={onChecksLoaded} />);
    rerender(<NonEmployeeChecksPanel payPeriodId={9} companyId={1} onChecksLoaded={onChecksLoaded} />);
    await waitFor(() => expect(api.list).toHaveBeenCalledTimes(2));
    onChecksLoaded.mockClear();
    await act(async () => older.resolve({ non_employee_checks: [check] }));
    expect(screen.getByText('Loading...')).toBeTruthy();
    expect(screen.queryByText('Synthetic vendor')).toBeNull();
    expect((screen.getByRole('button', { name: '+ Add Check' }) as HTMLButtonElement).disabled).toBe(true);
    unmount();
    await act(async () => current.resolve({ non_employee_checks: [{ ...check, pay_period_id: 9 }] }));
    expect(onChecksLoaded).not.toHaveBeenCalled();
  });

  it('blocks initial Add and an open Create form during pending or failed reads, then recovers the draft with a read-only reload', async () => {
    const initial = deferred<{ non_employee_checks: NonEmployeeCheck[] }>();
    api.list.mockReturnValueOnce(initial.promise);
    const view = render(<NonEmployeeChecksPanel payPeriodId={8} companyId={1} />);
    fireEvent.click(screen.getByRole('button', { name: '+ Add Check' }));
    expect(screen.queryByPlaceholderText('Payable To *')).toBeNull();
    await act(async () => initial.resolve({ non_employee_checks: [check] }));
    fireEvent.click(screen.getByRole('button', { name: '+ Add Check' }));
    fireEvent.change(screen.getByPlaceholderText('Payable To *'), { target: { value: 'Retained draft' } });
    fireEvent.change(screen.getByPlaceholderText('Amount *'), { target: { value: '25' } });
    const reload = deferred<{ non_employee_checks: NonEmployeeCheck[] }>();
    api.list.mockReturnValueOnce(reload.promise);
    view.rerender(<NonEmployeeChecksPanel payPeriodId={8} companyId={1} refreshToken={1} />);
    expect((screen.getByRole('button', { name: 'Create Check' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole('button', { name: 'Create Check' }));
    expect(api.create).not.toHaveBeenCalled();
    await act(async () => reload.reject(new Error('Current outage')));
    expect((await screen.findByRole('alert')).textContent).toContain('Saved changes are retained');
    expect((screen.getByRole('button', { name: 'Create Check' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole('button', { name: 'Create Check' }));
    expect(api.create).not.toHaveBeenCalled();
    api.list.mockResolvedValueOnce({ non_employee_checks: [check] });
    fireEvent.click(screen.getByRole('button', { name: 'Reload checks' }));
    await waitFor(() => expect((screen.getByRole('button', { name: 'Create Check' }) as HTMLButtonElement).disabled).toBe(false));
    expect((screen.getByPlaceholderText('Payable To *') as HTMLInputElement).value).toBe('Retained draft');
    fireEvent.click(screen.getByRole('button', { name: 'Create Check' }));
    await waitFor(() => expect(api.create).toHaveBeenCalledOnce());
  });

  it('blocks new payments for a voided committed payroll while retaining saved payment review', async () => {
    api.list.mockResolvedValue({ non_employee_checks: [{ ...check, voided: true, edit_count: 1 }] });
    render(<NonEmployeeChecksPanel payPeriodId={8} companyId={1} payPeriodStatus="committed" payPeriodVoided />);
    await screen.findByText('Synthetic vendor');

    expect(screen.getByRole('status').textContent).toContain('This payroll is voided');
    const generate = screen.getByRole('button', { name: 'Generate FIT Check' }) as HTMLButtonElement;
    const add = screen.getByRole('button', { name: '+ Add Check' }) as HTMLButtonElement;
    expect(generate.disabled).toBe(true);
    expect(add.disabled).toBe(true);
    fireEvent.click(generate);
    fireEvent.click(add);
    expect(api.generateFitCheck).not.toHaveBeenCalled();
    expect(api.create).not.toHaveBeenCalled();
    expect(screen.queryByPlaceholderText('Payable To *')).toBeNull();
    expect((screen.getByRole('button', { name: 'Preview' }) as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(screen.getByTitle('Show edit history'));
    expect(screen.getByText('Edit History')).toBeTruthy();
  });

  it('preserves an open draft and allows Cancel when the payroll becomes voided', async () => {
    const view = await renderChecks();
    fireEvent.click(screen.getByRole('button', { name: '+ Add Check' }));
    fireEvent.change(screen.getByPlaceholderText('Payable To *'), { target: { value: 'Retained draft' } });
    fireEvent.change(screen.getByPlaceholderText('Amount *'), { target: { value: '25' } });

    view.rerender(<NonEmployeeChecksPanel payPeriodId={8} companyId={1} payPeriodStatus="committed" payPeriodVoided />);
    expect((screen.getByPlaceholderText('Payable To *') as HTMLInputElement).value).toBe('Retained draft');
    expect((screen.getByPlaceholderText('Amount *') as HTMLInputElement).value).toBe('25.00');
    const create = screen.getByRole('button', { name: 'Create Check' }) as HTMLButtonElement;
    expect(create.disabled).toBe(true);
    fireEvent.click(create);
    expect(api.create).not.toHaveBeenCalled();
    fireEvent.click(screen.getAllByRole('button', { name: 'Cancel' })[0]);
    expect(screen.queryByPlaceholderText('Payable To *')).toBeNull();
    expect((screen.getByRole('button', { name: '+ Add Check' }) as HTMLButtonElement).disabled).toBe(true);
  });
});
