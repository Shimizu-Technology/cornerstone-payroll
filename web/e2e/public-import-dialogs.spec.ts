import { expect, test, type Page, type Route } from '@playwright/test';

const harnessModule = '/e2e/fixtures/import-dialog-harness.tsx';

interface HeldRejection {
  started: Promise<void>;
  release: () => void;
  cleanup: () => Promise<void>;
}

async function mountHarness(page: Page, exportName: string): Promise<void> {
  await page.goto('/');
  await page.addScriptTag({
    type: 'module',
    content: `import { ${exportName} } from '${harnessModule}'; ${exportName}();`,
  });
}

async function holdAndRejectPost(page: Page, pattern: string, error: string): Promise<HeldRejection> {
  let signalStarted!: () => void;
  let releaseRequest!: () => void;
  const started = new Promise<void>((resolve) => { signalStarted = resolve; });
  const released = new Promise<void>((resolve) => { releaseRequest = resolve; });
  const handler = async (route: Route): Promise<void> => {
    if (route.request().method() !== 'POST') {
      await route.continue();
      return;
    }

    signalStarted();
    await released;
    await route.fulfill({
      status: 422,
      contentType: 'application/json',
      body: JSON.stringify({ error }),
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

async function expectBusyDialogCannotDismiss(page: Page, dialogName: RegExp | string): Promise<void> {
  const dialog = page.getByRole('dialog', { name: dialogName });
  await page.keyboard.press('Escape');
  await expect(dialog).toBeVisible();
  await page.mouse.click(8, 8);
  await expect(dialog).toBeVisible();
}

function intakeImport(row: Record<string, unknown>): Record<string, unknown> {
  return {
    id: 901,
    company_id: 1,
    pay_period_id: 702,
    source_type: 'spike_email',
    source_label: 'Regression fixture',
    status: 'previewed',
    import_hash: 'dialog-regression',
    parser_version: 'test-v1',
    warnings: [],
    totals: {},
    created_at: '2026-09-07T00:00:00Z',
    documents: [],
    rows: [row],
  };
}

const matchedIntakeRow = {
  id: 902,
  position: 1,
  status: 'ready',
  excluded: false,
  source_employee_name: 'Existing Employee',
  employee_id: 801,
  employee_name: 'Existing Employee',
  match_method: 'exact',
  match_confidence: 1,
  confidence: 1,
  week1_hours: 40,
  week2_hours: 40,
  extracted_total_hours: 80,
  regular_hours: 80,
  overtime_hours: 0,
  week1_tips: 0,
  week2_tips: 0,
  reported_tips: 0,
  tips_paid_out: 0,
  loan_deduction: 0,
  warnings: [],
  errors: [],
};

const unmatchedIntakeRow = {
  ...matchedIntakeRow,
  id: 903,
  status: 'needs_review',
  source_employee_name: 'New Person',
  employee_id: null,
  employee_name: null,
  match_method: null,
  match_confidence: null,
  errors: [{ code: 'unmatched_employee', message: 'Select or create an employee.', severity: 'error' }],
};

test('ImportModal blocks dismissal while parsing and applying, then recovers after failures', async ({ page }): Promise<void> => {
  await mountHarness(page, 'mountImportModalHarness');
  const dialogName = 'Import Payroll Data';
  const dialog = page.getByRole('dialog', { name: dialogName });
  await expect(dialog).toBeVisible();
  const pdfInput = dialog.locator('input[type="file"]').first();
  await pdfInput.setInputFiles({ name: 'hours.pdf', mimeType: 'application/pdf', buffer: Buffer.from('fixture') });

  const previewFailure = await holdAndRejectPost(page, '**/admin/pay_periods/701/preview_import', 'Preview parsing failed');
  try {
    await dialog.getByRole('button', { name: 'Preview Import' }).click();
    await previewFailure.started;
    await expect(dialog.getByRole('button', { name: 'Cancel' })).toBeDisabled();
    await expectBusyDialogCannotDismiss(page, dialogName);
    previewFailure.release();
    await expect(dialog.getByText('Preview parsing failed')).toBeVisible();
  } finally {
    await previewFailure.cleanup();
  }
  await page.keyboard.press('Escape');
  await expect(dialog).not.toBeVisible();

  await page.getByRole('button', { name: 'Open payroll import' }).click();
  await pdfInput.setInputFiles({ name: 'hours.pdf', mimeType: 'application/pdf', buffer: Buffer.from('fixture') });
  await page.route('**/admin/pay_periods/701/preview_import', async (route): Promise<void> => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        import_id: 904,
        preview: {
          matched: [{
            employee_id: 801,
            employee_name: 'Existing Employee',
            employment_type: 'hourly',
            pay_rate: 12,
            confidence: 1,
            matched_name: 'Existing Employee',
            regular_hours: 80,
            overtime_hours: 0,
            total_hours: 80,
            pdf_employee_name: 'Existing Employee',
            total_tips: 0,
            tip_pool: null,
            loan_deduction: 0,
          }],
          unmatched_pdf_names: [],
          unmatched_excel_names: [],
          duplicate_employee_matches: [],
          low_confidence_matches: [],
          pdf_count: 1,
          excel_count: 0,
          matched_count: 1,
          can_apply: true,
          tips_paid_out_from_tips: false,
        },
      }),
    });
  });
  await dialog.getByRole('button', { name: 'Preview Import' }).click();
  await expect(dialog.getByRole('button', { name: /Apply Import/ })).toBeEnabled();

  const applyFailure = await holdAndRejectPost(page, '**/admin/pay_periods/701/apply_import', 'Import apply failed');
  try {
    await dialog.getByRole('button', { name: /Apply Import/ }).click();
    await applyFailure.started;
    await expect(dialog.getByText('Importing payroll data and calculating taxes...')).toBeVisible();
    await expectBusyDialogCannotDismiss(page, dialogName);
    applyFailure.release();
    await expect(dialog.getByText('Import apply failed')).toBeVisible();
  } finally {
    await applyFailure.cleanup();
  }
  await page.keyboard.press('Escape');
  await expect(dialog).not.toBeVisible();
});

test('PayrollIntakeImportModal guards preview, apply, and nested employee creation', async ({ page }): Promise<void> => {
  await mountHarness(page, 'mountPayrollIntakeModalHarness');
  const dialogName = 'Spike Payroll Intake';
  const dialog = page.getByRole('dialog', { name: dialogName });
  const sourceInput = dialog.getByRole('textbox', { name: 'Paste email body or copied table' });
  await sourceInput.fill('Existing Employee 40 40');

  const previewFailure = await holdAndRejectPost(page, '**/payroll_intake_imports/preview', 'Intake preview failed');
  try {
    await dialog.getByRole('button', { name: 'Preview Intake' }).click();
    await previewFailure.started;
    await expect(dialog.getByRole('button', { name: 'Cancel' })).toBeDisabled();
    await expectBusyDialogCannotDismiss(page, dialogName);
    previewFailure.release();
    await expect(dialog.getByText('Intake preview failed')).toBeVisible();
  } finally {
    await previewFailure.cleanup();
  }
  await page.keyboard.press('Escape');
  await expect(dialog).not.toBeVisible();

  let previewRow: Record<string, unknown> = matchedIntakeRow;
  await page.route('**/payroll_intake_imports/preview', async (route): Promise<void> => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ import: intakeImport(previewRow), duplicate: false }),
    });
  });
  await page.getByRole('button', { name: 'Open payroll intake' }).click();
  await sourceInput.fill('Existing Employee 40 40');
  await dialog.getByRole('button', { name: 'Preview Intake' }).click();
  await expect(dialog.getByRole('button', { name: 'Apply Reviewed Rows' })).toBeEnabled();

  const applyFailure = await holdAndRejectPost(page, '**/payroll_intake_imports/901/apply', 'Intake apply failed');
  try {
    await dialog.getByRole('button', { name: 'Apply Reviewed Rows' }).click();
    await applyFailure.started;
    await expect(dialog.getByText('Applying reviewed payroll intake...')).toBeVisible();
    await expectBusyDialogCannotDismiss(page, dialogName);
    applyFailure.release();
    await expect(dialog.getByText('Intake apply failed')).toBeVisible();
  } finally {
    await applyFailure.cleanup();
  }
  await page.keyboard.press('Escape');
  await expect(dialog).not.toBeVisible();

  previewRow = unmatchedIntakeRow;
  await page.getByRole('button', { name: 'Open payroll intake' }).click();
  await sourceInput.fill('New Person 40 40');
  await dialog.getByRole('button', { name: 'Preview Intake' }).click();
  await dialog.getByRole('button', { name: 'New' }).click();
  const createDialog = page.getByRole('dialog', { name: 'Create employee' });
  await createDialog.getByLabel('Rate').fill('12.50');

  const createFailure = await holdAndRejectPost(page, '**/admin/employees*', 'Employee create failed');
  try {
    await createDialog.getByRole('button', { name: 'Create and map employee' }).click();
    await createFailure.started;
    await expect(createDialog.getByRole('button', { name: 'Cancel' })).toBeDisabled();
    await expectBusyDialogCannotDismiss(page, 'Create employee');
    createFailure.release();
    await expect(createDialog.getByText('Employee create failed')).toBeVisible();
  } finally {
    await createFailure.cleanup();
  }
  await page.keyboard.press('Escape');
  await expect(createDialog).not.toBeVisible();
  await expect(dialog).toBeVisible();
});
