import { expect, test, type Page, type Route } from '@playwright/test';
import type { HistoricalImportBatch, HistoricalImportDetail } from '@/services/api';

interface MockWorker {
  id: number;
  source_name: string;
  source_status: 'active' | 'inactive' | 'unknown';
  hire_date: string | null;
  employee_id: number | null;
  employee_name: string | null;
  mapping_status: 'needs_review' | 'exact_match' | 'manual_match' | 'archive_only';
  match_method: string | null;
  match_confidence: number | null;
}

const archive = {
  applied_batch_count: 0,
  paycheck_count: 0,
  worker_count: 0,
  first_pay_date: null,
  last_pay_date: null,
  gross_pay: '0.0',
  net_pay: '0.0',
};

function batch(id: number, workers: MockWorker[] = []): HistoricalImportBatch {
  return {
    id,
    company_id: 1,
    source_system: 'quickbooks_online' as const,
    source_label: `Batch ${id}`,
    bundle_digest: `digest-${id}`,
    importer_version: 'test',
    status: 'previewed' as const,
    source_file_manifest: [],
    preview_summary: {
      file_count: 5,
      worker_count: workers.length,
      period_count: 0,
      paycheck_count: 0,
      check_number_count: 0,
      totals: {
        hours_total: '0.0',
        gross_pay: '0.0',
        adjusted_gross: '0.0',
        pretax_deductions: '0.0',
        employee_taxes: '0.0',
        federal_income_tax: '0.0',
        social_security_tax: '0.0',
        medicare_tax: '0.0',
        after_tax_deductions: '0.0',
        net_pay: '0.0',
        employer_taxes: '0.0',
        employer_contributions: '0.0',
        total_payroll_cost: '0.0',
      },
    },
    reconciliation_summary: { passed: true, errors: [] },
    worker_review_summary: {
      total: workers.length,
      needs_review: workers.filter((worker) => worker.mapping_status === 'needs_review').length,
      linked: workers.filter((worker) => worker.employee_id !== null).length,
      archive_only: workers.filter((worker) => worker.mapping_status === 'archive_only').length,
    },
    warnings: [],
    errors: [],
    created_at: '2026-09-06T00:00:00Z',
  };
}

function detail(id: number, workers: MockWorker[] = []): HistoricalImportDetail {
  return { ...batch(id, workers), periods: [], workers, paychecks: [] };
}

async function fulfillJson(route: Route, body: unknown, status = 200): Promise<void> {
  await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

async function mockApplicationShell(page: Page): Promise<void> {
  await page.route('**/api/v1/auth/me', (route) => fulfillJson(route, {
    user: {
      id: 1,
      email: 'admin@example.com',
      name: 'History Admin',
      role: 'admin',
      organization_id: 1,
      organization_name: 'Test Organization',
      company_id: 1,
      company_name: 'Historical Payroll Company',
      home_company_id: 1,
      assigned_company_ids: [1],
    },
  }));
  await page.route('**/api/v1/companies', (route) => fulfillJson(route, {
    companies: [{
      id: 1,
      name: 'Historical Payroll Company',
      active: true,
      active_employees: 1,
      total_employees: 1,
      pay_frequency: 'biweekly',
      historical_payroll_enabled: true,
    }],
    can_manage_clients: true,
    can_view_client_management: true,
    can_switch_company: false,
    current_company_id: 1,
  }));
  await page.route('**/api/v1/admin/employees**', (route) => fulfillJson(route, {
    data: [{ id: 900, first_name: 'Live', last_name: 'Employee', status: 'active' }],
    meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 200 },
  }));
}

test('keeps every historical batch reachable with simple pagination', async ({ page }) => {
  await mockApplicationShell(page);
  const allBatches = Array.from({ length: 51 }, (_, index) => batch(51 - index));

  await page.route('**/api/v1/admin/historical_imports?**', async (route) => {
    const requestedPage = Number(new URL(route.request().url()).searchParams.get('page') || '1');
    const data = requestedPage === 1 ? allBatches.slice(0, 50) : allBatches.slice(50);
    await fulfillJson(route, {
      data,
      meta: { current_page: requestedPage, total_pages: 2, total_count: 51, per_page: 50, archive },
    });
  });
  await page.route('**/api/v1/admin/historical_imports/*?**', async (route) => {
    const id = Number(new URL(route.request().url()).pathname.split('/').pop());
    await fulfillJson(route, {
      data: detail(id),
      meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
    });
  });

  await page.goto('/historical-payroll');
  await expect(page.getByRole('heading', { name: 'Historical payroll' })).toBeVisible();
  await expect(page.getByText('Batch page 1 of 2 · 51 total')).toBeVisible();
  await expect(page.locator('#historical-batch option')).toHaveCount(50);

  await page.getByRole('button', { name: 'Next batch page' }).click();

  await expect(page.getByText('Batch page 2 of 2 · 51 total')).toBeVisible();
  await expect(page.locator('#historical-batch option')).toHaveCount(1);
  await expect(page.locator('#historical-batch')).toHaveValue('1');
  await expect(page.getByRole('heading', { name: 'Batch 1' })).toBeVisible();
});

test('never lets a completed worker mapping replace a newly selected batch', async ({ page }) => {
  await mockApplicationShell(page);
  const sourceWorker: MockWorker = {
    id: 200,
    source_name: 'Source Worker',
    source_status: 'inactive',
    hire_date: '2024-01-01',
    employee_id: null,
    employee_name: null,
    mapping_status: 'needs_review',
    match_method: null,
    match_confidence: null,
  };
  let releaseMapping: (() => void) | undefined;
  const mappingGate = new Promise<void>((resolve) => { releaseMapping = resolve; });
  const detailRequests: number[] = [];

  await page.route('**/api/v1/admin/historical_imports?**', (route) => fulfillJson(route, {
    data: [batch(2, [sourceWorker]), batch(1)],
    meta: { current_page: 1, total_pages: 1, total_count: 2, per_page: 50, archive },
  }));
  await page.route('**/api/v1/admin/historical_imports/2/workers/200', async (route) => {
    await mappingGate;
    await fulfillJson(route, { data: { ...sourceWorker, employee_id: 900, mapping_status: 'manual_match' } });
  });
  await page.route('**/api/v1/admin/historical_imports/*?**', async (route) => {
    const id = Number(new URL(route.request().url()).pathname.split('/').pop());
    detailRequests.push(id);
    await fulfillJson(route, {
      data: detail(id, id === 2 ? [sourceWorker] : []),
      meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
    });
  });

  await page.goto('/historical-payroll');
  const batchSelector = page.locator('#historical-batch');
  const workerDisposition = page.getByRole('combobox', { name: 'Disposition for Source Worker' });
  await expect(workerDisposition).toBeVisible();

  await workerDisposition.selectOption('900');
  await expect(batchSelector).toBeDisabled();

  // Mapping intentionally disables this control. Bypass it only to simulate an
  // external company/context selection change while the request is still pending.
  await batchSelector.evaluate((node) => {
    const select = node as HTMLSelectElement;
    select.disabled = false;
    select.value = '1';
    select.dispatchEvent(new Event('change', { bubbles: true }));
  });
  await expect(page.getByRole('heading', { name: 'Batch 1' })).toBeVisible();
  await expect(page.getByText('Source Worker')).toHaveCount(0);

  releaseMapping?.();
  await expect(batchSelector).toBeEnabled();
  await expect(page.getByRole('heading', { name: 'Batch 1' })).toBeVisible();
  await expect.poll(() => detailRequests.filter((id) => id === 2).length).toBe(1);
});
