// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CheckPrintGeneration, CheckPrintQueueResponse, CheckPrintRun } from '@/types';
import { UnifiedCheckPrintDialog } from './UnifiedCheckPrintDialog';

const apiMocks = vi.hoisted(() => ({
  printQueue: vi.fn(),
  printRuns: vi.fn(),
  activePrintGeneration: vi.fn(),
  printGeneration: vi.fn(),
  printRunPdf: vi.fn(),
  createPrintGeneration: vi.fn(),
  updateCheckNumbers: vi.fn(),
  confirmPrintRun: vi.fn(),
  listPrinterProfiles: vi.fn(),
  selectPrinterProfile: vi.fn(),
  createPrinterProfile: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  checksApi: {
    printQueue: apiMocks.printQueue,
    printRuns: apiMocks.printRuns,
    activePrintGeneration: apiMocks.activePrintGeneration,
    printGeneration: apiMocks.printGeneration,
    printRunPdf: apiMocks.printRunPdf,
    createPrintGeneration: apiMocks.createPrintGeneration,
    updateCheckNumbers: apiMocks.updateCheckNumbers,
    confirmPrintRun: apiMocks.confirmPrintRun,
  },
  printerProfilesApi: {
    list: apiMocks.listPrinterProfiles,
    selectForMe: apiMocks.selectPrinterProfile,
    create: apiMocks.createPrinterProfile,
  },
}));

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
    status: 'unprinted',
    print_count: 0,
    printed_at: null,
    eligible: true,
    disabled_reason: null,
  }],
  meta: {
    total: 1,
    eligible: 1,
    unprinted: 1,
    printed: 0,
    voided: 0,
    check_stock_type: 'bottom_check',
    slot_count: 1,
    printer_profile: { id: 8, name: 'Payroll Room Printer', check_stock_type: 'bottom_check', lock_version: 3, updated_at: '2026-09-22T00:00:00Z' },
  },
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

const generatedRun: CheckPrintRun = {
  ...savedRun,
  status: 'generated',
  confirmed_at: null,
  confirmed_by_id: null,
  confirmed_by_name: null,
  confirmation_state: 'verification_required',
  confirmation_issue: 'Open this package to verify it against current payroll data.',
};

const queuedGeneration: CheckPrintGeneration = {
  id: 90,
  pay_period_id: 9,
  status: 'queued',
  phase: 'queued',
  completed_items: 0,
  total_items: 1,
  error_code: null,
  error_message: null,
  check_print_run_id: null,
  created_at: new Date().toISOString(),
  started_at: null,
  completed_at: null,
  failed_at: null,
};

function renderDialog(props?: Partial<React.ComponentProps<typeof UnifiedCheckPrintDialog>>) {
  return render(
    <MemoryRouter>
      <UnifiedCheckPrintDialog open payPeriodId={9} onOpenChange={vi.fn()} onConfirmed={vi.fn()} {...props} />
    </MemoryRouter>
  );
}

describe('UnifiedCheckPrintDialog', () => {
  beforeEach(() => {
    apiMocks.printQueue.mockReset().mockResolvedValue(queue);
    apiMocks.printRuns.mockReset().mockResolvedValue({ check_print_runs: [] });
    apiMocks.activePrintGeneration.mockReset().mockResolvedValue({ check_print_generation: null });
    apiMocks.printGeneration.mockReset();
    apiMocks.printRunPdf.mockReset().mockResolvedValue({ blob: new Blob(['%PDF-1.4']), filename: 'checks.pdf' });
    apiMocks.createPrintGeneration.mockReset().mockResolvedValue({ check_print_generation: queuedGeneration });
    apiMocks.updateCheckNumbers.mockReset();
    apiMocks.confirmPrintRun.mockReset();
    apiMocks.listPrinterProfiles.mockReset().mockResolvedValue({ printer_profiles: [printerProfile], selections: [], active_printer_profile_id: 8 });
    apiMocks.selectPrinterProfile.mockReset().mockResolvedValue({ selection: { id: 1 } });
    apiMocks.createPrinterProfile.mockReset();
    vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:checks');
    vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it('reopens the latest immutable package without generating another PDF', async () => {
    apiMocks.printRuns.mockResolvedValue({ check_print_runs: [savedRun] });
    renderDialog();

    expect(await screen.findByText('Package #42')).toBeTruthy();
    expect(screen.getByText('Saved package history')).toBeTruthy();
    expect(screen.getByText('A generated package is a saved snapshot')).toBeTruthy();
    expect(apiMocks.printRunPdf).toHaveBeenCalledWith(42);
    expect(apiMocks.createPrintGeneration).not.toHaveBeenCalled();
  });

  it('starts a background generation with a unique key and real selection', async () => {
    const user = userEvent.setup();
    renderDialog();

    await user.click(await screen.findByRole('button', { name: 'Generate and save package' }));

    expect(apiMocks.createPrintGeneration).toHaveBeenCalledWith(9, expect.objectContaining({
      idempotencyKey: expect.any(String),
      printerProfileId: 8,
      printerProfileLockVersion: 3,
      payrollItemIds: [7],
    }));
    expect(await screen.findByText('Generating and saving package')).toBeTruthy();
    expect(screen.getByText(/Safe to close/)).toBeTruthy();
  });

  it('opens a ready generation returned directly by an idempotent create retry', async () => {
    const user = userEvent.setup();
    apiMocks.printRuns
      .mockResolvedValueOnce({ check_print_runs: [] })
      .mockResolvedValueOnce({ check_print_runs: [generatedRun] });
    apiMocks.createPrintGeneration.mockResolvedValue({
      check_print_generation: {
        ...queuedGeneration,
        status: 'ready',
        phase: 'ready',
        completed_items: 1,
        check_print_run_id: generatedRun.id,
        completed_at: new Date().toISOString(),
      },
    });
    renderDialog();

    await user.click(await screen.findByRole('button', { name: 'Generate and save package' }));

    expect(await screen.findByText('Package #42')).toBeTruthy();
    expect(apiMocks.printRunPdf).toHaveBeenCalledWith(42);
    expect(screen.getByRole('button', { name: 'Confirm printed correctly' })).toBeTruthy();
  });

  it('reconnects to an active generation and announces progress', async () => {
    apiMocks.activePrintGeneration.mockResolvedValue({
      check_print_generation: { ...queuedGeneration, status: 'processing', phase: 'rendering', completed_items: 1, total_items: 3 },
    });
    apiMocks.printGeneration.mockResolvedValue({
      check_print_generation: { ...queuedGeneration, status: 'processing', phase: 'rendering', completed_items: 2, total_items: 3 },
    });
    renderDialog();

    expect(await screen.findByText('1 of 3 checks')).toBeTruthy();
    expect(screen.getByRole('progressbar')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Generating package…' }).getAttribute('aria-busy')).toBe('true');
  });

  it('keeps the selection after failure and retries with a new idempotency key', async () => {
    const user = userEvent.setup();
    apiMocks.printGeneration.mockResolvedValue({
      check_print_generation: {
        ...queuedGeneration,
        status: 'failed',
        phase: 'failed',
        error_code: 'generation_failed',
        error_message: 'The package could not be generated. Try again.',
        failed_at: new Date().toISOString(),
      },
    });
    renderDialog();

    await user.click(await screen.findByRole('button', { name: 'Generate and save package' }));
    expect(await screen.findByText('Package not generated', {}, { timeout: 2500 })).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Try again with the same selection' }));

    await waitFor(() => expect(apiMocks.createPrintGeneration).toHaveBeenCalledTimes(2));
    const firstKey = apiMocks.createPrintGeneration.mock.calls[0][1].idempotencyKey;
    const secondKey = apiMocks.createPrintGeneration.mock.calls[1][1].idempotencyKey;
    expect(firstKey).not.toBe(secondKey);
    expect(apiMocks.createPrintGeneration.mock.calls[1][1].payrollItemIds).toEqual([7]);
  });

  it('reuses the pending generation key after a transport failure', async () => {
    const user = userEvent.setup();
    apiMocks.createPrintGeneration
      .mockRejectedValueOnce(new Error('Network connection lost'))
      .mockResolvedValueOnce({ check_print_generation: queuedGeneration });
    renderDialog();

    await user.click(await screen.findByRole('button', { name: 'Generate and save package' }));
    expect(await screen.findByText('Network connection lost')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Generate and save package' }));

    await waitFor(() => expect(apiMocks.createPrintGeneration).toHaveBeenCalledTimes(2));
    expect(apiMocks.createPrintGeneration.mock.calls[0][1].idempotencyKey)
      .toBe(apiMocks.createPrintGeneration.mock.calls[1][1].idempotencyKey);
  });

  it('reconnects to a generation whose start response was lost', async () => {
    const user = userEvent.setup();
    apiMocks.createPrintGeneration.mockRejectedValueOnce(new Error('Request timed out'));
    apiMocks.activePrintGeneration
      .mockResolvedValueOnce({ check_print_generation: null })
      .mockResolvedValueOnce({ check_print_generation: queuedGeneration });
    renderDialog();

    await user.click(await screen.findByRole('button', { name: 'Generate and save package' }));

    expect(await screen.findByText('Generating and saving package')).toBeTruthy();
    expect(screen.queryByText('Request timed out')).toBeNull();
  });

  it('creates a shared printer profile inline and automatically selects it', async () => {
    const user = userEvent.setup();
    const unconfiguredQueue = { ...queue, meta: { ...queue.meta, printer_profile: null } };
    const createdProfile = { ...printerProfile, id: 19, name: 'Front Office Printer', lock_version: 0 };
    apiMocks.printQueue.mockResolvedValueOnce(unconfiguredQueue).mockResolvedValue(queue);
    apiMocks.createPrinterProfile.mockResolvedValue({ printer_profile: createdProfile });
    renderDialog();

    await user.click(await screen.findByRole('button', { name: 'Manage' }));
    await user.click(screen.getByRole('button', { name: 'New profile' }));
    await user.type(screen.getByLabelText('Profile name'), 'Front Office Printer');
    await user.click(screen.getByRole('button', { name: 'Create and use profile' }));

    await waitFor(() => expect(apiMocks.createPrinterProfile).toHaveBeenCalledWith(expect.objectContaining({
      name: 'Front Office Printer',
      check_stock_type: 'bottom_check',
    })));
    await waitFor(() => expect(apiMocks.selectPrinterProfile).toHaveBeenCalledWith('bottom_check', 19));
  });

  it('does not create a duplicate profile when automatic selection fails', async () => {
    const user = userEvent.setup();
    const unconfiguredQueue = { ...queue, meta: { ...queue.meta, printer_profile: null } };
    const createdProfile = { ...printerProfile, id: 19, name: 'Front Office Printer', lock_version: 0 };
    apiMocks.printQueue.mockResolvedValue(unconfiguredQueue);
    apiMocks.createPrinterProfile.mockResolvedValue({ printer_profile: createdProfile });
    apiMocks.selectPrinterProfile
      .mockRejectedValueOnce(new Error('Selection unavailable'))
      .mockResolvedValueOnce({ selection: { id: 2 } });
    renderDialog();

    await user.click(await screen.findByRole('button', { name: 'Manage' }));
    await user.click(screen.getByRole('button', { name: 'New profile' }));
    await user.type(screen.getByLabelText('Profile name'), 'Front Office Printer');
    await user.click(screen.getByRole('button', { name: 'Create and use profile' }));

    expect(await screen.findByText(/profile was created but could not be selected/i)).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Use Front Office Printer' }));

    await waitFor(() => expect(apiMocks.selectPrinterProfile).toHaveBeenCalledTimes(2));
    expect(apiMocks.selectPrinterProfile.mock.calls[1]).toEqual(['bottom_check', 19]);
    expect(apiMocks.createPrinterProfile).toHaveBeenCalledTimes(1);
  });

  it('requires unsaved check-number edits to be discarded before opening history', async () => {
    const user = userEvent.setup();
    const confirmSpy = vi.spyOn(window, 'confirm')
      .mockReturnValueOnce(false)
      .mockReturnValueOnce(true);
    apiMocks.printRuns.mockResolvedValue({ check_print_runs: [savedRun] });
    renderDialog();

    expect(await screen.findByText('Package #42')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Create another package' }));
    const numberInput = await screen.findByRole('textbox', { name: 'Check number for Ada Trainer' });
    await user.clear(numberInput);
    await user.type(numberInput, '4200');
    const historyPackage = screen.getByRole('button', { name: /Package #42 · 1 checks/ });

    await user.click(historyPackage);
    expect(confirmSpy).toHaveBeenCalledTimes(1);
    expect(apiMocks.printRunPdf).toHaveBeenCalledTimes(1);
    expect(screen.getByText('1 unsaved check-number change')).toBeTruthy();

    await user.click(historyPackage);
    await waitFor(() => expect(apiMocks.printRunPdf).toHaveBeenCalledTimes(2));
    expect(screen.queryByText('1 unsaved check-number change')).toBeNull();
  });

  it('ignores a generation response from a closed or replaced workspace', async () => {
    const user = userEvent.setup();
    let resolveGeneration!: (value: { check_print_generation: CheckPrintGeneration }) => void;
    apiMocks.createPrintGeneration.mockReturnValue(new Promise((resolve) => {
      resolveGeneration = resolve;
    }));
    const onOpenChange = vi.fn();
    const onConfirmed = vi.fn();
    const view = render(
      <MemoryRouter>
        <UnifiedCheckPrintDialog open payPeriodId={9} onOpenChange={onOpenChange} onConfirmed={onConfirmed} />
      </MemoryRouter>
    );

    await user.click(await screen.findByRole('button', { name: 'Generate and save package' }));
    await waitFor(() => expect(apiMocks.createPrintGeneration).toHaveBeenCalledTimes(1));
    view.rerender(
      <MemoryRouter>
        <UnifiedCheckPrintDialog open={false} payPeriodId={9} onOpenChange={onOpenChange} onConfirmed={onConfirmed} />
      </MemoryRouter>
    );
    view.rerender(
      <MemoryRouter>
        <UnifiedCheckPrintDialog open payPeriodId={10} onOpenChange={onOpenChange} onConfirmed={onConfirmed} />
      </MemoryRouter>
    );
    resolveGeneration({ check_print_generation: queuedGeneration });

    expect(await screen.findByRole('button', { name: 'Generate and save package' })).toBeTruthy();
    expect(screen.queryByText('Generating and saving package')).toBeNull();
  });

  it('blocks printing and confirmation for an outdated package and offers replacement generation', async () => {
    const outdatedRun: CheckPrintRun = {
      ...savedRun,
      status: 'generated',
      confirmed_at: null,
      confirmation_state: 'outdated',
      confirmation_issue: 'Check #4101 changed after this package was generated.',
    };
    apiMocks.printRuns.mockResolvedValue({ check_print_runs: [outdatedRun] });
    renderDialog();

    expect(await screen.findByText('This package is outdated.')).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Print saved PDF' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.queryByRole('button', { name: 'Confirm printed correctly' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Generate replacement package' })).toBeTruthy();
  });
});
