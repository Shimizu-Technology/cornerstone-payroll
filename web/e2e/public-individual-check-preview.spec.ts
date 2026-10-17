import { expect, test } from '@playwright/test';
import { twoPagePdf } from './fixtures/synthetic-pdf';

const check = { id: 42, pay_period_id: 8, employee_id: 1, employee_name: 'Avery Example', check_number: '8101', check_status: 'prepared', reconciliation_status: 'prepared', check_print_count: 0, voided: false, gross_pay: 1200, net_pay: 960, events: [] };
const otherCheck = { id: 43, pay_period_id: 8, company_id: 1, payable_to: 'Synthetic Vendor', amount: 100, check_number: '8102', check_type: 'vendor', payment_method: 'check', payment_period_type: 'none', line_items: [], print_count: 0, voided: false, check_status: 'prepared', created_at: '2026-10-08T01:00:00Z', updated_at: '2026-10-08T01:00:00Z' };

for (const width of [1280, 390]) {
  for (const surface of ['payroll', 'period', 'payments'] as const) {
    test(`${surface} original check and voucher paint at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 844 });
      const mutations: string[] = [];
      const pdfRequests: string[] = [];
      await page.route('**/api/v1/**', async (route) => {
        const request = route.request();
        const path = new URL(request.url()).pathname;
        if (request.method() !== 'GET') { mutations.push(`${request.method()} ${path}`); await route.abort(); return; }
        if (path.endsWith('/check') || path.endsWith('/check_pdf') || path.endsWith('/voucher_pdf')) {
          pdfRequests.push(path);
          await route.fulfill({ contentType: 'application/pdf', body: twoPagePdf() }); return;
        }
        let result: unknown = {};
        if (path.endsWith('/checks')) result = { checks: [check], direct_deposit_items: [], earnings_statement_items: [], meta: { total: 1, prepared: 1, unprinted: 0, printed: 0, delivered: 0, voided: 0, check_stock_type: 'bottom_check' } };
        else if (path.endsWith('/non_employee_checks')) result = { non_employee_checks: [otherCheck] };
        else if (path.endsWith('/companies/1')) result = { company: { id: 1, name: 'Synthetic Client', check_stock_type: 'bottom_check' } };
        else if (path.endsWith('/check_register')) result = { check_register: { rows: [], summary: {} } };
        else if (path.endsWith('/payroll_liability_center')) result = { payroll_liability_center: null };
        await route.fulfill({ json: result });
      });
      await page.goto('/');
      await page.addScriptTag({ type: 'module', content: `import { mountIndividualCheckHarness } from '/e2e/fixtures/individual-check-preview-harness.tsx'; mountIndividualCheckHarness('${surface}');` });
      await page.getByRole('button', { name: 'Preview', exact: true }).first().click();
      const dialog = page.getByRole('dialog');
      await expect(dialog).toBeVisible();
      const canvas = dialog.getByLabel('Page 1 preview');
      await expect(canvas).toHaveAttribute('aria-hidden', 'false');
      await expect.poll(async () => canvas.evaluate((el) => Array.from((el as HTMLCanvasElement).getContext('2d')!.getImageData(175, 175, 1, 1).data))).toEqual([255, 0, 0, 255]);
      await expect(dialog.locator('iframe')).toHaveCount(0);
      await expect(dialog.getByRole('button', { name: 'Open to print', exact: true })).toBeVisible();
      await expect(dialog.getByRole('button', { name: 'Download', exact: true })).toBeVisible();
      if (surface === 'payroll') {
        await expect(dialog.getByRole('button', { name: 'Print Stub', exact: true })).toBeVisible();
        await expect(dialog.getByRole('button', { name: 'Download Stub', exact: true })).toBeVisible();
      }
      await dialog.getByRole('button', { name: 'Zoom in' }).click();
      await dialog.getByRole('button', { name: 'Fit page' }).click();
      await dialog.getByRole('button', { name: 'Close PDF preview' }).click();
      await expect(dialog).toHaveCount(0);
      await page.getByRole('button', { name: 'Preview', exact: true }).first().click();
      await expect(page.getByLabel('Page 1 preview')).toHaveAttribute('aria-hidden', 'false');
      await page.getByRole('button', { name: 'Close PDF preview' }).click();
      if (surface === 'payments') {
        await page.getByRole('button', { name: 'Voucher', exact: true }).click();
        await expect(page.getByRole('dialog', { name: 'Payment voucher' })).toBeVisible();
        await expect(page.getByLabel('Page 1 preview')).toHaveAttribute('aria-hidden', 'false');
        await page.getByRole('button', { name: 'Close PDF preview' }).click();
        expect(pdfRequests.some((path) => path.endsWith('/voucher_pdf'))).toBe(true);
      }
      expect(pdfRequests.filter((path) => (path.endsWith('/check') || path.endsWith('/check_pdf')))).toHaveLength(2);
      expect(mutations).toEqual([]);
    });
  }
}
