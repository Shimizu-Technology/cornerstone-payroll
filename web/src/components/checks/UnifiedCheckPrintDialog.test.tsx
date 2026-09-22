// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CheckPrintQueueResponse, CheckPrintRun } from '@/types';
import { UnifiedCheckPrintDialog } from './UnifiedCheckPrintDialog';

const apiMocks = vi.hoisted(() => ({
  printQueue: vi.fn(),
  printRuns: vi.fn(),
  printRunPdf: vi.fn(),
  createPrintRun: vi.fn(),
  updateCheckNumbers: vi.fn(),
  confirmPrintRun: vi.fn(),
}));

vi.mock('@/services/api', () => ({ checksApi: apiMocks }));

const queue: CheckPrintQueueResponse = {
  items: [{
    key: 'payroll_item:7',
    source_type: 'payroll_item',
    source_id: 7,
    check_number: '4101',
    payee: 'Ada Trainer',
    amount: 800,
    kind: 'employee',
    kind_label: 'Employee check',
    status: 'printed',
    print_count: 1,
    printed_at: '2026-09-22T01:00:00Z',
    eligible: true,
    disabled_reason: null,
  }],
  meta: { total: 1, eligible: 1, unprinted: 0, printed: 1, voided: 0, check_stock_type: 'bottom_check', slot_count: 1 },
};

const savedRun: CheckPrintRun = {
  id: 42,
  pay_period_id: 9,
  status: 'confirmed',
  check_stock_type: 'bottom_check',
  starting_slot: 1,
  selected_count: 1,
  manifest: [{ key: 'payroll_item:7', source_type: 'payroll_item', source_id: 7, check_number: '4101', payee: 'Ada Trainer', amount: '800.00' }],
  filename: 'checks.pdf',
  sha256: 'a'.repeat(64),
  byte_size: 100,
  generated_at: '2026-09-22T01:00:00Z',
  confirmed_at: '2026-09-22T01:05:00Z',
  created_by_id: 1,
  created_by_name: 'Leon',
  confirmed_by_id: 1,
  confirmed_by_name: 'Leon',
  requires_distinct_confirmer: false,
  can_current_user_confirm: true,
  confirmation_state: 'confirmed',
  confirmation_issue: null,
};

const newerSavedRun: CheckPrintRun = {
  ...savedRun,
  id: 43,
  pay_period_id: 10,
  filename: 'newer-checks.pdf',
  generated_at: '2026-09-22T02:00:00Z',
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolver) => { resolve = resolver; });
  return { promise, resolve };
}

describe('UnifiedCheckPrintDialog', () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, 'localStorage', {
      configurable: true,
      value: {
        getItem: vi.fn(() => null),
        setItem: vi.fn(),
        removeItem: vi.fn(),
        clear: vi.fn(),
      },
    });
    apiMocks.printQueue.mockReset().mockResolvedValue(queue);
    apiMocks.printRuns.mockReset().mockResolvedValue({ check_print_runs: [savedRun] });
    apiMocks.printRunPdf.mockReset().mockResolvedValue({ blob: new Blob(['%PDF-1.4']), filename: 'checks.pdf' });
    apiMocks.createPrintRun.mockReset();
    vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:checks');
    vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it('reopens the latest saved package without generating another PDF', async () => {
    const user = userEvent.setup();
    render(<UnifiedCheckPrintDialog open payPeriodId={9} onOpenChange={vi.fn()} onConfirmed={vi.fn()} />);

    expect(await screen.findByText('Generated package #42')).toBeTruthy();
    expect(screen.getByText('Saved package history')).toBeTruthy();
    expect(screen.getAllByText(/Package #42/).length).toBeGreaterThan(0);
    expect(apiMocks.printRuns).toHaveBeenCalledWith(9);
    expect(apiMocks.printRunPdf).toHaveBeenCalledWith(42);
    expect(apiMocks.createPrintRun).not.toHaveBeenCalled();

    await user.click(screen.getByRole('button', { name: 'New package' }));
    await waitFor(() => expect(screen.getByRole('button', { name: 'Generate print package' })).toBeTruthy());
  });

  it('ignores an older PDF response after the active pay period changes', async () => {
    const olderPdf = deferred<{ blob: Blob; filename: string }>();
    const newerPdf = deferred<{ blob: Blob; filename: string }>();
    apiMocks.printRuns.mockImplementation((payPeriodId: number) => Promise.resolve({
      check_print_runs: [payPeriodId === 9 ? savedRun : newerSavedRun],
    }));
    apiMocks.printRunPdf.mockImplementation((runId: number) => runId === savedRun.id ? olderPdf.promise : newerPdf.promise);
    vi.mocked(URL.createObjectURL).mockReturnValue('https://example.test/newer-checks.pdf');

    const { rerender } = render(
      <UnifiedCheckPrintDialog open payPeriodId={9} onOpenChange={vi.fn()} onConfirmed={vi.fn()} />
    );
    await waitFor(() => expect(apiMocks.printRunPdf).toHaveBeenCalledWith(savedRun.id));

    rerender(<UnifiedCheckPrintDialog open payPeriodId={10} onOpenChange={vi.fn()} onConfirmed={vi.fn()} />);
    await waitFor(() => expect(apiMocks.printRunPdf).toHaveBeenCalledWith(newerSavedRun.id));

    const newerBlob = new Blob(['newer PDF']);
    newerPdf.resolve({ blob: newerBlob, filename: newerSavedRun.filename });
    expect(await screen.findByText('Generated package #43')).toBeTruthy();
    await waitFor(() => expect(screen.getByTitle('Check package preview').getAttribute('src')).toBe('https://example.test/newer-checks.pdf'));

    olderPdf.resolve({ blob: new Blob(['older PDF']), filename: savedRun.filename });
    await waitFor(() => expect(URL.createObjectURL).toHaveBeenCalledTimes(1));
    expect(URL.createObjectURL).toHaveBeenCalledWith(newerBlob);
    expect(screen.getByText('Generated package #43')).toBeTruthy();
    expect(screen.getByTitle('Check package preview').getAttribute('src')).toBe('https://example.test/newer-checks.pdf');
  });
});
