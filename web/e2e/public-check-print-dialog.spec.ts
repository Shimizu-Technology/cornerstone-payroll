import { expect, test, type Page, type Route } from '@playwright/test';

const harnessModule = '/e2e/fixtures/check-print-dialog-harness.tsx';
const queuePattern = '**/admin/pay_periods/703/check_print_queue';

const queueResponse = {
  items: [{ key: 'payroll_item:901', source_type: 'payroll_item', source_id: 901, check_number: '1001', payee: 'Test Employee', amount: 100, kind: 'employee', kind_label: 'Employee', status: 'unprinted', print_count: 0, printed_at: null, eligible: true, disabled_reason: null }],
  meta: {
    total: 1, eligible: 1, unprinted: 1, printed: 0, voided: 0, check_stock_type: 'bottom_check', slot_count: 1,
    printer_profile: { id: 8, name: 'Payroll Room Printer', check_stock_type: 'bottom_check', lock_version: 3, updated_at: '2026-09-22T00:00:00Z' },
  },
};

const printerProfile = {
  id: 8, organization_id: 2, name: 'Payroll Room Printer', description: null, notes: null,
  check_stock_type: 'bottom_check', check_offset_x: 0.125, check_offset_y: -0.05,
  check_layout_config: {}, is_default: false, created_by_id: 1, created_by_name: 'Leon',
  updated_by_id: 1, updated_by_name: 'Leon', selection_count: 1, selected_for_current_user: true,
  lock_version: 3, created_at: '2026-09-22T00:00:00Z', updated_at: '2026-09-22T00:00:00Z',
};

interface HeldRequest {
  started: Promise<void>;
  release: () => void;
  cleanup: () => Promise<void>;
}

async function mountHarness(page: Page): Promise<void> {
  await page.goto('/');
  await page.addScriptTag({ type: 'module', content: `import { mountCheckPrintDialogHarness } from '${harnessModule}'; mountCheckPrintDialogHarness();` });
}

async function fulfillJson(route: Route, body: unknown, status = 200): Promise<void> {
  await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

async function routeWorkspace(page: Page): Promise<void> {
  await page.route('**/admin/printer_profiles', (route) => fulfillJson(route, { printer_profiles: [printerProfile], selections: [], active_printer_profile_id: 8 }));
  await page.route('**/admin/pay_periods/703/check_print_runs', (route) => fulfillJson(route, { check_print_runs: [] }));
  await page.route('**/admin/pay_periods/703/check_print_generations/active', (route) => fulfillJson(route, { check_print_generation: null }));
}

async function holdAndReject(page: Page, pattern: string, method: string, message: string): Promise<HeldRequest> {
  let signalStarted!: () => void;
  let releaseRequest!: () => void;
  const started = new Promise<void>((resolve) => { signalStarted = resolve; });
  const released = new Promise<void>((resolve) => { releaseRequest = resolve; });
  const handler = async (route: Route): Promise<void> => {
    if (route.request().method() !== method) return route.continue();
    signalStarted();
    await released;
    await fulfillJson(route, { error: message }, 422);
  };
  await page.route(pattern, handler);
  return { started, release: releaseRequest, cleanup: async () => { releaseRequest(); await page.unroute(pattern, handler); } };
}

test('check printing uses a structured loading workspace and still allows closing', async ({ page }): Promise<void> => {
  await routeWorkspace(page);
  const loadingRequest = await holdAndReject(page, queuePattern, 'GET', 'Queue load failed');
  try {
    await mountHarness(page);
    await loadingRequest.started;
    const dialog = page.getByRole('dialog', { name: 'Print checks' });
    await expect(dialog.getByLabel('Loading check print workspace')).toBeVisible();
    await dialog.getByRole('button', { name: 'Close' }).click();
    await expect(dialog).toBeHidden();
  } finally {
    await loadingRequest.cleanup();
  }
});

test('printer profiles stay usable at laptop height and expose inline creation', async ({ page }): Promise<void> => {
  await page.setViewportSize({ width: 1366, height: 768 });
  await routeWorkspace(page);
  await page.route(queuePattern, (route) => fulfillJson(route, queueResponse));
  await mountHarness(page);

  const workspace = page.getByRole('dialog', { name: 'Print checks' });
  await workspace.getByRole('button', { name: 'Manage' }).click();
  const manager = page.getByRole('dialog', { name: 'Printer profiles' });
  await expect(manager).toBeVisible();
  await expect(manager.getByRole('button', { name: 'Done' })).toBeVisible();
  await manager.getByRole('button', { name: 'New profile' }).click();
  await manager.getByRole('textbox', { name: 'Profile name' }).fill('Accounting Office Canon');
  await expect(manager.getByRole('button', { name: 'Create and use profile' })).toBeEnabled();
});

test('check printing shows a stable starting state and can close without cancelling generation', async ({ page }): Promise<void> => {
  await routeWorkspace(page);
  await page.route(queuePattern, (route) => fulfillJson(route, queueResponse));
  const generationRequest = await holdAndReject(page, '**/admin/pay_periods/703/check_print_generations', 'POST', 'Package generation failed');
  try {
    await mountHarness(page);
    const dialog = page.getByRole('dialog', { name: 'Print checks' });
    await dialog.getByRole('button', { name: 'Generate and save package' }).click();
    await generationRequest.started;
    await expect(dialog.getByRole('button', { name: 'Starting generation…' })).toBeDisabled();
    await dialog.getByRole('button', { name: 'Close' }).click();
    await expect(dialog).toBeHidden();
  } finally {
    await generationRequest.cleanup();
  }
});

test('check printing reports durable background progress and allows every close path', async ({ page }): Promise<void> => {
  await routeWorkspace(page);
  await page.route(queuePattern, (route) => fulfillJson(route, queueResponse));
  const generation = {
    id: 90, pay_period_id: 703, status: 'queued', phase: 'queued', completed_items: 0, total_items: 1,
    error_code: null, error_message: null, check_print_run_id: null, created_at: new Date().toISOString(),
    started_at: null, completed_at: null, failed_at: null,
  };
  await page.route('**/admin/pay_periods/703/check_print_generations', (route) => fulfillJson(route, { check_print_generation: generation }, 202));
  await page.route('**/admin/pay_periods/703/check_print_generations/90', (route) => fulfillJson(route, { check_print_generation: { ...generation, status: 'processing', phase: 'rendering' } }));
  await mountHarness(page);
  const dialog = page.getByRole('dialog', { name: 'Print checks' });
  await dialog.getByRole('button', { name: 'Generate and save package' }).click();
  await expect(dialog.getByText('Generating and saving package')).toBeVisible();
  await expect(dialog.getByText(/Safe to close/)).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(dialog).toBeHidden();
});

test('check printing blocks dismissal only while saving check-number mutations', async ({ page }): Promise<void> => {
  await routeWorkspace(page);
  await page.route(queuePattern, (route) => fulfillJson(route, queueResponse));
  await mountHarness(page);
  const dialog = page.getByRole('dialog', { name: 'Print checks' });
  await dialog.getByRole('textbox', { name: 'Check number for Test Employee' }).fill('1002');
  const saveRequest = await holdAndReject(page, '**/admin/pay_periods/703/check_numbers', 'PATCH', 'Check number save failed');
  try {
    await dialog.getByRole('button', { name: 'Save check numbers' }).click();
    await saveRequest.started;
    await expect(dialog.getByRole('button', { name: 'Saving…' })).toBeDisabled();
    await page.keyboard.press('Escape');
    await expect(dialog).toBeVisible();
    await dialog.getByRole('button', { name: 'Close' }).click();
    await expect(dialog).toBeVisible();
    saveRequest.release();
    await expect(dialog.getByText('Check number save failed')).toBeVisible();
  } finally {
    await saveRequest.cleanup();
  }
});
