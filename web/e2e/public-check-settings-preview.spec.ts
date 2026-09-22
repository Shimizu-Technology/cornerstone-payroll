import { expect, test } from '@playwright/test';

function blankPdf(): Buffer {
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>',
    '<< /Length 0 >>\nstream\n\nendstream',
  ];
  let contents = '%PDF-1.4\n';
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(contents));
    contents += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(contents);
  contents += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  offsets.slice(1).forEach((offset) => { contents += `${String(offset).padStart(10, '0')} 00000 n \n`; });
  contents += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(contents);
}

test('check settings previews draft test checks and alignment PDFs before optional downloads', async ({ page }) => {
  const requested: string[] = [];
  let draftRequest: Record<string, unknown> | null = null;
  let settingsSaves = 0;
  let downloads = 0;
  page.on('download', () => { downloads += 1; });
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith('/auth/me')) return route.fulfill({ json: { user: { id: 1, role: 'admin', name: 'Review Admin', company_id: 1, organization_id: 1, assigned_company_ids: [1] } } });
    if (path.endsWith('/companies')) return route.fulfill({ json: { companies: [{ id: 1, name: 'Synthetic Review Company', active: true }], can_switch_company: false, current_company_id: 1 } });
    if (path.endsWith('/check_settings')) {
      if (route.request().method() !== 'GET') settingsSaves += 1;
      return route.fulfill({ json: { check_settings: {
      check_stock_type: 'top_check', check_offset_x: 0, check_offset_y: 0,
      bank_name: 'Test Bank', bank_address: 'Test Address', check_layout_config: {},
      check_memo_template: '', auto_create_fit_check: false,
      require_distinct_check_print_confirmer: false, next_check_number: 1000,
      } } });
    }
    if (path.endsWith('/check_layout')) return route.fulfill({ json: { check_layout: null } });
    if (path.endsWith('/printer_profiles')) return route.fulfill({ json: { printer_profiles: [], selections: [], active_printer_profile_id: null } });
    if (path.endsWith('/test_check_pdf') || path.endsWith('/alignment_test_pdf')) {
      requested.push(path);
      if (path.endsWith('/test_check_pdf')) draftRequest = route.request().postDataJSON() as Record<string, unknown>;
      return route.fulfill({
        status: 200, contentType: 'application/pdf',
        headers: {
          'access-control-expose-headers': 'Content-Disposition',
          'content-disposition': `attachment; filename="${path.endsWith('/test_check_pdf') ? 'draft_test_check.pdf' : 'alignment_test.pdf'}"`,
        },
        body: blankPdf(),
      });
    }
    return route.fulfill({ json: {} });
  });

  await page.goto('/check-settings');
  await page.locator('#bank-name').fill('Unsaved Draft Bank');
  await page.getByRole('button', { name: 'Preview Test Check' }).click();
  await expect(page.getByRole('heading', { name: 'Test check preview' })).toBeVisible();
  await expect(page.getByRole('dialog').getByText('Nothing is saved until you click Save Settings.')).toBeVisible();
  expect(draftRequest).toMatchObject({ sample_type: 'payroll', check_settings: { bank_name: 'Unsaved Draft Bank' } });
  expect(downloads).toBe(0);
  const testCheckDownload = page.waitForEvent('download');
  await page.getByRole('dialog').getByRole('button', { name: 'Download' }).click();
  expect((await testCheckDownload).suggestedFilename()).toBe('draft_test_check.pdf');
  await page.getByRole('button', { name: 'Close PDF preview' }).click();
  await expect(page.getByRole('heading', { name: 'Test check preview' })).toHaveCount(0);

  await page.getByRole('button', { name: 'Preview Alignment Test PDF' }).click();
  await expect(page.getByRole('heading', { name: 'Alignment test preview' })).toBeVisible();
  expect(downloads).toBe(1);
  const alignmentDownload = page.waitForEvent('download');
  await page.getByRole('dialog').getByRole('button', { name: 'Download' }).click();
  expect((await alignmentDownload).suggestedFilename()).toBe('alignment_test.pdf');
  await page.getByRole('button', { name: 'Close PDF preview' }).click();
  await expect(page.getByRole('heading', { name: 'Alignment test preview' })).toHaveCount(0);
  expect(requested).toEqual([
    '/api/v1/admin/companies/test_check_pdf',
    '/api/v1/admin/companies/alignment_test_pdf',
  ]);
  expect(settingsSaves).toBe(0);
});
