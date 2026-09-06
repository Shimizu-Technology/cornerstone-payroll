import { expect, test, type Page, type Route } from '@playwright/test';
import type { HistoricalClientBootstrap, HistoricalCutoverReview, HistoricalImportBatch, HistoricalImportDetail, HistoricalReport, HistoricalReportType } from '@/services/api';

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

const acceptedArchive = {
  applied_batch_count: 1,
  paycheck_count: 2,
  worker_count: 1,
  first_pay_date: '2024-01-15',
  last_pay_date: '2024-12-31',
  gross_pay: '3000.0',
  net_pay: '2325.0',
};

function historicalReport(reportType: HistoricalReportType): HistoricalReport {
  return {
    report_type: reportType,
    title: reportType === 'taxes' ? 'Historical Tax Detail' : 'Historical Payroll Register',
    description: 'Final payroll facts preserved from QuickBooks.',
    generated_at: '2026-09-06T01:00:00Z',
    source_statement: 'Authoritative QuickBooks snapshots — never recalculated by Cornerstone Payroll',
    filters: { year: null, worker_key: null },
    available_years: [2025, 2024],
    available_workers: [{ key: 'worker alice', name: 'Worker, Alice' }],
    columns: [
      { key: 'pay_date', label: 'Pay date', format: 'date' },
      { key: 'record_kind', label: 'Record type', format: 'text' },
      { key: 'employee', label: 'Employee', format: 'text' },
      { key: 'gross_pay', label: 'Gross pay', format: 'money' },
    ],
    rows: [
      { pay_date: '2024-01-15', record_kind: 'Detailed paycheck', employee: 'Worker, Alice', gross_pay: '1000.0' },
      { pay_date: '2024-12-31', record_kind: 'Opening summary', employee: 'Worker, Alice', gross_pay: '2000.0' },
    ],
    summary: {
      row_count: 2,
      paycheck_count: 2,
      detailed_paycheck_count: 1,
      opening_summary_count: 1,
      totals: { gross_pay: '3000.0', pretax_deductions: '50.0', employee_taxes: '600.0', after_tax_deductions: '25.0', net_pay: '2325.0', employer_taxes: '300.0', employer_contributions: '50.0', total_payroll_cost: '3350.0' },
      detailed_paycheck_totals: { gross_pay: '1000.0', pretax_deductions: '50.0', employee_taxes: '200.0', after_tax_deductions: '25.0', net_pay: '725.0', employer_taxes: '100.0', employer_contributions: '50.0', total_payroll_cost: '1150.0' },
      opening_summary_totals: { gross_pay: '2000.0', pretax_deductions: '0.0', employee_taxes: '400.0', after_tax_deductions: '0.0', net_pay: '1600.0', employer_taxes: '200.0', employer_contributions: '0.0', total_payroll_cost: '2200.0' },
      missing_check_number_count: 2,
    },
    coverage: {
      first_detailed_pay_date: '2024-01-15',
      last_detailed_pay_date: '2024-01-15',
      opening_summary_start: '2024-01-01',
      opening_summary_end: '2024-12-31',
    },
    warnings: ['1 opening summary record covers 2024-01-01 through 2024-12-31. It is shown separately and is not an individual pay period.'],
    provenance: [{
      batch_id: 1,
      source_label: 'MoSa 2024 history',
      status: 'locked',
      bundle_digest: 'a'.repeat(64),
      importer_version: 'test',
      applied_at: '2026-09-06T01:00:00Z',
      locked_at: '2026-09-06T01:05:00Z',
      retained_file_count: 5,
      verified_file_count: 5,
    }],
  };
}

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
    source_retention_summary: {
      expected_file_count: 0,
      retained_file_count: 0,
      verified_file_count: 0,
      failed_file_count: 0,
      ready: false,
      last_verified_at: null,
    },
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

function detailWithVerifiedSource(id: number): HistoricalImportDetail {
  const source = {
    id: 700,
    original_filename: 'Payroll Details.xls',
    content_type: 'application/vnd.ms-excel',
    byte_size: 2048,
    sha256: 'a'.repeat(64),
    report_type: 'payroll_details',
    position: 0,
    verification_status: 'verified' as const,
    verified_at: '2026-09-06T01:00:00Z',
    verification_error: null,
  };
  return {
    ...detail(id),
    source_file_manifest: [{
      position: 0,
      filename: source.original_filename,
      byte_size: source.byte_size,
      sha256: source.sha256,
      report_type: source.report_type,
    }],
    source_retention_summary: {
      expected_file_count: 1,
      retained_file_count: 1,
      verified_file_count: 1,
      failed_file_count: 0,
      ready: true,
      last_verified_at: source.verified_at,
    },
    source_files: [source],
  };
}

function detail(id: number, workers: MockWorker[] = []): HistoricalImportDetail {
  return { ...batch(id, workers), periods: [], workers, paychecks: [] };
}

function cutoverReview(status: 'verified' | 'approved', readyForApproval: boolean): HistoricalCutoverReview {
  const totals = batch(1).preview_summary.totals;
  return {
    id: 80,
    status,
    evidence: {
      version: 1,
      generated_at: '2026-09-06T02:00:00Z',
      passed: true,
      batch_id: 1,
      bundle_digest: 'a'.repeat(64),
      importer_version: 'test',
      verification_parser_version: 'test',
      checks: [
        { key: 'source_bundle', label: 'Retained originals reproduce the recorded bundle', passed: true },
        { key: 'stored_totals', label: 'Stored payroll totals match the retained originals to the cent', passed: true },
      ],
      counts: { worker_count: 1, period_count: 2, paycheck_count: 2 },
      totals,
      years: [{ year: '2024', paycheck_count: 2, detailed_paycheck_count: 1, opening_summary_count: 1, totals }],
      ledger_digests: {
        workers: { source: 'c'.repeat(64), stored: 'c'.repeat(64) },
        periods: { source: 'd'.repeat(64), stored: 'd'.repeat(64) },
        paychecks: { source: 'e'.repeat(64), stored: 'e'.repeat(64) },
      },
      source_files: [{ filename: 'Payroll Details.xls', sha256: 'a'.repeat(64), byte_size: 2048, report_type: 'payroll_details', verified: true }],
      exceptions: [{ key: 'opening-summary', message: 'Opening summaries preserve totals but are not original paycheck-level periods.' }],
      fresh_source_label: 'MoSa 2024 history',
    },
    evidence_digest: 'b'.repeat(64),
    verified_at: '2026-09-06T02:00:00Z',
    verified_by_name: 'History Admin',
    exception_dispositions: readyForApproval ? { 'opening-summary': 'Accepted; detailed coverage begins on the recorded date.' } : {},
    attestations: readyForApproval
      ? { source_restore: true, history_review: true, backup_restore: true, rollback_owner: true }
      : {},
    attestation_labels: {
      source_restore: 'A retained original was downloaded and opened without signing in to QuickBooks.',
      history_review: 'Register, employee, tax, deduction, and check history were reviewed in Cornerstone Payroll.',
      backup_restore: 'The production database and private source-storage backup and restore procedure was rehearsed or approved.',
      rollback_owner: 'A rollback owner can disable historical payroll without deleting the retained evidence.',
    },
    approval_notes: readyForApproval ? 'No remaining limitations.' : null,
    ready_for_approval: readyForApproval,
    approved_at: status === 'approved' ? '2026-09-06T02:05:00Z' : null,
    approved_by_name: status === 'approved' ? 'History Admin' : null,
    approval_acknowledgement: 'I approve this verified QuickBooks history for lock and QuickBooks cutover.',
    updated_at: status === 'approved' ? '2026-09-06T02:05:00Z' : readyForApproval ? '2026-09-06T02:03:00Z' : '2026-09-06T02:00:00Z',
  };
}

function pendingCutoverReview(): HistoricalCutoverReview {
  return {
    ...cutoverReview('verified', false),
    status: 'pending',
    evidence: {},
    evidence_digest: null,
    verified_at: null,
    verified_by_name: null,
    verification_started_at: '2026-09-06T02:00:00Z',
    updated_at: '2026-09-06T02:00:00Z',
  };
}

function clientBootstrap(status: 'previewed' | 'applied' = 'previewed'): HistoricalClientBootstrap {
  return {
    id: 90,
    status,
    plan_digest: 'f'.repeat(64),
    preview_summary: {
      worker_count: 114,
      active_employee_count: 57,
      inactive_employee_count: 57,
      hourly_employee_count: 112,
      variable_pay_employee_count: 2,
      wage_rate_count: 244,
      payroll_field_assignment_count: 32,
      employees_with_recurring_setup_count: 28,
      employees_needing_review_count: 114,
      error_count: 0,
    },
    warnings: [{ message: 'A QuickBooks placeholder deduction was intentionally not activated', worker_count: 3 }],
    errors: [],
    review_items: [{
      code: 'verify_hire_date',
      message: 'QuickBooks hire dates were retained with the source evidence but were not copied into live payroll. Confirm the effective hire date.',
      worker_count: 114,
      historical_worker_ids: [1],
    }],
    ready_to_apply: status === 'previewed',
    applied_at: status === 'applied' ? '2026-09-07T03:00:00Z' : null,
    applied_by_name: status === 'applied' ? 'History Admin' : null,
    acknowledgement: 'PREPARE CLEAN CLIENT EMPLOYEES',
  };
}

function withoutDetailCollections(value: HistoricalImportDetail): HistoricalImportBatch {
  const { periods: _periods, workers: _workers, paychecks: _paychecks, ...payload } = value;
  return payload;
}

function withoutCutoverEvidence(value: HistoricalImportDetail): HistoricalImportBatch {
  const payload = withoutDetailCollections(value);
  if (!payload.cutover_review) return payload;

  const review = { ...payload.cutover_review };
  delete review.evidence;
  return { ...payload, cutover_review: review };
}

async function fulfillJson(route: Route, body: unknown, status = 200): Promise<void> {
  await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

async function mockApplicationShell(page: Page, role: 'admin' | 'accountant' = 'admin'): Promise<void> {
  await page.route('**/api/v1/auth/me', (route) => fulfillJson(route, {
    user: {
      id: 1,
      email: 'admin@example.com',
      name: 'History Admin',
      role,
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
    can_manage_clients: role === 'admin',
    can_view_client_management: role === 'admin',
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
  await expect(page.getByText('No source inventory is attached')).toBeVisible();
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

test('never lets a cancelled verification poll restore the previous batch', async ({ page }) => {
  await mockApplicationShell(page);
  const pendingBatch: HistoricalImportDetail = {
    ...detail(1),
    status: 'applied',
    cutover_review: pendingCutoverReview(),
  };
  const otherBatch: HistoricalImportDetail = {
    ...detail(2),
    status: 'applied',
    cutover_review: null,
  };
  const verifiedBatch: HistoricalImportDetail = {
    ...pendingBatch,
    cutover_review: cutoverReview('verified', false),
  };
  let listRequestCount = 0;
  let fulfilledListResponseCount = 0;
  let detailRequestCount = 0;
  let releasePoll: (() => void) | undefined;
  let markPollStarted: (() => void) | undefined;
  const pollGate = new Promise<void>((resolve) => { releasePoll = resolve; });
  const pollStarted = new Promise<void>((resolve) => { markPollStarted = resolve; });

  await page.route('**/api/v1/admin/historical_imports?**', async (route) => {
    listRequestCount += 1;
    if (listRequestCount === 2) {
      markPollStarted?.();
      await pollGate;
    }
    await fulfillJson(route, {
      data: [withoutCutoverEvidence(listRequestCount >= 2 ? verifiedBatch : pendingBatch), withoutDetailCollections(otherBatch)],
      meta: { current_page: 1, total_pages: 1, total_count: 2, per_page: 50, archive },
    });
    fulfilledListResponseCount += 1;
  });
  await page.route('**/api/v1/admin/historical_imports/*?**', async (route) => {
    const id = Number(new URL(route.request().url()).pathname.split('/').pop());
    if (id === 1) detailRequestCount += 1;
    await fulfillJson(route, {
      data: id === 1 ? (detailRequestCount >= 2 ? verifiedBatch : pendingBatch) : otherBatch,
      meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
    });
  });

  await page.goto('/historical-payroll');
  const batchSelector = page.locator('#historical-batch');
  await expect(batchSelector).toHaveValue('1');
  await pollStarted;

  await batchSelector.selectOption('2');
  await expect(page.getByRole('heading', { name: 'Batch 2' })).toBeVisible();
  releasePoll?.();

  await expect.poll(() => fulfilledListResponseCount).toBeGreaterThanOrEqual(2);
  await page.evaluate(() => new Promise<void>((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
  }));
  await expect(batchSelector).toHaveValue('2');
  await expect(page.getByRole('heading', { name: 'Batch 2' })).toBeVisible();
});

test('keeps checking verification status after a temporary refresh failure', async ({ page }) => {
  await mockApplicationShell(page);
  const pendingBatch: HistoricalImportDetail = {
    ...detail(1),
    status: 'applied',
    cutover_review: pendingCutoverReview(),
  };
  const verifiedBatch: HistoricalImportDetail = {
    ...pendingBatch,
    cutover_review: cutoverReview('verified', false),
  };
  let detailRequestCount = 0;
  let fulfilledDetailResponseCount = 0;
  let failNextDetailRequest = false;
  let pollFailureCount = 0;
  let verificationComplete = false;
  let markPollFailed: (() => void) | undefined;
  const pollFailed = new Promise<void>((resolve) => { markPollFailed = resolve; });

  await page.route('**/api/v1/admin/historical_imports?**', async (route) => {
    await fulfillJson(route, {
      data: [withoutCutoverEvidence(verificationComplete ? verifiedBatch : pendingBatch)],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, archive },
    });
  });
  await page.route('**/api/v1/admin/historical_imports/1?**', async (route) => {
    detailRequestCount += 1;
    if (failNextDetailRequest) {
      failNextDetailRequest = false;
      await fulfillJson(route, { error: 'Temporary status refresh failed.' }, 503);
      pollFailureCount += 1;
      markPollFailed?.();
      return;
    }
    if (pollFailureCount > 0) verificationComplete = true;
    await fulfillJson(route, {
      data: verificationComplete ? verifiedBatch : pendingBatch,
      meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
    });
    fulfilledDetailResponseCount += 1;
  });

  await page.goto('/historical-payroll');
  await expect(page.getByText('Comparing the retained source with the archive')).toBeVisible();
  await expect.poll(() => fulfilledDetailResponseCount).toBeGreaterThanOrEqual(1);
  failNextDetailRequest = true;
  await pollFailed;
  await expect(page.getByRole('alert')).toContainText('Temporary status refresh failed. Retrying automatically.');

  await expect(page.getByText('Checklist needed')).toBeVisible({ timeout: 10_000 });
  await expect(page.getByText('2/2')).toBeVisible();
  await expect(page.getByRole('alert')).toHaveCount(0);
  expect(detailRequestCount).toBeGreaterThanOrEqual(3);
});

test('shows a completed verification even when the batch-list refresh fails', async ({ page }) => {
  await mockApplicationShell(page);
  const pendingBatch: HistoricalImportDetail = {
    ...detail(1),
    status: 'applied',
    cutover_review: pendingCutoverReview(),
  };
  const verifiedBatch: HistoricalImportDetail = {
    ...pendingBatch,
    cutover_review: cutoverReview('verified', false),
  };
  let listRequestCount = 0;
  let detailRequestCount = 0;
  let terminalDetailReturned = false;

  await page.route('**/api/v1/admin/historical_imports?**', async (route) => {
    listRequestCount += 1;
    if (terminalDetailReturned) {
      await fulfillJson(route, { error: 'Temporary batch-list refresh failed.' }, 503);
      return;
    }
    await fulfillJson(route, {
      data: [withoutCutoverEvidence(pendingBatch)],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, archive },
    });
  });
  await page.route('**/api/v1/admin/historical_imports/1?**', async (route) => {
    detailRequestCount += 1;
    terminalDetailReturned = detailRequestCount > 1;
    await fulfillJson(route, {
      data: terminalDetailReturned ? verifiedBatch : pendingBatch,
      meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
    });
  });

  await page.goto('/historical-payroll');
  await expect(page.getByText('Checklist needed')).toBeVisible({ timeout: 10_000 });
  await expect(page.getByText('2/2')).toBeVisible();
  expect(listRequestCount).toBeGreaterThanOrEqual(2);
});

test('makes retained source verification and exact download clear to an administrator', async ({ page }) => {
  await mockApplicationShell(page);
  const retainedDetail = detailWithVerifiedSource(1);

  await page.route('**/api/v1/admin/historical_imports?**', (route) => fulfillJson(route, {
    data: [retainedDetail],
    meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, archive },
  }));
  await page.route('**/api/v1/admin/historical_imports/1?**', (route) => fulfillJson(route, {
    data: retainedDetail,
    meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
  }));
  await page.route('**/api/v1/admin/historical_imports/1/verify_source_files', (route) => fulfillJson(route, {
    data: retainedDetail,
    meta: { all_verified: true },
  }));
  await page.route('**/api/v1/admin/historical_imports/1/source_files/700/download', (route) => route.fulfill({
    status: 200,
    contentType: 'application/vnd.ms-excel',
    headers: { 'Content-Disposition': 'attachment; filename="Payroll Details.xls"' },
    body: 'exact-source-bytes',
  }));

  await page.goto('/historical-payroll');
  await expect(page.getByText('1/1')).toBeVisible();
  await expect(page.getByText('Verified', { exact: true })).toBeVisible();

  await page.getByRole('button', { name: 'Verify all files' }).click();
  await expect(page.getByText('Every retained QuickBooks source file matches its original SHA-256 fingerprint.')).toBeVisible();

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Download original' }).click();
  await expect((await download).suggestedFilename()).toBe('Payroll Details.xls');
  await expect(page.getByText('Payroll Details.xls passed integrity verification and was downloaded.')).toBeVisible();
});

test('previews and creates a clean current-payroll roster without running payroll', async ({ page }): Promise<void> => {
  await mockApplicationShell(page);
  let current: HistoricalImportDetail = detailWithVerifiedSource(1);
  let rosterApplied = false;
  let employeeListRequests = 0;

  await page.unroute('**/api/v1/companies');
  await page.unroute('**/api/v1/admin/employees**');
  await page.route('**/api/v1/companies', (route) => fulfillJson(route, {
    companies: [
      {
        id: 1,
        name: 'Historical Payroll Company',
        active: true,
        active_employees: rosterApplied ? 57 : 1,
        total_employees: rosterApplied ? 114 : 1,
        pay_frequency: 'biweekly',
        historical_payroll_enabled: true,
      },
      {
        id: 2,
        name: 'Another Client',
        active: true,
        active_employees: 1,
        total_employees: 1,
        pay_frequency: 'biweekly',
        historical_payroll_enabled: false,
      },
    ],
    can_manage_clients: true,
    can_view_client_management: true,
    can_switch_company: true,
    current_company_id: 1,
  }));
  await page.route('**/api/v1/admin/employees**', async (route) => {
    employeeListRequests += 1;
    await fulfillJson(route, {
      data: rosterApplied
        ? [{ id: 900, first_name: 'Imported', last_name: 'Employee', status: 'active' }]
        : [{ id: 800, first_name: 'Existing', last_name: 'Employee', status: 'active' }],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 200 },
    });
  });

  await page.route('**/api/v1/admin/historical_imports/1/preview_client_bootstrap', async (route) => {
    current = { ...current, client_bootstrap: clientBootstrap() };
    await fulfillJson(route, { data: current.client_bootstrap });
  });
  await page.route('**/api/v1/admin/historical_imports/1/apply_client_bootstrap', async (route) => {
    expect(route.request().postDataJSON()).toEqual({ acknowledgement: 'PREPARE CLEAN CLIENT EMPLOYEES' });
    rosterApplied = true;
    current = { ...current, client_bootstrap: clientBootstrap('applied') };
    await fulfillJson(route, { data: withoutDetailCollections(current) });
  });
  await page.route('**/api/v1/admin/historical_imports?**', (route) => fulfillJson(route, {
    data: [withoutDetailCollections(current)],
    meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, archive },
  }));
  await page.route('**/api/v1/admin/historical_imports/1?**', (route) => fulfillJson(route, {
    data: current,
    meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
  }));

  await page.goto('/historical-payroll');
  await expect(page.getByRole('heading', { name: 'Prepare this clean client for its next payroll' })).toBeVisible();
  await expect(page.getByText('It makes no changes.')).toBeVisible();
  await expect(page.getByText(/suppresses the incorrect Nevada addresses/)).toBeVisible();

  await page.getByRole('button', { name: 'Preview current setup' }).click();
  await expect(page.getByText('Current employee and recurring-payroll setup is ready for review. No live records were created.')).toBeVisible();
  await expect(page.getByText('114', { exact: true })).toHaveCount(3);
  await expect(page.getByText(/placeholder deduction was intentionally not activated/)).toBeVisible();
  await expect(page.getByRole('button', { name: 'Create employee records' })).toBeEnabled();

  await page.getByRole('button', { name: 'Create employee records' }).click();
  const confirm = page.getByRole('button', { name: 'Create employees' });
  await expect(confirm).toBeDisabled();
  await page.getByLabel('Type the confirmation exactly').fill('PREPARE CLEAN CLIENT EMPLOYEES');
  await expect(confirm).toBeEnabled();
  await confirm.click();

  await expect(page.getByText('Every QuickBooks worker now has a live employee record. Historical payroll remains a preview and no payroll was run.')).toBeVisible();
  await expect(page.getByText('Employees prepared')).toBeVisible();
  await expect(page.getByText(/Prepared .* by History Admin/)).toBeVisible();
  await expect(page.getByRole('button', { name: /Historical Payroll Company 57 employees/ })).toBeVisible();
  expect(employeeListRequests).toBeGreaterThanOrEqual(2);
});

test('makes accepted QuickBooks history easy to filter, understand, and export', async ({ page }): Promise<void> => {
  await mockApplicationShell(page);
  const accepted = { ...detailWithVerifiedSource(1), status: 'locked' as const };
  const reportRequests: URL[] = [];

  await page.route('**/api/v1/admin/historical_imports?**', (route) => fulfillJson(route, {
    data: [accepted],
    meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, archive: acceptedArchive },
  }));
  await page.route('**/api/v1/admin/historical_imports/1?**', (route) => fulfillJson(route, {
    data: accepted,
    meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
  }));
  await page.route('**/api/v1/admin/historical_reports/**', async (route): Promise<void> => {
    const url = new URL(route.request().url());
    const parts = url.pathname.split('/');
    const reportType = parts.at(-1) as HistoricalReportType;
    const extension = parts.at(-1);
    if (extension === 'csv' || extension === 'xlsx' || extension === 'pdf') {
      await route.fulfill({
        status: 200,
        contentType: extension === 'pdf' ? 'application/pdf' : extension === 'csv' ? 'text/csv' : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        headers: { 'Content-Disposition': `attachment; filename="historical_register.${extension}"` },
        body: extension === 'pdf' ? '%PDF-test' : extension === 'xlsx' ? 'PK-test' : 'Pay date,Employee',
      });
      return;
    }

    reportRequests.push(url);
    const report = historicalReport(reportType);
    if (reportType === 'taxes' && !url.searchParams.has('year') && !url.searchParams.has('worker_key')) {
      report.summary.row_count = 13_830;
    }
    await fulfillJson(route, {
      data: report,
      meta: { current_page: 1, total_pages: 1, total_count: 2, per_page: 50 },
    });
  });

  await page.goto('/historical-payroll');
  await expect(page.getByRole('heading', { name: 'Historical reports' })).toBeVisible();
  await expect(page.getByText('Authoritative QuickBooks snapshots — never recalculated by Cornerstone Payroll')).toBeVisible();
  await expect(page.getByText('Opening summary', { exact: true })).toBeVisible();
  await expect(page.getByText(/not an individual pay period/)).toBeVisible();
  await expect(page.getByText('Evidence: 1 accepted source batch · 5 verified original files')).toBeVisible();

  await page.locator('#historical-report-type').selectOption('taxes');
  await expect(page.getByRole('heading', { name: 'Historical Tax Detail' })).toBeVisible();
  await expect(page.getByText('Excel and CSV are ready for this full report. Select a year or worker to make a readable PDF available.')).toBeVisible();
  await page.getByRole('button', { name: 'Export historical report' }).click();
  await expect(page.getByRole('menuitem', { name: /PDF/ })).toHaveCount(0);
  await page.keyboard.press('Escape');

  await page.locator('#historical-report-year').selectOption('2024');
  await page.locator('#historical-report-worker').selectOption('worker alice');
  await expect.poll(() => reportRequests.some((url) => url.searchParams.get('year') === '2024' && url.searchParams.get('worker_key') === 'worker alice')).toBe(true);
  await expect(page.getByText('Excel and CSV are ready for this full report.')).toHaveCount(0);

  await page.getByRole('button', { name: 'Export historical report' }).click();
  const download = page.waitForEvent('download');
  await page.getByRole('menuitem', { name: /Excel workbook/ }).click();
  await expect((await download).suggestedFilename()).toBe('historical-taxes.xlsx');
});

test('guides an administrator through the final no-QuickBooks cutover gate', async ({ page }): Promise<void> => {
  await mockApplicationShell(page);
  let current: HistoricalImportDetail = { ...detailWithVerifiedSource(1), status: 'applied', cutover_review: null };

  await page.route('**/api/v1/admin/historical_imports/1/verify_cutover', async (route) => {
    const pending = { ...current, cutover_review: pendingCutoverReview() };
    await fulfillJson(route, { data: withoutDetailCollections(pending), meta: { enqueued: true, status: 'pending' } }, 202);
    current = { ...current, cutover_review: cutoverReview('verified', false) };
  });
  await page.route('**/api/v1/admin/historical_imports/1/update_cutover_review', async (route) => {
    const payload = route.request().postDataJSON() as {
      exception_dispositions: Record<string, string>;
      attestations: Record<string, boolean>;
      approval_notes: string;
    };
    expect(payload.exception_dispositions['opening-summary']).toContain('Accepted');
    expect(Object.values(payload.attestations)).toEqual([true, true, true, true]);
    expect(payload.approval_notes).toBe('No remaining limitations.');
    current = { ...current, cutover_review: cutoverReview('verified', true) };
    await fulfillJson(route, { data: withoutDetailCollections(current) });
  });
  await page.route('**/api/v1/admin/historical_imports/1/download_cutover_evidence', (route) => route.fulfill({
    status: 200,
    contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    headers: { 'Content-Disposition': 'attachment; filename="quickbooks_cutover_evidence_batch_1.xlsx"' },
    body: 'PK-test',
  }));
  await page.route('**/api/v1/admin/historical_imports/1/approve_cutover', async (route) => {
    expect(route.request().postDataJSON()).toEqual({
      acknowledgement: 'I approve this verified QuickBooks history for lock and QuickBooks cutover.',
    });
    current = { ...current, cutover_review: cutoverReview('approved', true) };
    await fulfillJson(route, { data: withoutDetailCollections(current) });
  });
  await page.route('**/api/v1/admin/historical_imports?**', (route) => fulfillJson(route, {
    data: [withoutCutoverEvidence(current)],
    meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, archive: acceptedArchive },
  }));
  await page.route('**/api/v1/admin/historical_imports/1?**', (route) => fulfillJson(route, {
    data: current,
    meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
  }));

  await page.goto('/historical-payroll');
  await expect(page.getByRole('heading', { name: 'Prove the archive works without QuickBooks' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Complete cutover review' })).toBeDisabled();

  await page.getByRole('button', { name: 'Run final verification' }).click();
  await expect(page.getByText('Final verification started. This page will update automatically')).toBeVisible();
  await expect(page.getByText('Comparing the retained source with the archive')).toBeVisible();
  await expect(page.getByText('2/2')).toBeVisible();
  await expect(page.getByText('Checklist needed')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Approve cutover' })).toBeDisabled();

  await page.getByLabel('Reviewed decision').fill('Accepted; detailed coverage begins on the recorded date.');
  await page.getByRole('button', { name: 'Refresh' }).click();
  await expect(page.getByLabel('Reviewed decision')).toHaveValue('Accepted; detailed coverage begins on the recorded date.');
  for (const checkbox of await page.getByRole('checkbox').all()) await checkbox.check();
  await page.getByLabel('Final review notes').fill('No remaining limitations.');
  await page.getByRole('button', { name: 'Save review' }).click();
  await expect(page.getByText('Cutover review saved and ready for approval.')).toBeVisible();

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Evidence workbook' }).click();
  await expect((await download).suggestedFilename()).toBe('quickbooks_cutover_evidence_batch_1.xlsx');

  await page.getByRole('button', { name: 'Approve cutover' }).click();
  await expect(page.getByRole('heading', { name: 'Approve QuickBooks cutover?' })).toBeVisible();
  await expect(page.getByText('It does not cancel QuickBooks or change live payroll.')).toBeVisible();
  await page.getByRole('button', { name: 'Approve verified cutover' }).click();

  await expect(page.getByText('QuickBooks cutover is approved. The historical batch can now be locked.')).toBeVisible();
  await expect(page.getByText('Approved', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Lock batch' })).toBeEnabled();
});

test('gives an accountant the accepted evidence without import or source-file controls', async ({ page }): Promise<void> => {
  await mockApplicationShell(page, 'accountant');
  const accepted: HistoricalImportDetail = {
    ...detailWithVerifiedSource(1),
    status: 'locked',
    cutover_review: cutoverReview('approved', true),
  };

  await page.route('**/api/v1/admin/historical_imports?**', (route) => fulfillJson(route, {
    data: [withoutCutoverEvidence(accepted)],
    meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, archive: acceptedArchive },
  }));
  await page.route('**/api/v1/admin/historical_imports/1?**', (route) => fulfillJson(route, {
    data: accepted,
    meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
  }));
  await page.route('**/api/v1/admin/historical_reports/**', (route) => fulfillJson(route, {
    data: historicalReport('register'),
    meta: { current_page: 1, total_pages: 1, total_count: 2, per_page: 50 },
  }));

  await page.goto('/historical-payroll');

  await expect(page.getByText('Accountants can review imported history and reconciliation.')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Prove the archive works without QuickBooks' })).toBeVisible();
  await expect(page.getByText('Approved', { exact: true })).toBeVisible();
  await expect(page.getByText(/by History Admin/)).toHaveCount(2);
  await expect(page.getByRole('button', { name: 'Evidence workbook' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Build preview' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Verify all files' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Download original' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Re-run verification' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Save review' })).toHaveCount(0);
});

test('withholds unapproved cutover evidence from an accountant', async ({ page }): Promise<void> => {
  await mockApplicationShell(page, 'accountant');
  const awaitingApproval: HistoricalImportDetail = {
    ...detailWithVerifiedSource(1),
    status: 'applied',
    cutover_review: cutoverReview('verified', false),
  };

  await page.route('**/api/v1/admin/historical_imports?**', (route) => fulfillJson(route, {
    data: [withoutCutoverEvidence(awaitingApproval)],
    meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, archive },
  }));
  await page.route('**/api/v1/admin/historical_imports/1?**', (route) => fulfillJson(route, {
    data: awaitingApproval,
    meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 },
  }));

  await page.goto('/historical-payroll');

  await expect(page.getByText('Checklist needed')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Evidence workbook' })).toHaveCount(0);
});
