import { expect, test, type Page } from '@playwright/test';
import type { SavedTransmittal, TransmittalPreview } from '../src/services/api';

const previewPattern = '**/admin/reports/transmittal_preview?*';
const modulePath = '/e2e/fixtures/reports-followup-harness.tsx';

function preview(notes: string[] | null, totalFica = 1234.56, fit = 789.12): TransmittalPreview {
  const saved: SavedTransmittal | null = notes === null ? null : {
    notes,
    preparer_name: 'Saved preparer',
    transmittal_date: '2026-05-01',
    report_list: ['Payroll Summary by Employee'],
    check_number_first: null,
    check_number_last: null,
    payroll_check_numbers: [],
    non_employee_check_numbers: {},
    custom_entries: [],
    generated_at: '2026-05-01T00:00:00Z',
    updated_by_id: 1,
    created_at: '2026-05-01T00:00:00Z',
    updated_at: '2026-05-01T00:00:00Z',
  };
  return {
    payroll_checks: { count: 0, first: null, last: null, numbers: [], ranges: '' },
    non_employee_checks: [],
    tax_totals: {
      fit, total_fica: totalFica, total_drt_deposit: fit,
      employee_ss: 0, employer_ss: 0, employee_medicare: 0, employer_medicare: 0,
    },
    saved_transmittal: saved,
  };
}

async function mountPanel(page: Page, response: TransmittalPreview): Promise<{ failPreview: () => void }> {
  let fail = false;
  await page.route(previewPattern, async (route) => {
    await route.fulfill({
      status: fail ? 503 : 200,
      contentType: 'application/json',
      body: JSON.stringify(fail ? { error: 'Preview unavailable' } : response),
    });
  });
  await page.route('**/admin/reports/check_signoff_preview?*', async (route) => {
    await route.fulfill({ json: { company_name: 'Test client', entries: [], saved_signoff: null } });
  });
  await page.goto('/');
  const initialPreview = page.waitForResponse((response) => response.url().includes('/admin/reports/transmittal_preview'));
  await page.addScriptTag({
    type: 'module',
    content: `import { mountReportsDownloadPanelHarness } from '${modulePath}'; mountReportsDownloadPanelHarness();`,
  });
  await initialPreview;
  return { failPreview: () => { fail = true; } };
}

async function openEditor(page: Page, saved: boolean): Promise<void> {
  const row = page.getByText('Full Print Package', { exact: true }).locator('../..');
  const response = page.waitForResponse((response) => response.url().includes('/admin/reports/transmittal_preview'));
  await row.getByRole('button', { name: saved ? 'Edit' : 'View', exact: true }).click();
  await response;
  await expect(page.getByRole('heading', { name: 'Edit Full Print Package', exact: true })).toBeVisible();
  await expect(page.getByText('Loading transmittal data...', { exact: true })).toHaveCount(0);
  await expect(page.getByPlaceholder('Add a note...')).toBeVisible();
}

async function expectNotes(page: Page, expected: string[]): Promise<void> {
  const fields = page.getByText('Notes', { exact: true }).locator('..').locator('input:not([placeholder])');
  await expect(fields).toHaveCount(expected.length);
  for (const [index, value] of expected.entries()) await expect(fields.nth(index)).toHaveValue(value);
}

for (const notes of [
  ['  Keep the signed original.  ', '', 'Call Sara before releasing checks.'],
  [],
]) {
  test(`saved transmittal ${notes.length ? 'notes are preserved verbatim' : 'empty notes stay empty'} despite positive tax totals`, async ({ page }) => {
    await mountPanel(page, preview(notes));
    await openEditor(page, true);
    await expectNotes(page, notes);
  });
}

for (const { fica, fit, expected } of [
  { fica: 1234.56, fit: 789.12, expected: [
    'FICA Obligation (Social Security & Medicare): $1,234.56',
    'FIT Deposit Total: $789.12 — check to Treasurer of Guam for DRT',
  ] },
  { fica: 1234.56, fit: 0, expected: ['FICA Obligation (Social Security & Medicare): $1,234.56'] },
  { fica: 0, fit: 789.12, expected: ['FIT Deposit Total: $789.12 — check to Treasurer of Guam for DRT'] },
  { fica: 0, fit: 0, expected: [] },
]) {
  test(`new transmittal notes contain only positive computed tax totals (FICA ${fica}, FIT ${fit})`, async ({ page }) => {
    await mountPanel(page, preview(null, fica, fit));
    await openEditor(page, false);
    // Exact contents/count also reject the old client EFTPS and 401K responsibility defaults.
    await expectNotes(page, expected);
  });
}

test('preview failure clears prior initialized notes and leaves no fallback instructions', async ({ page }) => {
  const { failPreview } = await mountPanel(page, preview(null));
  await openEditor(page, false);
  await expectNotes(page, [
    'FICA Obligation (Social Security & Medicare): $1,234.56',
    'FIT Deposit Total: $789.12 — check to Treasurer of Guam for DRT',
  ]);
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Edit Full Print Package', exact: true })).toHaveCount(0);
  failPreview();
  await openEditor(page, false);
  await expectNotes(page, []);
});

test.describe('AIRE record timestamps', () => {
  test.use({ timezoneId: 'America/Los_Angeles' });
  test('timestamps use Guam time and missing dates keep their fallback', async ({ page }) => {
    await page.goto('/');
    await page.addScriptTag({
      type: 'module',
      content: `import { mountAireRecordsHarness } from '${modulePath}'; mountAireRecordsHarness();`,
    });
    const dialog = page.getByRole('dialog', { name: 'Linked AIRE records' });
    const value = (label: string) => dialog.getByText(label, { exact: true }).locator('..').locator('dd');
    await expect(value('Source cutoff')).toHaveText(/May 1, 2026, 6:00:00 AM (GMT\+10|ChST)/);
    await expect(value('Imported')).toHaveText(/May 1, 2026, 6:30:00 AM (GMT\+10|ChST)/);
    await expect(value('Reconciled')).toHaveText('Not recorded');
    await expect(value('Status confirmed at')).toHaveText('Not recorded');
  });
});
