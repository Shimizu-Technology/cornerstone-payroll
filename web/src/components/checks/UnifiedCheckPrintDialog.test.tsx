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
  listPrinterProfiles: vi.fn(),
  selectPrinterProfile: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  checksApi: apiMocks,
  printerProfilesApi: {
    list: apiMocks.listPrinterProfiles,
    selectForMe: apiMocks.selectPrinterProfile,
  },
}));

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
  meta: {
    total: 1,
    eligible: 1,
    unprinted: 0,
    printed: 1,
    voided: 0,
    check_stock_type: 'bottom_check',
    slot_count: 1,
    printer_profile: { id: 8, name: 'Payroll Room Printer', check_stock_type: 'bottom_check', lock_version: 3, updated_at: '2026-09-22T00:00:00Z' },
  },
};

const printerProfile = {
  id: 8,
  organization_id: 2,
  name: 'Payroll Room Printer',
  description: null,
  notes: null,
  check_stock_type: 'bottom_check' as const,
  check_offset_x: 0.125,
  check_offset_y: -0.05,
  check_layout_config: {},
  is_default: false,
  created_by_id: 1,
  created_by_name: 'Leon',
  updated_by_id: 1,
  updated_by_name: 'Leon',
  selection_count: 1,
  selected_for_current_user: true,
  lock_version: 3,
  created_at: '2026-09-22T00:00:00Z',
  updated_at: '2026-09-22T00:00:00Z',
};

const savedRun: CheckPrintRun = {
  id: 42,
  pay_period_id: 9,
  status: 'confirmed',
  check_stock_type: 'bottom_check',
  printer_profile_id: 8,
  printer_profile_name: 'Payroll Room Printer',
  printer_profile_lock_version: 3,
  calibration_digest: 'b'.repeat(64),
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
    apiMocks.listPrinterProfiles.mockReset().mockResolvedValue({ printer_profiles: [], selections: [], active_printer_profile_id: 8 });
    apiMocks.selectPrinterProfile.mockReset();
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

  it('pins the selected printer profile version when generating a package', async () => {
    const user = userEvent.setup();
    apiMocks.printQueue.mockResolvedValue({
      ...queue,
      items: [{ ...queue.items[0], status: 'unprinted', printed_at: null, print_count: 0 }],
      meta: { ...queue.meta, unprinted: 1, printed: 0 },
    });
    apiMocks.printRuns.mockResolvedValue({ check_print_runs: [] });
    apiMocks.createPrintRun.mockResolvedValue({
      check_print_run: { ...savedRun, status: 'generated', confirmed_at: null, confirmation_state: 'ready' },
    });

    render(<UnifiedCheckPrintDialog open payPeriodId={9} onOpenChange={vi.fn()} onConfirmed={vi.fn()} />);

    await user.click(await screen.findByRole('button', { name: 'Generate print package' }));

    expect(apiMocks.createPrintRun).toHaveBeenCalledWith(9, expect.objectContaining({
      printerProfileId: 8,
      printerProfileLockVersion: 3,
      payrollItemIds: [7],
    }));
  });

  it('surfaces profile loading errors and recovers without reopening the dialog', async () => {
    const user = userEvent.setup();
    const printableQueue = {
      ...queue,
      items: [{ ...queue.items[0], status: 'unprinted' as const, printed_at: null, print_count: 0 }],
      meta: { ...queue.meta, unprinted: 1, printed: 0, printer_profile: null },
    };
    apiMocks.printQueue
      .mockResolvedValueOnce(printableQueue)
      .mockResolvedValueOnce({ ...printableQueue, meta: { ...printableQueue.meta, printer_profile: queue.meta.printer_profile } });
    apiMocks.printRuns.mockResolvedValue({ check_print_runs: [] });
    apiMocks.listPrinterProfiles
      .mockRejectedValueOnce(new Error('Profiles unavailable'))
      .mockResolvedValueOnce({ printer_profiles: [printerProfile], selections: [], active_printer_profile_id: null });
    apiMocks.selectPrinterProfile.mockResolvedValue({ selection: { id: 1 } });

    render(<UnifiedCheckPrintDialog open payPeriodId={9} onOpenChange={vi.fn()} onConfirmed={vi.fn()} />);

    expect(await screen.findByText('Profiles unavailable')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Retry printer profiles' }));
    await user.selectOptions(screen.getByRole('combobox', { name: 'Printer profile' }), '8');

    await waitFor(() => expect(apiMocks.selectPrinterProfile).toHaveBeenCalledWith('bottom_check', 8));
    await waitFor(() => expect((screen.getByRole('button', { name: 'Generate print package' }) as HTMLButtonElement).disabled).toBe(false));
  });
});
