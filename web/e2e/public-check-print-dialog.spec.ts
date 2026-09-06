import { expect, test, type Page, type Route } from '@playwright/test';

const harnessModule = '/e2e/fixtures/check-print-dialog-harness.tsx';
const queuePattern = '**/admin/pay_periods/703/check_print_queue';

const queueResponse = {
  items: [{
    key: 'payroll_item:901',
    source_type: 'payroll_item',
    source_id: 901,
    check_number: '1001',
    payee: 'Test Employee',
    amount: 100,
    kind: 'employee',
    kind_label: 'Employee',
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
  },
};

interface HeldRequest {
  started: Promise<void>;
  release: () => void;
  cleanup: () => Promise<void>;
}

async function mountHarness(page: Page): Promise<void> {
  await page.goto('/');
  await page.addScriptTag({
    type: 'module',
    content: `import { mountCheckPrintDialogHarness } from '${harnessModule}'; mountCheckPrintDialogHarness();`,
  });
}

async function fulfillQueue(route: Route): Promise<void> {
  await route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify(queueResponse),
  });
}

async function holdAndReject(page: Page, pattern: string, method: string, message: string): Promise<HeldRequest> {
  let signalStarted!: () => void;
  let releaseRequest!: () => void;
  const started = new Promise<void>((resolve) => { signalStarted = resolve; });
  const released = new Promise<void>((resolve) => { releaseRequest = resolve; });
  const handler = async (route: Route): Promise<void> => {
    if (route.request().method() !== method) {
      await route.continue();
      return;
    }

    signalStarted();
    await released;
    await route.fulfill({
      status: 422,
      contentType: 'application/json',
      body: JSON.stringify({ error: message }),
    });
  };
  await page.route(pattern, handler);

  return {
    started,
    release: releaseRequest,
    cleanup: async (): Promise<void> => {
      releaseRequest();
      await page.unroute(pattern, handler);
    },
  };
}

async function expectBusyDialogCannotDismiss(page: Page): Promise<void> {
  const dialog = page.getByRole('dialog', { name: 'Print checks' });
  await page.keyboard.press('Escape');
  await expect(dialog).toBeVisible();
  await page.mouse.click(8, 8);
  await expect(dialog).toBeVisible();
  await dialog.getByRole('button', { name: 'Close' }).click();
  await expect(dialog).toBeVisible();
}

test('check printing blocks every dismissal path while its queue is loading', async ({ page }): Promise<void> => {
  const loadingRequest = await holdAndReject(page, queuePattern, 'GET', 'Queue load failed');
  try {
    await mountHarness(page);
    await loadingRequest.started;
    await expect(page.getByText('Loading check queue…')).toBeVisible();
    await expectBusyDialogCannotDismiss(page);
    loadingRequest.release();
    await expect(page.getByText('Queue load failed')).toBeVisible();
  } finally {
    await loadingRequest.cleanup();
  }
});

test('check printing blocks every dismissal path while generating a package', async ({ page }): Promise<void> => {
  await page.route(queuePattern, fulfillQueue);
  await mountHarness(page);
  const dialog = page.getByRole('dialog', { name: 'Print checks' });
  await expect(dialog.getByRole('button', { name: 'Generate print package' })).toBeEnabled();

  const generationRequest = await holdAndReject(
    page,
    '**/admin/pay_periods/703/check_print_runs',
    'POST',
    'Package generation failed'
  );
  try {
    await dialog.getByRole('button', { name: 'Generate print package' }).click();
    await generationRequest.started;
    await expect(dialog.getByText('Generating an exact print package…')).toBeVisible();
    await expectBusyDialogCannotDismiss(page);
    generationRequest.release();
    await expect(dialog.getByText('Package generation failed')).toBeVisible();
  } finally {
    await generationRequest.cleanup();
  }
});

test('check printing blocks every dismissal path while saving check numbers', async ({ page }): Promise<void> => {
  await page.route(queuePattern, fulfillQueue);
  await mountHarness(page);
  const dialog = page.getByRole('dialog', { name: 'Print checks' });
  await dialog.getByRole('textbox', { name: 'Check number for Test Employee' }).fill('1002');
  await expect(dialog.getByRole('button', { name: 'Save check numbers' })).toBeEnabled();

  const saveRequest = await holdAndReject(
    page,
    '**/admin/pay_periods/703/check_numbers',
    'PATCH',
    'Check number save failed'
  );
  try {
    await dialog.getByRole('button', { name: 'Save check numbers' }).click();
    await saveRequest.started;
    await expect(dialog.getByRole('button', { name: 'Saving…' })).toBeDisabled();
    await expectBusyDialogCannotDismiss(page);
    saveRequest.release();
    await expect(dialog.getByText('Check number save failed')).toBeVisible();
  } finally {
    await saveRequest.cleanup();
  }
});
