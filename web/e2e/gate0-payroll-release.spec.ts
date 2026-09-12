import { expect, request as playwrightRequest, test, type APIRequestContext, type APIResponse, type Page, type Route } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

interface Gate0Fixture {
  schema_version: number;
  company_id: number;
  other_company_id: number;
  admin_email: string;
  super_admin_email: string;
  manager_email: string;
  accountant_email: string;
  client_email: string;
  inactive_user_email: string;
  employee_id: number;
  client_employee_id: number;
  other_employee_id: number;
  historical_import_batch_id: number;
  historical_pay_period_id: number;
  historical_paycheck_id: number;
  bonus_sync_pay_period_id: number;
  bonus_alpha_employee_id: number;
  bonus_alpha_payroll_item_id: number;
  bonus_beta_employee_id: number;
  bonus_beta_payroll_item_id: number;
  historical_hourly_contractor_employee_id: number;
  historical_hourly_contractor_payroll_item_id: number;
  register_reconciliation_field_name: string;
  register_reconciliation_field_total: number;
  workflow_pay_period_id: number;
  workflow_payroll_item_id: number;
  filter_race_pay_period_id: number;
  mutation_race_pay_period_id: number;
  time_import_pay_period_id: number;
  time_tracking_source_id: number;
  first_time_import_id: number;
  retry_time_import_id: number;
  safe_payroll_import_period_id: number;
  blocked_payroll_import_period_id: number;
  import_typo_employee_id: number;
  import_typo_employee_rate: number;
  safe_payroll_import_pdf_path: string;
  safe_payroll_import_workbook_path: string;
  blocked_payroll_import_pdf_path: string;
  blocked_payroll_import_workbook_path: string;
  original_client_pay_rate: number;
  original_client_ssn_last_four: string;
}

function loadFixture(): Gate0Fixture {
  if (process.env.E2E_RELEASE_LANE !== 'true') {
    throw new Error('The Gate 0 payroll release suite requires E2E_RELEASE_LANE=true.');
  }

  const fixturePath = process.env.E2E_FIXTURE_PATH || resolve(process.cwd(), '.e2e-fixtures/release.json');
  const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as Gate0Fixture;
  if (fixture.schema_version !== 1) {
    throw new Error(`Unsupported Gate 0 fixture schema: ${fixture.schema_version}`);
  }
  return fixture;
}

async function responseJson(response: APIResponse): Promise<Record<string, unknown>> {
  return await response.json() as Record<string, unknown>;
}

async function waitForUiCommit(page: Page): Promise<void> {
  await page.evaluate((): Promise<void> => new Promise<void>((resolve): void => {
    requestAnimationFrame((): void => {
      requestAnimationFrame((): void => resolve());
    });
  }));
}

test.describe('Gate 0 deterministic payroll release lane', () => {
  test.describe.configure({ mode: 'serial' });

  const fixture = loadFixture();
  const apiBaseUrl = process.env.E2E_API_URL || `http://127.0.0.1:${process.env.E2E_API_PORT || '4317'}/api/v1/`;
  let adminApi: APIRequestContext;
  let accountantApi: APIRequestContext;
  let clientApi: APIRequestContext;

  test.beforeAll(async () => {
    adminApi = await playwrightRequest.newContext({
      baseURL: apiBaseUrl,
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    clientApi = await playwrightRequest.newContext({
      baseURL: apiBaseUrl,
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.client_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    accountantApi = await playwrightRequest.newContext({
      baseURL: apiBaseUrl,
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.accountant_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
  });

  test.afterAll(async () => {
    await adminApi.dispose();
    await accountantApi.dispose();
    await clientApi.dispose();
  });

  test('fully hides and restores the desktop sidebar without changing mobile navigation', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      viewport: { width: 1280, height: 800 },
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const page = await context.newPage();
    await page.goto('/app');

    const sidebar = page.locator('aside');
    await expect(sidebar).toBeVisible();
    await page.getByRole('button', { name: 'Collapse sidebar' }).click();
    await expect(sidebar).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Show sidebar' })).toBeVisible();
    expect(await page.getByTestId('app-shell').evaluate((root) => getComputedStyle(root).getPropertyValue('--sidebar-width'))).toBe('0rem');
    expect(await page.evaluate(() => localStorage.getItem('sidebar-collapsed'))).toBe('true');

    await page.reload();
    await expect(page.getByRole('button', { name: 'Show sidebar' })).toBeVisible();
    await page.getByRole('button', { name: 'Show sidebar' }).click();
    await expect(sidebar).toBeVisible();
    expect(await page.evaluate(() => localStorage.getItem('sidebar-collapsed'))).toBe('false');

    await page.keyboard.press('Control+b');
    await expect(page.getByRole('button', { name: 'Show sidebar' })).toBeVisible();
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(page.getByRole('button', { name: 'Show sidebar' })).toBeHidden();
    await expect(page.getByRole('button', { name: 'Open navigation' })).toBeVisible();
    await page.getByRole('button', { name: 'Open navigation' }).click();
    await expect(page.getByRole('dialog')).toBeVisible();

    await context.close();
  });

  test('opens a recent payroll from the dashboard by keyboard', async ({ page }): Promise<void> => {
    await page.route('**/api/v1/admin/reports/dashboard', async (route): Promise<void> => {
      const response = await route.fetch();
      const body = await response.json() as { stats: Record<string, unknown> };
      body.stats.recent_payrolls = [{
        id: fixture.workflow_pay_period_id,
        period_description: 'Keyboard test payroll',
        pay_date: '2026-09-04',
        employee_count: 1,
        total_net: 1234.56,
      }];
      await route.fulfill({ response, json: body });
    });
    await page.goto('/app');
    const recentPayrollLink = page.getByRole('link', { name: /^Open payroll / }).first();
    await expect(recentPayrollLink).toBeVisible();
    const destination = await recentPayrollLink.getAttribute('href');
    expect(destination).toMatch(new RegExp(`^/companies/${fixture.company_id}/pay-runs/\\d+/overview`));

    await recentPayrollLink.focus();
    await page.keyboard.press('Enter');
    await expect(page).toHaveURL(new RegExp(`${destination?.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`));
    await expect(page.getByRole('heading', { name: /^Pay Period:/ })).toBeVisible();
  });

  test('keeps the current payroll item visible when route loads resolve out of order', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const page = await context.newPage();
    let markDelayedItemStarted: (() => void) | undefined;
    let releaseDelayedItem: (() => void) | undefined;
    const delayedItemStarted = new Promise<void>((resolve): void => { markDelayedItemStarted = resolve; });
    const delayedItemReleased = new Promise<void>((resolve): void => { releaseDelayedItem = resolve; });
    const delayedItemPath = `/api/v1/admin/pay_periods/${fixture.workflow_pay_period_id}/payroll_items/${fixture.workflow_payroll_item_id}`;

    await page.route(`**${delayedItemPath}`, async (route): Promise<void> => {
      const response = await route.fetch();
      markDelayedItemStarted?.();
      await delayedItemReleased;
      await route.fulfill({ response });
    });

    await page.goto(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/payroll-items/${fixture.workflow_payroll_item_id}`);
    await delayedItemStarted;
    const currentPath = `/companies/${fixture.company_id}/pay-runs/${fixture.bonus_sync_pay_period_id}/payroll-items/${fixture.bonus_alpha_payroll_item_id}`;
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, currentPath);
    await expect(page.getByText(`Payroll item #${fixture.bonus_alpha_payroll_item_id}`)).toBeVisible();

    const delayedItemResponseDelivered = page.waitForResponse((response): boolean => (
      new URL(response.url()).pathname === delayedItemPath
    ));
    releaseDelayedItem?.();
    await delayedItemResponseDelivered;
    await waitForUiCommit(page);
    await expect(page.getByText(`Payroll item #${fixture.bonus_alpha_payroll_item_id}`)).toBeVisible();
    await expect(page.getByText(`Payroll item #${fixture.workflow_payroll_item_id}`)).toHaveCount(0);
    await context.close();
  });

  test('hides a loaded payroll item while the next route resolves', async ({ page }): Promise<void> => {
    const firstPath = `/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/payroll-items/${fixture.workflow_payroll_item_id}`;
    await page.goto(firstPath);
    await expect(page.getByText(`Payroll item #${fixture.workflow_payroll_item_id}`)).toBeVisible();

    const nextItemPath = `/api/v1/admin/pay_periods/${fixture.bonus_sync_pay_period_id}/payroll_items/${fixture.bonus_alpha_payroll_item_id}`;
    let markNextItemStarted: (() => void) | undefined;
    let releaseNextItem: (() => void) | undefined;
    const nextItemStarted = new Promise<void>((resolve): void => { markNextItemStarted = resolve; });
    const nextItemReleased = new Promise<void>((resolve): void => { releaseNextItem = resolve; });
    await page.route(`**${nextItemPath}`, async (route): Promise<void> => {
      const response = await route.fetch();
      markNextItemStarted?.();
      await nextItemReleased;
      await route.fulfill({ response });
    });

    const destination = `/companies/${fixture.company_id}/pay-runs/${fixture.bonus_sync_pay_period_id}/payroll-items/${fixture.bonus_alpha_payroll_item_id}`;
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, destination);
    await nextItemStarted;
    await expect(page.getByText('Loading payroll item')).toBeVisible();
    await expect(page.getByText(`Payroll item #${fixture.workflow_payroll_item_id}`)).toHaveCount(0);

    const nextItemDelivered = page.waitForResponse((response): boolean => new URL(response.url()).pathname === nextItemPath);
    releaseNextItem?.();
    await nextItemDelivered;
    await expect(page.getByText(`Payroll item #${fixture.bonus_alpha_payroll_item_id}`)).toBeVisible();
  });

  test('closes a staged employee import when the company changes', async ({ page }): Promise<void> => {
    await page.goto(`/companies/${fixture.company_id}/employees`);
    await page.getByRole('button', { name: 'Bulk Import' }).click();
    await expect(page.getByRole('heading', { name: 'Bulk Import Employees' })).toBeVisible();

    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, `/companies/${fixture.other_company_id}/employees`);
    await expect(page).toHaveURL(`/companies/${fixture.other_company_id}/employees`);
    await expect(page.getByRole('heading', { name: 'Bulk Import Employees' })).toHaveCount(0);
    await expect(page.getByRole('table').getByText('Jordan Boundary', { exact: true })).toBeVisible();
    await expect(page.getByText('Avery Example', { exact: true })).toHaveCount(0);
  });

  test('keeps accountant payroll operations available while denying client configuration', async ({ browser }): Promise<void> => {
    const payrollPeriods = await accountantApi.get('admin/pay_periods');
    expect(payrollPeriods.ok()).toBeTruthy();

    const activityHistory = await accountantApi.get('admin/audit_logs');
    expect(activityHistory.ok()).toBeTruthy();
    const activityEntries = (await responseJson(activityHistory)).data as Array<Record<string, unknown>>;
    expect(activityEntries.length).toBeGreaterThan(0);
    expect(activityEntries.every((entry) => Number(entry.company_id) === fixture.company_id)).toBeTruthy();

    const schedule = await accountantApi.get('admin/pay_schedule_settings');
    expect(schedule.ok()).toBeTruthy();
    const rejectedUpdate = await accountantApi.put('admin/pay_schedule_settings', {
      data: { pay_schedule_settings: {} },
    });
    expect(rejectedUpdate.status()).toBe(403);
    expect((await responseJson(rejectedUpdate)).error).toBe('Manager or admin access required');

    const accountantContext = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.accountant_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const accountantPage = await accountantContext.newPage();
    await accountantPage.goto('/app');
    await expect(accountantPage.getByText('Gate 0 Accountant')).toBeVisible();
    await expect(accountantPage.getByRole('link', { name: 'Timecard OCR' })).toBeVisible();
    await expect(accountantPage.getByRole('link', { name: 'Activity History' })).toBeVisible();
    await expect(accountantPage.getByRole('link', { name: 'Pay Schedule' })).toHaveCount(0);
    await expect(accountantPage.getByRole('link', { name: 'Client Changes' })).toHaveCount(0);

    await accountantPage.goto('/pay-schedule-settings');
    await expect(accountantPage).toHaveURL(/\/app$/);
    await accountantPage.goto('/settings/audit-logs');
    await expect(accountantPage.getByRole('heading', { name: 'Activity History' })).toBeVisible();
    await expect(accountantPage.getByText(`recorded actions for Synthetic Payroll Company`)).toBeVisible();
    await accountantContext.close();
  });

  test('keeps employee details usable when pay history is unavailable', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const page = await context.newPage();
    await page.route('**/api/v1/admin/reports/employee_pay_history**', async (route): Promise<void> => {
      await route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'Synthetic pay-history outage' }),
      });
    });

    await page.goto(`/companies/${fixture.company_id}/employees/${fixture.employee_id}/overview`);
    await expect(page.getByRole('heading', { name: 'Avery Example' })).toBeVisible();
    await expect(page.getByText('Pay history is temporarily unavailable. Employee details are still available.')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Edit employee' })).toBeVisible();

    await page.getByRole('navigation', { name: 'Employee workspace sections' }).getByRole('link', { name: 'Pay setup' }).click();
    await expect(page.getByRole('heading', { name: 'Payroll setup' })).toBeVisible();
    await context.close();
  });

  test('reloads an employee workspace when only the company route changes', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
      },
    });
    const page = await context.newPage();
    await page.goto(`/companies/${fixture.company_id}/employees/${fixture.employee_id}/overview`);
    await expect(page.getByRole('heading', { name: 'Avery Example' })).toBeVisible();

    let markBoundaryLoadStarted: (() => void) | undefined;
    const boundaryLoadStarted = new Promise<void>((resolve): void => {
      markBoundaryLoadStarted = resolve;
    });
    let releaseBoundaryLoad: (() => void) | undefined;
    const boundaryLoadReleased = new Promise<void>((resolve): void => {
      releaseBoundaryLoad = resolve;
    });
    await page.route(`**/api/v1/admin/employees/${fixture.employee_id}`, async (route): Promise<void> => {
      if (route.request().method() !== 'GET') {
        await route.continue();
        return;
      }
      markBoundaryLoadStarted?.();
      await boundaryLoadReleased;
      await route.continue();
    });

    const boundaryPath = `/companies/${fixture.other_company_id}/employees/${fixture.employee_id}/overview`;
    const boundaryEmployeeResponse = page.waitForResponse((response): boolean => (
      response.request().method() === 'GET'
      && new URL(response.url()).pathname === `/api/v1/admin/employees/${fixture.employee_id}`
    ));
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, boundaryPath);

    await expect(page).toHaveURL(boundaryPath);
    await boundaryLoadStarted;
    await expect(page.getByText('Loading employee workspace')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Avery Example' })).toHaveCount(0);
    releaseBoundaryLoad?.();
    const boundaryResponse = await boundaryEmployeeResponse;
    expect(boundaryResponse.request().headers()['x-company-id']).toBe(String(fixture.other_company_id));
    expect(boundaryResponse.status()).toBe(404);
    await expect(page.getByRole('heading', { name: 'This employee workspace could not be opened' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Avery Example' })).toHaveCount(0);
    await context.close();
  });

  test('hides prior-company dashboard data while a company switch is loading', async ({ browser }): Promise<void> => {
    const primaryDashboardResponse = await adminApi.get('admin/reports/dashboard');
    const boundaryDashboardResponse = await adminApi.get('admin/reports/dashboard', {
      headers: { 'X-Company-Id': String(fixture.other_company_id) },
    });
    expect(primaryDashboardResponse.ok()).toBeTruthy();
    expect(boundaryDashboardResponse.ok()).toBeTruthy();
    const primaryStats = (await responseJson(primaryDashboardResponse)).stats as { total_employees: number };
    const boundaryStats = (await responseJson(boundaryDashboardResponse)).stats as { total_employees: number };
    const primaryTotalLabel = `${primaryStats.total_employees} total records`;
    const boundaryTotalLabel = `${boundaryStats.total_employees} total records`;
    expect(primaryTotalLabel).not.toBe(boundaryTotalLabel);

    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
      },
    });
    const page = await context.newPage();
    let markBoundaryRequestStarted: (() => void) | undefined;
    let releaseBoundaryResponse: (() => void) | undefined;
    const boundaryRequestStarted = new Promise<void>((resolve): void => { markBoundaryRequestStarted = resolve; });
    const boundaryResponseReleased = new Promise<void>((resolve): void => { releaseBoundaryResponse = resolve; });

    await page.route('**/api/v1/admin/reports/dashboard', async (route): Promise<void> => {
      if (route.request().headers()['x-company-id'] !== String(fixture.other_company_id)) {
        await route.continue();
        return;
      }

      markBoundaryRequestStarted?.();
      const response = await route.fetch();
      await boundaryResponseReleased;
      await route.fulfill({ response });
    });

    await page.goto('/app');
    await expect(page.getByText(primaryTotalLabel)).toBeVisible();
    await page.getByRole('button', { name: /Synthetic Payroll Company/ }).click();
    await page.getByRole('button', { name: /Synthetic Boundary Company/ }).click();
    await boundaryRequestStarted;
    await expect(page.getByText(primaryTotalLabel)).toHaveCount(0);
    await expect(page.getByText(boundaryTotalLabel)).toHaveCount(0);

    releaseBoundaryResponse?.();
    await expect(page.getByText(boundaryTotalLabel)).toBeVisible();
    await context.close();
  });

  test('keeps only the current pay run actionable when route loads overlap or fail', async ({ page }): Promise<void> => {
    const delayedPayRunId = fixture.workflow_pay_period_id;
    const nextPayRunId = fixture.time_import_pay_period_id;
    let markDelayedRequestStarted: (() => void) | undefined;
    let releaseDelayedResponse: (() => void) | undefined;
    let failDelayedPayRun = false;
    const delayedRequestStarted = new Promise<void>((resolve): void => { markDelayedRequestStarted = resolve; });
    const delayedResponseReleased = new Promise<void>((resolve): void => { releaseDelayedResponse = resolve; });

    await page.route(`**/api/v1/admin/pay_periods/${delayedPayRunId}`, async (route): Promise<void> => {
      if (route.request().method() !== 'GET') {
        await route.continue();
        return;
      }

      if (failDelayedPayRun) {
        await route.fulfill({
          status: 500,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Synthetic failed pay-run load' }),
        });
        return;
      }

      markDelayedRequestStarted?.();
      const response = await route.fetch();
      await delayedResponseReleased;
      await route.fulfill({ response });
    });

    const delayedPath = `/companies/${fixture.company_id}/pay-runs/${delayedPayRunId}/overview`;
    const nextPath = `/companies/${fixture.company_id}/pay-runs/${nextPayRunId}/overview`;
    await page.goto(delayedPath);
    await delayedRequestStarted;
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, nextPath);
    await expect(page.getByText(`Pay run #${nextPayRunId}`, { exact: true })).toBeVisible();

    const delayedResponseDelivered = page.waitForResponse(
      (response): boolean => new URL(response.url()).pathname.endsWith(`/api/v1/admin/pay_periods/${delayedPayRunId}`),
    );
    releaseDelayedResponse?.();
    await delayedResponseDelivered;
    await waitForUiCommit(page);
    await expect(page.getByText(`Pay run #${nextPayRunId}`, { exact: true })).toBeVisible();
    await expect(page.getByText(`Pay run #${delayedPayRunId}`, { exact: true })).toHaveCount(0);

    failDelayedPayRun = true;
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, delayedPath);
    await expect(page.getByRole('heading', { name: 'This pay-run workspace could not be opened' })).toBeVisible();
    await expect(page.getByText(`Pay run #${nextPayRunId}`, { exact: true })).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'Open processing' })).toHaveCount(0);
  });

  test('reloads a pay-run workspace when only the company route changes', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
      },
    });
    const page = await context.newPage();
    const payRunId = fixture.workflow_pay_period_id;
    await page.goto(`/companies/${fixture.company_id}/pay-runs/${payRunId}/overview`);
    await expect(page.getByText(`Pay run #${payRunId}`, { exact: true })).toBeVisible();

    let markBoundaryLoadStarted: (() => void) | undefined;
    const boundaryLoadStarted = new Promise<void>((resolve): void => {
      markBoundaryLoadStarted = resolve;
    });
    let releaseBoundaryLoad: (() => void) | undefined;
    const boundaryLoadReleased = new Promise<void>((resolve): void => {
      releaseBoundaryLoad = resolve;
    });
    await page.route(`**/api/v1/admin/pay_periods/${payRunId}`, async (route): Promise<void> => {
      if (route.request().method() !== 'GET') {
        await route.continue();
        return;
      }
      markBoundaryLoadStarted?.();
      await boundaryLoadReleased;
      await route.continue();
    });

    const boundaryPath = `/companies/${fixture.other_company_id}/pay-runs/${payRunId}/overview`;
    const boundaryResponsePromise = page.waitForResponse((response): boolean => (
      response.request().method() === 'GET'
      && new URL(response.url()).pathname === `/api/v1/admin/pay_periods/${payRunId}`
    ));
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, boundaryPath);

    await expect(page).toHaveURL(boundaryPath);
    await boundaryLoadStarted;
    await expect(page.getByText('Loading pay-run workspace')).toBeVisible();
    await expect(page.getByText(`Pay run #${payRunId}`, { exact: true })).toHaveCount(0);
    releaseBoundaryLoad?.();
    const boundaryResponse = await boundaryResponsePromise;
    expect(boundaryResponse.request().headers()['x-company-id']).toBe(String(fixture.other_company_id));
    expect(boundaryResponse.status()).toBe(404);
    await expect(page.getByRole('heading', { name: 'This pay-run workspace could not be opened' })).toBeVisible();
    await context.close();
  });

  test('does not reveal a prior company employee when an edit load finishes late', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
      },
    });
    const page = await context.newPage();
    let markPrimaryRequestStarted: (() => void) | undefined;
    let releasePrimaryResponse: (() => void) | undefined;
    const primaryRequestStarted = new Promise<void>((resolve): void => { markPrimaryRequestStarted = resolve; });
    const primaryResponseReleased = new Promise<void>((resolve): void => { releasePrimaryResponse = resolve; });

    await page.route(`**/api/v1/admin/employees/${fixture.employee_id}`, async (route): Promise<void> => {
      if (route.request().headers()['x-company-id'] !== String(fixture.company_id)) {
        await route.continue();
        return;
      }

      const response = await route.fetch();
      markPrimaryRequestStarted?.();
      await primaryResponseReleased;
      await route.fulfill({ response });
    });

    await page.goto(`/companies/${fixture.company_id}/employees/${fixture.employee_id}/edit`);
    await primaryRequestStarted;
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, `/companies/${fixture.other_company_id}/employees/${fixture.employee_id}/edit`);
    await expect(page.getByText('Employee not found', { exact: true })).toBeVisible();

    const primaryEmployeeResponseDelivered = page.waitForResponse((response): boolean => (
      new URL(response.url()).pathname === `/api/v1/admin/employees/${fixture.employee_id}`
      && response.request().headers()['x-company-id'] === String(fixture.company_id)
    ));
    releasePrimaryResponse?.();
    await primaryEmployeeResponseDelivered;
    await waitForUiCommit(page);
    await expect(page.getByText('Employee not found', { exact: true })).toBeVisible();
    await expect(page.getByText('Avery Example', { exact: true })).toHaveCount(0);
    await context.close();
  });

  test('discards a delayed employee save after switching clients', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
      },
    });
    const page = await context.newPage();
    let markSaveStarted: (() => void) | undefined;
    const saveStarted = new Promise<void>((resolve): void => {
      markSaveStarted = resolve;
    });
    let releaseSave: (() => void) | undefined;
    const saveReleased = new Promise<void>((resolve): void => {
      releaseSave = resolve;
    });

    await page.route(`**/api/v1/admin/employees/${fixture.employee_id}`, async (route): Promise<void> => {
      if (route.request().method() !== 'PATCH') {
        await route.continue();
        return;
      }

      markSaveStarted?.();
      await saveReleased;
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ data: { id: fixture.employee_id } }),
      });
    });

    await page.goto(`/companies/${fixture.company_id}/employees/${fixture.employee_id}/edit`);
    await expect(page.locator('input[name="first_name"]')).toHaveValue('Avery');
    let captureOldCompanyDependents = false;
    const oldCompanyDependentRequests: string[] = [];
    page.on('request', (request): void => {
      if (!captureOldCompanyDependents) return;
      const url = new URL(request.url());
      const isOldPayrollFieldRequest = url.pathname.startsWith(`/api/v1/admin/employees/${fixture.employee_id}/payroll_fields`);
      const isOldWageRateRequest = url.pathname === '/api/v1/admin/employee_wage_rates'
        && url.searchParams.get('employee_id') === String(fixture.employee_id);
      if (isOldPayrollFieldRequest || isOldWageRateRequest) {
        oldCompanyDependentRequests.push(`${request.method()} ${url.pathname}${url.search}`);
      }
    });
    await page.getByRole('button', { name: 'Update Employee', exact: true }).click();
    await saveStarted;

    const boundaryEditPath = `/companies/${fixture.other_company_id}/employees/${fixture.other_employee_id}/edit`;
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, boundaryEditPath);
    await expect(page).toHaveURL(boundaryEditPath);
    await expect(page.locator('input[name="first_name"]')).toHaveValue('Jordan');
    await expect(page.getByRole('button', { name: 'Update Employee', exact: true })).toBeEnabled();

    const saveDelivered = page.waitForResponse((response): boolean => (
      response.request().method() === 'PATCH'
      && new URL(response.url()).pathname === `/api/v1/admin/employees/${fixture.employee_id}`
    ));
    captureOldCompanyDependents = true;
    releaseSave?.();
    await saveDelivered;
    await waitForUiCommit(page);

    expect(oldCompanyDependentRequests).toEqual([]);
    await expect(page).toHaveURL(boundaryEditPath);
    await expect(page.locator('input[name="first_name"]')).toHaveValue('Jordan');
    await expect(page.getByText('Failed to save employee')).toHaveCount(0);
    await context.close();
  });

  test('discards a delayed classification transition after switching clients', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.super_admin_email,
      },
    });
    const page = await context.newPage();
    let markTransitionStarted: (() => void) | undefined;
    const transitionStarted = new Promise<void>((resolve): void => {
      markTransitionStarted = resolve;
    });
    let releaseTransition: (() => void) | undefined;
    const transitionReleased = new Promise<void>((resolve): void => {
      releaseTransition = resolve;
    });

    await page.route(
      `**/api/v1/admin/employees/${fixture.employee_id}/transition_tax_classification`,
      async (route): Promise<void> => {
        markTransitionStarted?.();
        await transitionReleased;
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ data: { id: 999_999 } }),
        });
      },
    );

    await page.goto(`/companies/${fixture.company_id}/employees/${fixture.employee_id}/edit`);
    await page.getByRole('button', { name: 'Create new classification record' }).click();
    await page.getByLabel('Reason for transition *').fill('Confirmed worker classification change');
    await page.getByRole('button', { name: 'Create linked record' }).click();
    await transitionStarted;

    const boundaryEditPath = `/companies/${fixture.other_company_id}/employees/${fixture.other_employee_id}/edit`;
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, boundaryEditPath);
    await expect(page).toHaveURL(boundaryEditPath);
    await expect(page.locator('input[name="first_name"]')).toHaveValue('Jordan');

    const transitionDelivered = page.waitForResponse((response): boolean => (
      response.request().method() === 'POST'
      && new URL(response.url()).pathname === `/api/v1/admin/employees/${fixture.employee_id}/transition_tax_classification`
    ));
    releaseTransition?.();
    const transitionResponse = await transitionDelivered;
    expect(transitionResponse.request().headers()['x-company-id']).toBe(String(fixture.company_id));
    await waitForUiCommit(page);

    await expect(page).toHaveURL(boundaryEditPath);
    await expect(page.locator('input[name="first_name"]')).toHaveValue('Jordan');
    await expect(page.getByText('Create a new tax-classification record')).toHaveCount(0);
    await context.close();
  });

  test('discards company-specific form helpers after switching clients', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
      },
    });
    const page = await context.newPage();
    let markScheduleStarted: (() => void) | undefined;
    let releaseSchedule: (() => void) | undefined;
    let markCheckSettingsStarted: (() => void) | undefined;
    let releaseCheckSettings: (() => void) | undefined;
    const scheduleStarted = new Promise<void>((resolve): void => { markScheduleStarted = resolve; });
    const scheduleReleased = new Promise<void>((resolve): void => { releaseSchedule = resolve; });
    const checkSettingsStarted = new Promise<void>((resolve): void => { markCheckSettingsStarted = resolve; });
    const checkSettingsReleased = new Promise<void>((resolve): void => { releaseCheckSettings = resolve; });

    await page.route('**/api/v1/admin/pay_schedule_settings', async (route): Promise<void> => {
      if (route.request().headers()['x-company-id'] !== String(fixture.company_id)) {
        await route.continue();
        return;
      }
      const response = await route.fetch();
      markScheduleStarted?.();
      await scheduleReleased;
      await route.fulfill({ response });
    });
    await page.route('**/api/v1/admin/companies/*', async (route): Promise<void> => {
      const pathname = new URL(route.request().url()).pathname;
      if (pathname !== `/api/v1/admin/companies/${fixture.company_id}`) {
        await route.continue();
        return;
      }
      const response = await route.fetch();
      markCheckSettingsStarted?.();
      await checkSettingsReleased;
      await route.fulfill({ response });
    });

    await page.goto(`/companies/${fixture.company_id}/pay-runs`);
    await page.getByRole('button', { name: 'New Pay Period' }).click();
    await Promise.all([scheduleStarted, checkSettingsStarted]);
    await expect(page.getByRole('dialog', { name: 'New Pay Period' })).toBeVisible();

    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, `/companies/${fixture.other_company_id}/pay-runs`);
    await expect(page).toHaveURL(`/companies/${fixture.other_company_id}/pay-runs`);
    await expect(page.getByRole('dialog', { name: 'New Pay Period' })).toHaveCount(0);

    const scheduleDelivered = page.waitForResponse((response): boolean => (
      new URL(response.url()).pathname === '/api/v1/admin/pay_schedule_settings'
      && response.request().headers()['x-company-id'] === String(fixture.company_id)
    ));
    const checkSettingsDelivered = page.waitForResponse((response): boolean => (
      new URL(response.url()).pathname === `/api/v1/admin/companies/${fixture.company_id}`
    ));
    releaseSchedule?.();
    releaseCheckSettings?.();
    await Promise.all([scheduleDelivered, checkSettingsDelivered]);
    await waitForUiCommit(page);
    await expect(page.getByRole('dialog', { name: 'New Pay Period' })).toHaveCount(0);

    await page.goto(`/companies/${fixture.company_id}/pay-runs`);
    await expect(page.getByRole('heading', { name: 'Pay Periods' })).toBeVisible();
    await page.getByRole('button', { name: 'Edit', exact: true }).first().click();
    await expect(page.getByRole('dialog', { name: 'Edit Pay Period' })).toBeVisible();
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, `/companies/${fixture.other_company_id}/pay-runs`);
    await expect(page).toHaveURL(`/companies/${fixture.other_company_id}/pay-runs`);
    await expect(page.getByRole('dialog', { name: 'Edit Pay Period' })).toHaveCount(0);

    let markQuickFieldStarted: (() => void) | undefined;
    let releaseQuickField: (() => void) | undefined;
    const quickFieldStarted = new Promise<void>((resolve): void => { markQuickFieldStarted = resolve; });
    const quickFieldReleased = new Promise<void>((resolve): void => { releaseQuickField = resolve; });
    await page.route('**/api/v1/admin/payroll_fields', async (route): Promise<void> => {
      if (route.request().method() !== 'POST' || route.request().headers()['x-company-id'] !== String(fixture.company_id)) {
        await route.continue();
        return;
      }
      const response = await route.fetch();
      markQuickFieldStarted?.();
      await quickFieldReleased;
      await route.fulfill({ response });
    });

    await page.goto(`/companies/${fixture.company_id}/employees/${fixture.employee_id}/edit`);
    await expect(page.getByRole('heading', { name: 'Edit Employee' })).toBeVisible();
    const createClientFieldButton = page.getByRole('button', { name: 'Create client-wide field' });
    await expect(createClientFieldButton).toBeVisible();
    await waitForUiCommit(page);
    await createClientFieldButton.click();
    await expect(page.getByRole('heading', { name: 'Create reusable client-wide payroll field' })).toBeVisible();
    const delayedFieldName = `Delayed primary field ${randomUUID()}`;
    await page.getByPlaceholder('Auto loan, 401(k), phone allowance').fill(delayedFieldName);
    await page.getByRole('button', { name: 'Create and assign' }).click();
    await quickFieldStarted;
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, `/companies/${fixture.other_company_id}/employees/${fixture.other_employee_id}/edit`);
    await expect(page.getByRole('heading', { name: 'Edit Employee' })).toBeVisible();
    await expect(page.locator('input[name="first_name"]')).toHaveValue('Jordan');

    const quickFieldDelivered = page.waitForResponse((response): boolean => (
      new URL(response.url()).pathname === '/api/v1/admin/payroll_fields'
      && response.request().method() === 'POST'
      && response.request().headers()['x-company-id'] === String(fixture.company_id)
    ));
    releaseQuickField?.();
    const createdFieldResponse = await quickFieldDelivered;
    expect(createdFieldResponse.ok()).toBe(true);
    await waitForUiCommit(page);
    await expect(page.getByText(delayedFieldName, { exact: true })).toHaveCount(0);
    await expect(page.getByRole('heading', { name: 'Create reusable client-wide payroll field' })).toHaveCount(0);
    await context.close();
  });

  test('discards a delayed pay-run mutation after switching clients', async ({ page }): Promise<void> => {
    const calculate = await adminApi.post(`admin/pay_periods/${fixture.mutation_race_pay_period_id}/run_payroll`);
    expect(calculate.ok()).toBeTruthy();
    const calculatedPeriod = (await responseJson(calculate)).pay_period as Record<string, unknown>;
    expect(calculatedPeriod.status).toBe('calculated');

    let markApprovalStarted: (() => void) | undefined;
    const approvalStarted = new Promise<void>((resolve): void => {
      markApprovalStarted = resolve;
    });
    let releaseApproval: (() => void) | undefined;
    const approvalReleased = new Promise<void>((resolve): void => {
      releaseApproval = resolve;
    });

    await page.route(
      `**/api/v1/admin/pay_periods/${fixture.mutation_race_pay_period_id}/approve`,
      async (route): Promise<void> => {
        markApprovalStarted?.();
        await approvalReleased;
        await route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Synthetic delayed approval failure' }),
        });
      },
    );

    await page.goto(`/companies/${fixture.company_id}/pay-runs?status=calculated`);
    const delayedRow = page.getByRole('row').filter({ hasText: 'Jun 21 - Jul 4, 2026' });
    await expect(delayedRow).toBeVisible();
    await delayedRow.getByRole('button', { name: 'Approve', exact: true }).click();
    await approvalStarted;

    await page.getByRole('button', { name: /Synthetic Payroll Company/ }).click();
    await page.getByRole('button', { name: /Synthetic Boundary Company/ }).click();
    await expect(page).toHaveURL(`/companies/${fixture.other_company_id}/pay-runs?status=calculated`);
    await expect(page.getByText('No pay periods found. Create your first pay period to get started.')).toBeVisible();

    const approvalDelivered = page.waitForResponse((response): boolean => (
      response.request().method() === 'POST'
      && new URL(response.url()).pathname === `/api/v1/admin/pay_periods/${fixture.mutation_race_pay_period_id}/approve`
    ));
    releaseApproval?.();
    await approvalDelivered;
    await waitForUiCommit(page);

    await expect(page.getByText('Synthetic delayed approval failure')).toHaveCount(0);
    await expect(page).toHaveURL(`/companies/${fixture.other_company_id}/pay-runs?status=calculated`);
    await expect(delayedRow).toHaveCount(0);
  });

  test('keeps the selected pay-run filter when an action finishes late', async ({ page }): Promise<void> => {
    const calculate = await adminApi.post(`admin/pay_periods/${fixture.filter_race_pay_period_id}/run_payroll`);
    expect(calculate.ok()).toBeTruthy();
    const calculatedPeriod = (await responseJson(calculate)).pay_period as Record<string, unknown>;
    expect(calculatedPeriod.status).toBe('calculated');

    let markApprovalStarted: (() => void) | undefined;
    const approvalStarted = new Promise<void>((resolve): void => {
      markApprovalStarted = resolve;
    });
    let releaseApproval: (() => void) | undefined;
    const approvalReleased = new Promise<void>((resolve): void => {
      releaseApproval = resolve;
    });
    let approvalWasReleased = false;
    let staleCalculatedReloadSeen = false;
    let currentDraftReloadSeen = false;

    await page.route(
      `**/api/v1/admin/pay_periods/${fixture.filter_race_pay_period_id}/approve`,
      async (route): Promise<void> => {
        markApprovalStarted?.();
        await approvalReleased;
        approvalWasReleased = true;
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ status: 'approved' }),
        });
      },
    );

    await page.route('**/api/v1/admin/payroll_history**', async (route): Promise<void> => {
      const url = new URL(route.request().url());
      if (
        approvalWasReleased
        && route.request().method() === 'GET'
        && url.pathname === '/api/v1/admin/payroll_history'
      ) {
        if (url.searchParams.get('status') === 'calculated') staleCalculatedReloadSeen = true;
        if (url.searchParams.get('status') === 'draft') {
          currentDraftReloadSeen = true;
          await route.fulfill({
            status: 503,
            contentType: 'application/json',
            body: JSON.stringify({ error: 'Synthetic silent refresh failure' }),
          });
          return;
        }
      }
      await route.continue();
    });

    await page.goto(`/companies/${fixture.company_id}/pay-runs?status=calculated`);
    const delayedRow = page.getByRole('row').filter({ hasText: 'Jul 5 - 18, 2026' });
    await expect(delayedRow).toBeVisible();
    await delayedRow.getByRole('button', { name: 'Approve', exact: true }).click();
    await approvalStarted;

    await page.getByRole('button', { name: /^Draft \(/ }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs?status=draft`);
    await expect(page.getByRole('row').filter({ hasText: 'Aug 2 - 15, 2026' })).toBeVisible();

    const approvalDelivered = page.waitForResponse((response): boolean => (
      response.request().method() === 'POST'
      && new URL(response.url()).pathname === `/api/v1/admin/pay_periods/${fixture.filter_race_pay_period_id}/approve`
    ));
    releaseApproval?.();
    await approvalDelivered;
    await waitForUiCommit(page);
    await waitForUiCommit(page);

    expect(staleCalculatedReloadSeen).toBe(false);
    expect(currentDraftReloadSeen).toBe(true);
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs?status=draft`);
    await expect(page.getByRole('row').filter({ hasText: 'Aug 2 - 15, 2026' })).toBeVisible();
    await expect(page.getByText('Synthetic silent refresh failure')).toBeVisible();
    await expect(delayedRow).toHaveCount(0);
  });

  test('refreshes a production-shaped recurring bonus for an accountant without duplicating it', async ({ browser }): Promise<void> => {
    test.setTimeout(60_000);
    const accountantContext = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.accountant_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const page = await accountantContext.newPage();
    await page.goto(`/pay-periods/${fixture.bonus_sync_pay_period_id}`);
    await expect(page.getByRole('heading', { name: /Pay Period:/i })).toBeVisible();

    await page.getByRole('button', { name: 'Calculate Payroll' }).click();
    await expect(page.getByRole('button', { name: 'Approve' })).toBeVisible();

    const payrollTable = page.getByRole('table').filter({
      has: page.getByRole('columnheader', { name: 'Last Name' }),
    });
    await expect(payrollTable.getByRole('columnheader', { name: 'First Name' })).toBeVisible();
    await expect(payrollTable.getByRole('columnheader', { name: /^Employee Medicare/ })).toBeVisible();
    await expect(payrollTable.getByRole('columnheader', { name: /^Employer Medicare/ })).toBeVisible();

    const bonusAlphaRow = payrollTable.getByRole('row').filter({ hasText: 'Alpha' });
    const bonusBetaRow = payrollTable.getByRole('row').filter({ hasText: 'Beta' });
    await expect(bonusAlphaRow.getByRole('cell').nth(0)).toContainText('Alpha');
    await expect(bonusAlphaRow.getByRole('cell').nth(1)).toContainText('Bonus');
    await expect(bonusAlphaRow).toContainText('Bonus');
    await expect(bonusAlphaRow).toContainText('$1,234.56');
    await expect(bonusBetaRow).toContainText('Bonus');
    await expect(bonusBetaRow).toContainText('$876.54');

    const firstResult = await accountantApi.get(`admin/pay_periods/${fixture.bonus_sync_pay_period_id}`);
    expect(firstResult.ok()).toBeTruthy();
    const firstPeriod = (await responseJson(firstResult)).pay_period as Record<string, unknown>;
    const firstItems = firstPeriod.payroll_items as Array<Record<string, unknown>>;
    const firstBonusAlpha = firstItems.find((item) => item.id === fixture.bonus_alpha_payroll_item_id);
    expect(Number(firstBonusAlpha?.gross_pay)).toBe(2034.56);

    await expect(payrollTable.getByRole('columnheader', { name: new RegExp(fixture.register_reconciliation_field_name) })).toBeVisible();
    const headerLabels = (await payrollTable.getByRole('columnheader').allTextContents())
      .map((label) => label.replace(/\s+/g, ' ').trim());
    const totalsRow = payrollTable.getByRole('row').filter({ hasText: /Totals \(\d+ employees?\)/ });
    const totalCells = totalsRow.getByRole('cell');
    expect(await totalCells.count()).toBe(headerLabels.length);
    expect((await totalCells.nth(headerLabels.indexOf('Hours')).textContent())?.trim()).toBe('169.00');
    const reconciliationFieldIndex = headerLabels.findIndex((label) => label.includes(fixture.register_reconciliation_field_name));
    expect(reconciliationFieldIndex).toBeGreaterThanOrEqual(0);
    expect((await totalCells.nth(reconciliationFieldIndex).textContent())?.trim())
      .toBe(`+$${fixture.register_reconciliation_field_total.toFixed(2)}`);

    const employeeMedicareIndex = headerLabels.findIndex((label) => label.startsWith('Employee Medicare'));
    const employerMedicareIndex = headerLabels.findIndex((label) => label.startsWith('Employer Medicare'));
    const expectedEmployeeMedicare = firstItems.reduce(
      (sum, item) => sum + Number(item.medicare_tax || 0) + Number(item.additional_medicare_tax || 0),
      0,
    );
    const expectedEmployerMedicare = firstItems.reduce((sum, item) => sum + Number(item.employer_medicare_tax || 0), 0);
    expect((await totalCells.nth(employeeMedicareIndex).textContent())?.trim()).toBe(`$${expectedEmployeeMedicare.toFixed(2)}`);
    expect((await totalCells.nth(employerMedicareIndex).textContent())?.trim()).toBe(`$${expectedEmployerMedicare.toFixed(2)}`);
    expect(await totalsRow.evaluate((row) => window.getComputedStyle(row.parentElement as HTMLElement).position)).toBe('sticky');
    const unfilteredTotalValues = (await totalCells.allTextContents()).map((value) => value.trim());
    const historicalContractor = firstItems.find((item) => item.id === fixture.historical_hourly_contractor_payroll_item_id);
    expect(historicalContractor?.contractor_pay_type).toBe('hourly');
    const historicalContractorRow = payrollTable.getByRole('row').filter({ hasText: 'Historical' });
    await expect(historicalContractorRow).toContainText('$25.00/hr');
    await expect(
      historicalContractorRow.getByRole('cell').nth(headerLabels.indexOf('Hours')),
    ).toHaveText('4');

    const registerSearch = page.getByRole('textbox', { name: 'Search employees and checks...' });
    await registerSearch.fill('Alpha');
    await expect(totalsRow).toContainText('Totals (1 employee)');
    expect((await totalCells.nth(headerLabels.indexOf('Hours')).textContent())?.trim()).toBe('80.00');
    expect((await totalCells.nth(reconciliationFieldIndex).textContent())?.trim()).toBe('+$12.34');
    await expect(bonusAlphaRow).not.toContainText('Inactive legacy rate');
    await registerSearch.fill('');
    await expect(totalsRow).toContainText('Totals (5 employees)');
    expect((await totalCells.allTextContents()).map((value) => value.trim())).toEqual(unfilteredTotalValues);

    await page.getByRole('combobox').filter({ has: page.getByRole('option', { name: 'Hours Low-High' }) }).last().selectOption('hours:asc');
    const referenceContractorRow = payrollTable.getByRole('row').filter({ hasText: 'Reference' });
    const historicalContractorBox = await historicalContractorRow.boundingBox();
    const referenceContractorBox = await referenceContractorRow.boundingBox();
    expect(historicalContractorBox?.y).toBeLessThan(referenceContractorBox?.y || 0);

    await bonusAlphaRow.getByRole('button', { name: 'Edit' }).click();
    await expect(page.getByRole('heading', { name: 'Edit Payroll Item' })).toBeVisible();
    await expect(page.getByText('One-Time Bonus')).toBeVisible();
    const firstAdjustmentLabel = page.getByPlaceholder('Label (e.g. Uniform repayment)').first();
    const originalLabel = await firstAdjustmentLabel.inputValue();
    await firstAdjustmentLabel.fill(`${originalLabel} edited`);
    await firstAdjustmentLabel.fill(originalLabel);

    let signalSaveStarted!: () => void;
    let releaseSave!: () => void;
    const saveStarted = new Promise<void>((resolve) => { signalSaveStarted = resolve; });
    const saveReleased = new Promise<void>((resolve) => { releaseSave = resolve; });
    const payrollItemPattern = `**/payroll_items/${fixture.bonus_alpha_payroll_item_id}*`;
    const holdAndRejectSave = async (route: Route): Promise<void> => {
      if (route.request().method() !== 'PATCH') {
        await route.continue();
        return;
      }

      signalSaveStarted();
      await saveReleased;
      await route.fulfill({
        status: 422,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'Intentional busy-state regression response' }),
      });
    };
    await page.route(payrollItemPattern, holdAndRejectSave);
    try {
      const rejectedResponse = page.waitForResponse((response): boolean =>
        response.request().method() === 'PATCH' &&
        response.url().includes(`/payroll_items/${fixture.bonus_alpha_payroll_item_id}`)
      );
      await page.getByRole('button', { name: 'Save & Recalculate' }).click();
      await saveStarted;
      await page.keyboard.press('Escape');
      try {
        await expect(page.getByRole('heading', { name: 'Edit Payroll Item' })).toBeVisible();
        await page.mouse.click(8, 8);
        await expect(page.getByRole('heading', { name: 'Edit Payroll Item' })).toBeVisible();
      } finally {
        releaseSave();
      }
      expect((await rejectedResponse).ok()).toBeFalsy();
      await expect(page.getByText('Intentional busy-state regression response')).toBeVisible();
      await page.keyboard.press('Escape');
      await expect(page.getByRole('heading', { name: 'Edit Payroll Item' })).not.toBeVisible();
    } finally {
      releaseSave();
      await page.unroute(payrollItemPattern, holdAndRejectSave);
    }

    await bonusAlphaRow.getByRole('button', { name: 'Edit' }).click();
    const saveAndCaptureUpdatePayload = async (): Promise<{ payroll_item: Record<string, unknown> }> => {
      const updateResponsePromise = page.waitForResponse((response) =>
        response.request().method() === 'PATCH' &&
        response.url().includes(`/payroll_items/${fixture.bonus_alpha_payroll_item_id}`)
      );
      const refreshedPeriodPromise = page.waitForResponse((response) =>
        response.request().method() === 'GET' &&
        new URL(response.url()).pathname === `/api/v1/admin/pay_periods/${fixture.bonus_sync_pay_period_id}`
      );
      await page.getByRole('button', { name: 'Save & Recalculate' }).click();
      const updateResponse = await updateResponsePromise;
      expect(updateResponse.ok()).toBeTruthy();
      expect((await refreshedPeriodPromise).ok()).toBeTruthy();
      await waitForUiCommit(page);
      return updateResponse.request().postDataJSON() as { payroll_item: Record<string, unknown> };
    };

    await firstAdjustmentLabel.fill(`${originalLabel} edited`);
    await firstAdjustmentLabel.fill(originalLabel);
    const revertedEditPayload = await saveAndCaptureUpdatePayload();
    expect(revertedEditPayload.payroll_item).not.toHaveProperty('payroll_adjustments');
    await expect(page.getByRole('button', { name: 'Calculate Payroll', exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Calculate Payroll', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Approve', exact: true })).toBeVisible();

    await bonusAlphaRow.getByRole('button', { name: 'Edit' }).click();
    const adjustmentLabels = page.getByPlaceholder('Label (e.g. Uniform repayment)');
    const initialAdjustmentCount = await adjustmentLabels.count();
    await page.getByRole('button', { name: '+ Add Adjustment' }).click();
    await expect(adjustmentLabels).toHaveCount(initialAdjustmentCount + 1);
    await page.getByTitle('Remove').last().click();
    await expect(adjustmentLabels).toHaveCount(initialAdjustmentCount);
    const addRemovePayload = await saveAndCaptureUpdatePayload();
    expect(addRemovePayload.payroll_item).not.toHaveProperty('payroll_adjustments');

    const secondRun = await accountantApi.post(`admin/pay_periods/${fixture.bonus_sync_pay_period_id}/run_payroll`);
    expect(secondRun.ok()).toBeTruthy();
    const secondResult = await accountantApi.get(`admin/pay_periods/${fixture.bonus_sync_pay_period_id}`);
    const secondPeriod = (await responseJson(secondResult)).pay_period as Record<string, unknown>;
    const secondItems = secondPeriod.payroll_items as Array<Record<string, unknown>>;
    const secondBonusAlpha = secondItems.find((item) => item.id === fixture.bonus_alpha_payroll_item_id);
    const secondBonusAlphaAdjustments = secondBonusAlpha?.payroll_adjustments as Array<Record<string, unknown>>;
    expect(secondBonusAlphaAdjustments.filter((adjustment) => adjustment.label === 'Bonus')).toHaveLength(1);

    await accountantContext.close();
  });

  test('accounts for every MoSa source row and ignores Revel pay amounts', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.accountant_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const page = await context.newPage();

    await page.goto(`/pay-periods/${fixture.safe_payroll_import_period_id}`);
    await page.getByRole('button', { name: 'Import (MoSa)' }).click();
    const safeDialog = page.locator('.dialog-wide');
    await expect(safeDialog.getByText('Revel pay rates and pay amounts are ignored.', { exact: false })).toBeVisible();
    await safeDialog.locator('input[type="file"]').nth(0).setInputFiles(fixture.safe_payroll_import_pdf_path);
    await safeDialog.locator('input[type="file"]').nth(1).setInputFiles(fixture.safe_payroll_import_workbook_path);
    await safeDialog.getByRole('checkbox', { name: /Legacy workbook fallback: all tips in this workbook were already paid out daily/i }).check();
    await safeDialog.getByRole('button', { name: 'Preview Import' }).click();

    await expect(safeDialog.getByText(/Review 2 suggested name matches/)).toBeVisible();
    await expect(safeDialog.getByText(/Petrius, Rosie.*Rosie Petirus/)).toBeVisible();
    await expect(safeDialog.getByText(/Tips were already paid daily and will offset employee checks/)).toBeVisible();
    await expect(safeDialog.getByText('$19.25')).toBeVisible();
    await expect(safeDialog.getByText('$123.50', { exact: true })).toBeVisible();
    await expect(safeDialog.getByText('Matched to Rosie recurring repayment')).toBeVisible();
    await expect(safeDialog.getByText('$8,888.88')).toHaveCount(0);
    let applySafeImport = safeDialog.getByRole('button', { name: /Apply Import/ });
    await expect(applySafeImport).toBeDisabled();
    await safeDialog.getByRole('button', { name: 'Back' }).click();
    await safeDialog.getByRole('button', { name: 'Preview Import' }).click();
    applySafeImport = safeDialog.getByRole('button', { name: /Apply Import/ });
    await expect(applySafeImport).toBeDisabled();
    await safeDialog.getByLabel(/I reviewed these suggestions/).check();
    await expect(applySafeImport).toBeEnabled();
    await applySafeImport.click();
    await expect(safeDialog.getByText('Successfully imported 2 employees.')).toBeVisible();

    const importedPeriod = await accountantApi.get(`admin/pay_periods/${fixture.safe_payroll_import_period_id}`);
    expect(importedPeriod.ok()).toBeTruthy();
    const importedItems = ((await responseJson(importedPeriod)).pay_period as Record<string, unknown>).payroll_items as Array<Record<string, unknown>>;
    const typoEmployeeItem = importedItems.find((item) => Number(item.employee_id) === fixture.import_typo_employee_id);
    expect(Number(typoEmployeeItem?.pay_rate)).toBe(fixture.import_typo_employee_rate);
    expect(Number(typoEmployeeItem?.hours_worked)).toBe(37.5);
    expect(Number(typoEmployeeItem?.reported_tips)).toBe(117.5);
    expect(Number(typoEmployeeItem?.tips_paid_out)).toBe(117.5);
    expect(Number(typoEmployeeItem?.loan_deduction)).toBe(0);
    expect(Number(typoEmployeeItem?.loan_payment)).toBe(123.5);
    expect(Number(typoEmployeeItem?.gross_pay)).not.toBe(8_888.88);

    await page.goto(`/pay-periods/${fixture.blocked_payroll_import_period_id}`);
    await page.getByRole('button', { name: 'Import (MoSa)' }).click();
    const blockedDialog = page.locator('.dialog-wide');
    await blockedDialog.locator('input[type="file"]').nth(0).setInputFiles(fixture.blocked_payroll_import_pdf_path);
    await blockedDialog.locator('input[type="file"]').nth(1).setInputFiles(fixture.blocked_payroll_import_workbook_path);
    await blockedDialog.getByRole('button', { name: 'Preview Import' }).click();

    await expect(blockedDialog.getByText('2 source rows need attention before this import can be applied.')).toBeVisible();
    await expect(blockedDialog.getByText('Revel hours', { exact: true })).toBeVisible();
    await expect(blockedDialog.getByText('Change workbook', { exact: true })).toBeVisible();
    const applyNonpaySource = blockedDialog.getByRole('button', { name: /Apply Import/ });
    await expect(applyNonpaySource).toBeDisabled();

    await blockedDialog.getByRole('combobox', { name: 'Outcome for Unknown, Worker' }).selectOption('informational');
    await blockedDialog.getByRole('textbox', { name: 'Reason for Unknown, Worker' }).fill('Revel reference row; no payroll payment is due.');
    await blockedDialog.getByRole('combobox', { name: 'Outcome for Worker Unknown' }).selectOption('informational');
    await blockedDialog.getByRole('textbox', { name: 'Reason for Worker Unknown' }).fill('Workbook reference row; no payroll payment is due.');
    await expect(applyNonpaySource).toBeEnabled();
    await applyNonpaySource.click();
    await expect(blockedDialog.getByText('Successfully imported 0 employees.')).toBeVisible();

    await context.close();
  });

  test('binds the fixture identity, rejects inactive access, and enforces role and company boundaries', async (): Promise<void> => {
    const me = await adminApi.get('auth/me');
    expect(me.ok()).toBeTruthy();
    expect((await responseJson(me)).user).toMatchObject({
      email: fixture.admin_email,
      company_id: fixture.company_id,
    });

    const inactiveApi = await playwrightRequest.newContext({
      baseURL: apiBaseUrl,
      extraHTTPHeaders: { 'X-E2E-User-Email': fixture.inactive_user_email },
    });
    const inactiveResponse = await inactiveApi.get('auth/me');
    expect(inactiveResponse.status()).toBe(401);
    await inactiveApi.dispose();

    const staffRoute = await clientApi.get('admin/employees');
    expect(staffRoute.status()).toBe(403);
    expect((await responseJson(staffRoute)).error).toBe('Staff access required');

    const crossCompanyEmployee = await clientApi.get(`client/employees/${fixture.other_employee_id}`, {
      headers: { 'X-Company-Id': String(fixture.other_company_id) },
    });
    expect(crossCompanyEmployee.status()).toBe(404);
    expect(JSON.stringify(await responseJson(crossCompanyEmployee))).not.toContain('Jordan Boundary');
  });

  test('keeps SSNs masked and routes client payroll changes to staff approval', async (): Promise<void> => {
    const showBefore = await clientApi.get(`client/employees/${fixture.client_employee_id}`);
    expect(showBefore.ok()).toBeTruthy();
    const beforeBody = await responseJson(showBefore);
    expect(JSON.stringify(beforeBody)).not.toContain('ssn_encrypted');
    expect((beforeBody.data as Record<string, unknown>).ssn_last_four).toBe(fixture.original_client_ssn_last_four);

    const update = await clientApi.patch(`client/employees/${fixture.client_employee_id}`, {
      data: {
        employee: {
          first_name: 'Casey Updated',
          pay_rate: 31.25,
          ssn: '900-00-0099',
          ssn_confirmation: '900-00-0099',
        },
      },
    });
    expect(update.ok()).toBeTruthy();
    const updateBody = await responseJson(update);
    const employee = updateBody.data as Record<string, unknown>;
    const changeRequest = updateBody.change_request as Record<string, unknown>;
    expect(employee.first_name).toBe('Casey Updated');
    expect(Number(employee.pay_rate)).toBe(fixture.original_client_pay_rate);
    expect(employee.ssn_last_four).toBe(fixture.original_client_ssn_last_four);
    expect(changeRequest.status).toBe('pending');
    expect(changeRequest.proposed_changes).toMatchObject({
      pay_rate: 31.25,
      ssn_encrypted: '[REDACTED]',
    });
    expect(JSON.stringify(updateBody)).not.toContain('900-00-0099');
  });

  test('reports an unavailable time source without leaking its secret', async (): Promise<void> => {
    const response = await adminApi.post(
      `admin/pay_periods/${fixture.time_import_pay_period_id}/preview_time_tracking_import`,
      { data: { source_id: fixture.time_tracking_source_id } },
    );
    expect(response.status()).toBe(422);
    const body = JSON.stringify(await responseJson(response));
    expect(body).not.toContain('gate0-fixture-secret-must-never-leak');
    expect(body).not.toMatch(/shared[_ -]?secret/i);
  });

  test('shows comparison-only payroll guidance while cutover approval is open', async ({ page }): Promise<void> => {
    await page.goto(`/companies/${fixture.other_company_id}/pay-runs`);

    await expect(page.getByRole('heading', { name: 'Pay Periods' })).toBeVisible();
    await expect(page.getByText('Live payroll stays locked during cutover review')).toBeVisible();
    await expect(page.getByText(/created as comparison runs and cannot be committed/)).toBeVisible();

    await page.getByRole('button', { name: 'New Comparison Run' }).click();
    await expect(page.getByRole('heading', { name: 'New Comparison Run' })).toBeVisible();
    await expect(page.getByText('This run cannot be committed while cutover approval is open.')).toBeVisible();
    await expect(page.getByLabel('Starting Check Number (optional)')).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Create Comparison Run' })).toBeVisible();

    await page.getByLabel('Pay Date').fill('2026-08-31');
    await expect(page.getByRole('heading', { name: 'New Pay Period' })).toBeVisible();
    await expect(page.getByLabel('Starting Check Number (optional)')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Create Pay Period' })).toBeVisible();

    await page.getByLabel('Pay Date').fill('2026-09-18');
    await expect(page.getByRole('heading', { name: 'New Comparison Run' })).toBeVisible();
    await expect(page.getByLabel('Starting Check Number (optional)')).toHaveCount(0);
  });

  test('keeps recurring employee setup out of special runs unless the operator opts in', async ({ page }): Promise<void> => {
    await page.goto(`/companies/${fixture.company_id}/pay-runs`);
    await page.getByRole('button', { name: 'New Pay Period' }).click();

    const recurringSetup = page.getByRole('checkbox', { name: /Include recurring employee setup/ });
    const baseSalary = page.getByRole('checkbox', { name: /Include ordinary base salary/ });
    await expect(recurringSetup).toBeChecked();
    await expect(baseSalary).toBeChecked();

    await page.getByLabel('Run purpose').selectOption('bonus');
    await expect(recurringSetup).not.toBeChecked();
    await expect(baseSalary).not.toBeChecked();
    await expect(page.getByText(/Special runs leave these out unless you choose this/)).toBeVisible();

    await recurringSetup.check();
    await expect(page.getByText('You deliberately enabled recurring employee setup for a special run. Review every recurring item before calculating payroll.')).toBeVisible();

    await page.getByLabel('Run purpose').selectOption('regular');
    await expect(recurringSetup).toBeChecked();
    await expect(baseSalary).toBeChecked();
  });

  test('keeps company, queue, and relationship context across canonical payroll records', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
      },
    });
    const page = await context.newPage();
    let delayNextPrimaryResponse = false;
    let rejectNextBoundaryResponse = false;
    let markDelayedRequestStarted: (() => void) | undefined;
    let releaseDelayedResponse: (() => void) | undefined;
    let markDelayedRequestFinished: (() => void) | undefined;
    const delayedRequestStarted = new Promise<void>((resolve): void => { markDelayedRequestStarted = resolve; });
    const delayedResponseReleased = new Promise<void>((resolve): void => { releaseDelayedResponse = resolve; });
    const delayedRequestFinished = new Promise<void>((resolve): void => { markDelayedRequestFinished = resolve; });

    await page.route('**/api/v1/admin/payroll_history**', async (route): Promise<void> => {
      if (rejectNextBoundaryResponse && route.request().headers()['x-company-id'] === String(fixture.other_company_id)) {
        rejectNextBoundaryResponse = false;
        await route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Synthetic target-company failure' }),
        });
        return;
      }

      if (delayNextPrimaryResponse && route.request().headers()['x-company-id'] === String(fixture.company_id)) {
        delayNextPrimaryResponse = false;
        markDelayedRequestStarted?.();
        const response = await route.fetch();
        await delayedResponseReleased;
        await route.fulfill({ response });
        markDelayedRequestFinished?.();
        return;
      }

      await route.continue();
    });

    await page.goto(`/pay-periods?status=draft&sort=pay_date&direction=asc`);
    await expect(page).toHaveURL(new RegExp(`/companies/${fixture.company_id}/pay-runs\\?`));
    await expect(page).toHaveURL(/status=draft/);
    await expect(page.getByRole('heading', { name: 'Pay Periods' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Pay Periods' })).toHaveAttribute('href', `/companies/${fixture.company_id}/pay-runs`);

    await page.goto(`/companies/${fixture.company_id}/pay-runs?sort=pay_date&direction=asc&year=2026&search=Aug`);
    await expect(page.getByRole('table').getByText('Aug 2 - 15, 2026')).toBeVisible();
    delayNextPrimaryResponse = true;
    await page.getByRole('button', { name: /^Draft/ }).click();
    await delayedRequestStarted;
    rejectNextBoundaryResponse = true;
    await page.getByRole('button', { name: /Synthetic Payroll Company/ }).click();
    await page.getByRole('button', { name: /Synthetic Boundary Company/ }).click();
    await expect(page).toHaveURL(`/companies/${fixture.other_company_id}/pay-runs?sort=pay_date&direction=asc&year=2026&search=Aug&status=draft`);
    await expect(page.getByText('Switched clients. Showing pay periods for the selected client.')).toBeVisible();
    await expect(page.getByText('No pay periods match the current filters.')).toBeVisible();
    await expect(page.getByText('Aug 2 - 15, 2026')).toHaveCount(0);

    const delayedPayRunResponseDelivered = page.waitForResponse((response): boolean => (
      new URL(response.url()).pathname === '/api/v1/admin/payroll_history'
      && response.request().headers()['x-company-id'] === String(fixture.company_id)
    ));
    releaseDelayedResponse?.();
    await delayedPayRunResponseDelivered;
    await delayedRequestFinished;
    await waitForUiCommit(page);
    await expect(page.getByText('No pay periods match the current filters.')).toBeVisible();
    await expect(page.getByText('Aug 2 - 15, 2026')).toHaveCount(0);

    await page.getByRole('button', { name: /Synthetic Boundary Company/ }).click();
    await page.getByRole('button', { name: /Synthetic Payroll Company/ }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs?sort=pay_date&direction=asc&year=2026&search=Aug&status=draft`);
    await expect(page.getByRole('table').getByText('Aug 2 - 15, 2026')).toBeVisible();

    const queueUrl = page.url();
    const queueLocation = new URL(queueUrl);
    const queueReturnTo = `${queueLocation.pathname}${queueLocation.search}`;
    const workflowRow = page.getByRole('row').filter({ hasText: 'Aug 2 - 15, 2026' });

    await workflowRow.getByRole('button', { name: 'View', exact: true }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/overview?return_to=${encodeURIComponent(queueReturnTo)}`);
    const payRunIdentity = page.getByLabel('Pay run identity');
    await expect(payRunIdentity).toContainText(`Pay run #${fixture.workflow_pay_period_id}`);
    await payRunIdentity.evaluate((element): void => element.setAttribute('data-workspace-shell-probe', 'preserved'));
    await page.evaluate((): void => {
      (window as Window & { __payRunWorkspaceProbe?: string }).__payRunWorkspaceProbe = 'preserved';
    });

    const workspaceNavigation = page.getByRole('navigation', { name: 'Pay-run workspace sections' });
    await workspaceNavigation.getByRole('link', { name: 'Process payroll' }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/work?return_to=${encodeURIComponent(queueReturnTo)}`);
    await expect(page.getByLabel('Payroll processing actions')).toBeVisible();
    await expect(payRunIdentity).toHaveAttribute('data-workspace-shell-probe', 'preserved');
    expect(await page.evaluate((): string | undefined => (window as Window & { __payRunWorkspaceProbe?: string }).__payRunWorkspaceProbe)).toBe('preserved');

    const processingSearch = page.getByPlaceholder('Search employees...');
    await processingSearch.fill('Avery');
    await workspaceNavigation.getByRole('link', { name: 'Overview' }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/overview?return_to=${encodeURIComponent(queueReturnTo)}`);
    await expect(payRunIdentity).toHaveAttribute('data-workspace-shell-probe', 'preserved');
    await workspaceNavigation.getByRole('link', { name: 'Process payroll' }).click();
    await expect(processingSearch).toHaveValue('Avery');
    await workspaceNavigation.getByRole('link', { name: 'Overview' }).click();
    await page.getByRole('link', { name: 'Back', exact: true }).click();
    await expect(page).toHaveURL(queueUrl);

    await workflowRow.getByRole('button', { name: 'Enter Hours', exact: true }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/work?return_to=${encodeURIComponent(queueReturnTo)}`);
    await page.getByRole('link', { name: 'Back', exact: true }).click();
    await expect(page).toHaveURL(queueUrl);

    let delayNextPrimaryEmployeeResponse = false;
    let rejectNextBoundaryEmployeeResponse = false;
    let markDelayedEmployeeRequestStarted: (() => void) | undefined;
    let releaseDelayedEmployeeResponse: (() => void) | undefined;
    let markDelayedEmployeeRequestFinished: (() => void) | undefined;
    const delayedEmployeeRequestStarted = new Promise<void>((resolve): void => { markDelayedEmployeeRequestStarted = resolve; });
    const delayedEmployeeResponseReleased = new Promise<void>((resolve): void => { releaseDelayedEmployeeResponse = resolve; });
    const delayedEmployeeRequestFinished = new Promise<void>((resolve): void => { markDelayedEmployeeRequestFinished = resolve; });

    await page.route('**/api/v1/admin/employees**', async (route): Promise<void> => {
      if (rejectNextBoundaryEmployeeResponse && route.request().headers()['x-company-id'] === String(fixture.other_company_id)) {
        rejectNextBoundaryEmployeeResponse = false;
        await route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Synthetic target-company failure' }),
        });
        return;
      }

      if (delayNextPrimaryEmployeeResponse && route.request().headers()['x-company-id'] === String(fixture.company_id)) {
        delayNextPrimaryEmployeeResponse = false;
        markDelayedEmployeeRequestStarted?.();
        const response = await route.fetch();
        await delayedEmployeeResponseReleased;
        await route.fulfill({ response });
        markDelayedEmployeeRequestFinished?.();
        return;
      }

      await route.continue();
    });

    await page.goto(`/companies/${fixture.company_id}/employees?status=active`);
    await expect(page.getByRole('table').getByText('Avery Example')).toBeVisible();
    delayNextPrimaryEmployeeResponse = true;
    await page.getByPlaceholder('Search employees...').fill('Avery');
    await delayedEmployeeRequestStarted;
    rejectNextBoundaryEmployeeResponse = true;
    await page.getByRole('button', { name: /Synthetic Payroll Company/ }).click();
    await page.getByRole('button', { name: /Synthetic Boundary Company/ }).click();
    await expect(page).toHaveURL(`/companies/${fixture.other_company_id}/employees?status=active&search=Avery`);
    await expect(page.getByRole('heading', { name: 'No employees found' })).toBeVisible();
    await expect(page.getByText('Avery Example')).toHaveCount(0);

    const delayedEmployeeResponseDelivered = page.waitForResponse((response): boolean => (
      new URL(response.url()).pathname === '/api/v1/admin/employees'
      && response.request().headers()['x-company-id'] === String(fixture.company_id)
    ));
    releaseDelayedEmployeeResponse?.();
    await delayedEmployeeResponseDelivered;
    await delayedEmployeeRequestFinished;
    await waitForUiCommit(page);
    await expect(page.getByRole('heading', { name: 'No employees found' })).toBeVisible();
    await expect(page.getByText('Avery Example')).toHaveCount(0);

    await page.getByRole('button', { name: /Synthetic Boundary Company/ }).click();
    await page.getByRole('button', { name: /Synthetic Payroll Company/ }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/employees?status=active&search=Avery`);
    await expect(page.getByRole('table').getByText('Avery Example')).toBeVisible();

    await page.goto(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/payroll-items/${fixture.workflow_payroll_item_id}`);
    await expect(page.getByText(`Payroll item #${fixture.workflow_payroll_item_id}`)).toBeVisible();
    await expect(page.getByRole('link', { name: 'Employee workspace' })).toBeVisible();
    await expect(page.getByText('Source pay run')).toBeVisible();

    await page.getByRole('link', { name: 'Employee workspace' }).click();
    await expect(page).toHaveURL(new RegExp(`/companies/${fixture.company_id}/employees/${fixture.employee_id}/pay-history`));
    await expect(page.getByRole('heading', { name: 'Avery Example' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Employees' })).toHaveAttribute('href', `/companies/${fixture.company_id}/employees`);

    await context.close();
  });

  test('redirects legacy record URLs without creating back-navigation loops', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const page = await context.newPage();

    await page.goto(`/employees/${fixture.employee_id}`);
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/employees/${fixture.employee_id}/overview?return_to=%2Fcompanies%2F${fixture.company_id}%2Femployees`);
    await page.getByRole('link', { name: 'Back', exact: true }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/employees`);

    await page.goto('/employees/new');
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/employees/new?return_to=%2Fcompanies%2F${fixture.company_id}%2Femployees`);
    await page.getByRole('button', { name: 'Back', exact: true }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/employees`);

    await page.goto(`/pay-periods/${fixture.workflow_pay_period_id}`);
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/work?return_to=%2Fcompanies%2F${fixture.company_id}%2Fpay-runs`);
    await page.getByRole('link', { name: 'Back', exact: true }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs`);

    await page.goto('/pay-periods/not-a-number');
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs`);

    await page.goto('/pay-periods/123abc');
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs`);

    await page.goto('/employees/0');
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/employees`);

    await page.goto('/pay-periods/-1');
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs`);

    await context.close();
  });

  test('keeps connected payroll records usable on a mobile viewport', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      viewport: { width: 390, height: 844 },
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const page = await context.newPage();
    const expectNoPageOverflow = async (): Promise<void> => {
      expect(await page.evaluate((): boolean => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBeTruthy();
    };

    await page.goto(`/companies/${fixture.company_id}/pay-runs?status=draft&sort=pay_date&direction=asc&year=2026&search=Aug%202%20-%2015%2C%202026`);
    await expect(page.getByRole('heading', { name: 'Pay Periods' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'View' }).first()).toBeVisible();
    await expectNoPageOverflow();

    const mobileQueueUrl = page.url();
    const mobileQueueLocation = new URL(mobileQueueUrl);
    const mobileReturnTo = `${mobileQueueLocation.pathname}${mobileQueueLocation.search}`;

    await page.getByRole('button', { name: 'View', exact: true }).click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/overview?return_to=${encodeURIComponent(mobileReturnTo)}`);
    await page.getByRole('link', { name: 'Back', exact: true }).click();
    await expect(page).toHaveURL(mobileQueueUrl);

    await page.getByRole('button', { name: 'Enter hours', exact: true }).first().click();
    await expect(page).toHaveURL(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/work?return_to=${encodeURIComponent(mobileReturnTo)}`);

    await page.goto(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/overview`);
    await expect(page.getByLabel('Pay run identity')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Open payroll item for Avery Example' })).toBeVisible();
    await expectNoPageOverflow();

    await page.goto(`/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/payroll-items/${fixture.workflow_payroll_item_id}`);
    await expect(page.getByRole('link', { name: 'Employee workspace' })).toBeVisible();
    await expect(page.getByText(`Payroll item #${fixture.workflow_payroll_item_id}`)).toBeVisible();
    await expectNoPageOverflow();

    await context.close();
  });

  test('calculates, reviews, rolls back approval, commits, and rejects a retry or edit after commit', async ({ page }): Promise<void> => {
    await page.goto(`/pay-periods/${fixture.workflow_pay_period_id}`);
    await expect(page.getByRole('heading', { name: /Pay Period:/i })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Calculate Payroll' })).toBeVisible();

    await page.getByRole('button', { name: 'Calculate Payroll' }).click();
    await expect(page.getByRole('button', { name: 'Approve' })).toBeVisible();
    await expect(page.getByText('Reports & Documents')).toBeVisible();

    await page.getByRole('button', { name: 'Approve' }).click();
    await expect(page.getByRole('button', { name: 'Roll Back Approval' })).toBeVisible();

    page.once('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Roll Back Approval' }).click();
    await expect(page.getByRole('button', { name: 'Approve' })).toBeVisible();

    await page.getByRole('button', { name: 'Approve' }).click();
    await expect(page.getByRole('button', { name: 'Commit & Finalize' })).toBeVisible();
    page.once('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Commit & Finalize' }).click();
    await expect(page.getByText('Committed', { exact: true }).first()).toBeVisible();
    await expect(page.getByRole('button', { name: 'Commit & Finalize' })).toHaveCount(0);

    const committedBeforeRetry = await adminApi.get(`admin/pay_periods/${fixture.workflow_pay_period_id}`);
    expect(committedBeforeRetry.ok()).toBeTruthy();
    const beforeRetryBody = await responseJson(committedBeforeRetry);

    const retry = await adminApi.post(`admin/pay_periods/${fixture.workflow_pay_period_id}/commit`);
    expect(retry.status()).toBe(422);
    expect(String((await responseJson(retry)).error)).toMatch(/approved pay period|invalid transition/i);

    const edit = await adminApi.patch(
      `admin/pay_periods/${fixture.workflow_pay_period_id}/payroll_items/${fixture.workflow_payroll_item_id}`,
      { data: { payroll_item: { hours_worked: 99 } } },
    );
    expect(edit.status()).toBe(422);

    const committedAfterRetry = await adminApi.get(`admin/pay_periods/${fixture.workflow_pay_period_id}`);
    expect(committedAfterRetry.ok()).toBeTruthy();
    expect(await responseJson(committedAfterRetry)).toEqual(beforeRetryBody);

    await page.reload();
    await expect(page.getByText('Committed', { exact: true }).first()).toBeVisible();
    await expect(page.getByText('Reports & Documents')).toBeVisible();

    const employeeHistoryUrl = `/companies/${fixture.company_id}/employees/${fixture.employee_id}/pay-history`;
    await page.goto(employeeHistoryUrl);
    const historyPayrollItemLink = page.getByRole('link', { name: /Open payroll item for/ }).first();
    const historyPayrollItemHref = await historyPayrollItemLink.getAttribute('href');
    expect(historyPayrollItemHref).toBeTruthy();
    expect(new URL(historyPayrollItemHref!, page.url()).searchParams.get('return_to')).toBe(employeeHistoryUrl);
    await historyPayrollItemLink.click();
    await expect(page).toHaveURL(new URL(historyPayrollItemHref!, page.url()).href);
    await expect(page.getByText(/Payroll item #\d+/)).toBeVisible();
    await page.getByRole('link', { name: 'Back', exact: true }).click();
    await expect(page).toHaveURL(employeeHistoryUrl);
  });

  test('preserves the client pay-run list context when returning from detail', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.client_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const page = await context.newPage();
    const listUrl = `/companies/${fixture.company_id}/pay-runs?source=client-dashboard`;

    await page.goto(listUrl);
    await expect(page.getByRole('heading', { name: 'Pay Periods' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Employees', exact: true })).toHaveAttribute('href', `/companies/${fixture.company_id}/employees`);
    await expect(page.getByRole('link', { name: 'Pay Periods', exact: true })).toHaveAttribute('href', `/companies/${fixture.company_id}/pay-runs`);
    await page.getByRole('button', { name: 'View', exact: true }).first().click();
    await expect(page).toHaveURL(new RegExp(
      `/companies/${fixture.company_id}/pay-runs/\\d+/overview\\?return_to=${encodeURIComponent(listUrl)}`,
    ));
    await page.getByRole('button', { name: 'Back to List', exact: true }).click();
    await expect(page).toHaveURL(listUrl);

    await context.close();
  });

  test('serves locked QuickBooks payroll through client history, employee history, and payroll summary', async ({ browser }): Promise<void> => {
    const clientList = await clientApi.get('client/pay_periods', { params: { year: 2025 } });
    expect(clientList.ok()).toBeTruthy();
    const clientListBody = await responseJson(clientList);
    const importedPeriod = (clientListBody.pay_periods as Array<Record<string, unknown>>).find(
      (period) => period.key === `imported:${fixture.historical_pay_period_id}`,
    );
    expect(importedPeriod).toMatchObject({
      record_type: 'imported',
      status: 'locked',
      capabilities: { view: true, edit: false, delete: false, run: false, commit: false },
    });

    const clientDetail = await clientApi.get(`client/imported_pay_periods/${fixture.historical_pay_period_id}`);
    expect(clientDetail.ok()).toBeTruthy();
    const clientDetailBody = await responseJson(clientDetail);
    const clientSource = (clientDetailBody.data as Record<string, unknown>).source as Record<string, unknown>;
    const clientPaycheck = ((clientDetailBody.data as Record<string, unknown>).paychecks as Array<Record<string, unknown>>)[0];
    expect(clientSource.import_batch_id).toBeUndefined();
    expect(clientSource.importer_version).toBeUndefined();
    expect(clientSource.locked_by_name).toBeUndefined();
    expect(clientPaycheck.check_number).toBeNull();

    const employeeHistory = await adminApi.get('admin/reports/employee_pay_history', {
      params: { employee_id: fixture.employee_id, year: 2025 },
    });
    expect(employeeHistory.ok()).toBeTruthy();
    const employeeReport = (await responseJson(employeeHistory)).report as Record<string, unknown>;
    expect((employeeReport.history as Array<Record<string, unknown>>).some(
      (record) => record.historical_pay_period_id === fixture.historical_pay_period_id && record.record_type === 'imported',
    )).toBe(true);

    const summary = await adminApi.get('admin/reports/ytd_summary', { params: { year: 2025 } });
    expect(summary.ok()).toBeTruthy();
    const sourceSummary = ((await responseJson(summary)).report as Record<string, unknown>).source_summary as Record<string, Record<string, unknown>>;
    expect(sourceSummary.quickbooks.paycheck_count).toBe(1);

    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.client_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const page = await context.newPage();
    await page.goto(`/companies/${fixture.company_id}/pay-runs`);
    const importedRow = page.getByRole('row').filter({ hasText: 'QuickBooks import' });
    await expect(importedRow).toContainText('Locked');
    await importedRow.getByRole('button', { name: 'View' }).click();
    await expect(page).toHaveURL(new RegExp(`/companies/${fixture.company_id}/pay-runs/imported/${fixture.historical_pay_period_id}`));
    await expect(page.getByText('This finalized payroll came from QuickBooks')).toBeVisible();
    await expect(page.getByText('Import provenance')).toHaveCount(0);
    await expect(page.getByText('QB-1201')).toHaveCount(0);
    await context.close();
  });

  test('rejects malformed client company routes without requesting payroll data', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.client_email,
      },
    });
    const page = await context.newPage();
    let payPeriodRequestCount = 0;
    await page.route('**/api/v1/client/pay_periods**', async (route): Promise<void> => {
      payPeriodRequestCount += 1;
      await route.continue();
    });

    for (const invalidCompanyId of ['not-a-number', '0', '-1', '01', '1e3', '0x10']) {
      await page.goto(`/companies/${invalidCompanyId}/pay-runs`);
      await expect(page.getByRole('heading', { name: 'This client workspace could not be opened' })).toBeVisible();
      await expect(page.getByText('No pay periods found.')).toHaveCount(0);
    }
    expect(payPeriodRequestCount).toBe(0);

    await context.close();
  });

  test('keeps the newest client pay-period route when an older response arrives late', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.client_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const page = await context.newPage();
    const delayedPayPeriodId = 900001;
    const currentPayPeriodId = 900002;
    let markDelayedRequestStarted: (() => void) | undefined;
    const delayedRequestStarted = new Promise<void>((resolve): void => {
      markDelayedRequestStarted = resolve;
    });
    let releaseDelayedResponse: (() => void) | undefined;
    const delayedResponseReleased = new Promise<void>((resolve): void => {
      releaseDelayedResponse = resolve;
    });
    const responseBody = (payPeriodId: number, employeeName: string, payDate: string): string => JSON.stringify({
      pay_period: {
        id: payPeriodId,
        start_date: payDate,
        end_date: payDate,
        pay_date: payDate,
        status: 'committed',
        employee_count: 1,
        total_gross: '100.00',
        total_net: '80.00',
        payroll_items: [{
          id: payPeriodId,
          employee_name: employeeName,
          employment_type: 'hourly',
          total_hours: '1.0',
          pay_rate: '100.00',
          gross_pay: '100.00',
          total_deductions: '20.00',
          net_pay: '80.00',
        }],
      },
    });

    await page.route(`**/api/v1/client/pay_periods/${delayedPayPeriodId}`, async (route): Promise<void> => {
      markDelayedRequestStarted?.();
      await delayedResponseReleased;
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: responseBody(delayedPayPeriodId, 'Delayed Route Employee', '2026-01-02'),
      });
    });
    await page.route(`**/api/v1/client/pay_periods/${currentPayPeriodId}`, async (route): Promise<void> => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: responseBody(currentPayPeriodId, 'Current Route Employee', '2026-02-06'),
      });
    });

    await page.goto(`/companies/${fixture.company_id}/pay-runs/${delayedPayPeriodId}/overview`);
    await delayedRequestStarted;
    await page.evaluate((path): void => {
      window.history.pushState({}, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, `/companies/${fixture.company_id}/pay-runs/${currentPayPeriodId}/overview`);
    await expect(page.getByText('Current Route Employee', { exact: true })).toBeVisible();

    const delayedResponseDelivered = page.waitForResponse((response): boolean => (
      new URL(response.url()).pathname === `/api/v1/client/pay_periods/${delayedPayPeriodId}`
    ));
    releaseDelayedResponse?.();
    await delayedResponseDelivered;
    await waitForUiCommit(page);
    await expect(page.getByText('Current Route Employee', { exact: true })).toBeVisible();
    await expect(page.getByText('Delayed Route Employee', { exact: true })).toHaveCount(0);

    await context.close();
  });

  test('preserves a filtered pay-run return path when opening a correction workspace', async ({ page }): Promise<void> => {
    const payPeriodResponse = await adminApi.get(`admin/pay_periods/${fixture.workflow_pay_period_id}`);
    expect(payPeriodResponse.ok()).toBeTruthy();
    const payPeriod = (await responseJson(payPeriodResponse)).pay_period as Record<string, unknown>;
    if (payPeriod.correction_status !== 'voided') {
      const voidResponse = await adminApi.post(
        `admin/pay_periods/${fixture.workflow_pay_period_id}/void`,
        { data: { reason: 'Verify filtered correction navigation' } },
      );
      expect(voidResponse.ok()).toBeTruthy();
    }

    const filteredReturnTo = `/companies/${fixture.company_id}/pay-runs?status=committed&year=2026`;
    await page.goto(
      `/companies/${fixture.company_id}/pay-runs/${fixture.workflow_pay_period_id}/work?return_to=${encodeURIComponent(filteredReturnTo)}`,
    );
    await page.getByRole('button', { name: 'Create Correction Run', exact: true }).click();
    await page.getByLabel(/Reason for correction/).fill('Correct payroll while preserving filtered queue context');
    await page.getByRole('dialog').getByRole('button', { name: 'Create Correction Run', exact: true }).click();
    await expect(page).toHaveURL(new RegExp(
      `/companies/${fixture.company_id}/pay-runs/\\d+/work\\?return_to=${encodeURIComponent(filteredReturnTo)}`,
    ));
  });

  test('applies time to an editable period and rejects a second import after commit', async (): Promise<void> => {
    const mapping = {
      source_user_id: 'synthetic-worker-1',
      employee_id: fixture.employee_id,
      include: true,
    };
    const apply = await adminApi.post(
      `admin/pay_periods/${fixture.time_import_pay_period_id}/apply_time_tracking_import`,
      { data: { import_id: fixture.first_time_import_id, mappings: [mapping] } },
    );
    expect(apply.ok()).toBeTruthy();
    expect((await responseJson(apply)).results).toMatchObject({ errors: [] });

    const calculate = await adminApi.post(`admin/pay_periods/${fixture.time_import_pay_period_id}/run_payroll`);
    expect(calculate.ok()).toBeTruthy();
    const approve = await adminApi.post(`admin/pay_periods/${fixture.time_import_pay_period_id}/approve`);
    expect(approve.ok()).toBeTruthy();
    const commit = await adminApi.post(`admin/pay_periods/${fixture.time_import_pay_period_id}/commit`);
    expect(commit.ok()).toBeTruthy();

    const retryApply = await adminApi.post(
      `admin/pay_periods/${fixture.time_import_pay_period_id}/apply_time_tracking_import`,
      { data: { import_id: fixture.retry_time_import_id, mappings: [mapping] } },
    );
    expect(retryApply.status()).toBe(422);
    expect(String((await responseJson(retryApply)).error)).toMatch(/non-editable pay period/i);
  });

  test('enters and clears a one-time bonus beside hours without creating a recurring addition', async ({ browser }) => {
    const context = await browser.newContext({ extraHTTPHeaders: {
      'X-E2E-User-Email': fixture.accountant_email,
      'X-Company-Id': String(fixture.company_id),
    } });
    try {
      const page = await context.newPage();
      const periodPath = `admin/pay_periods/${fixture.bonus_sync_pay_period_id}`;
      const baseline = await accountantApi.post(`${periodPath}/run_payroll`);
      expect(baseline.ok()).toBeTruthy();
      const baselineBody = await baseline.json();
      const initial = baselineBody.pay_period.payroll_items.find((item: { employee_id: number }) => item.employee_id === fixture.employee_id);
      const grossWithoutBonus = Number(initial.gross_pay) - Number(initial.bonus || 0);
      await page.goto(`/companies/${fixture.company_id}/pay-runs/${fixture.bonus_sync_pay_period_id}/work`);
      const bonus = page.getByRole('textbox', { name: 'Bonus this payroll for Avery Example', exact: true });
      await expect(bonus).toBeVisible();
      await bonus.fill('321.09');
      await bonus.press('Tab');
      await expect(page.getByText('Recalculate to include your changes', { exact: true })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Approve', exact: true })).toBeDisabled();
      await page.route('**/run_payroll', async (route) => {
        await route.fulfill({ json: {
          ...baselineBody,
          results: { success: [], errors: [{ employee_id: fixture.employee_id, error: 'Review this employee setup before retrying.' }] },
        } });
      }, { times: 1 });
      await page.getByRole('button', { name: 'Recalculate', exact: true }).click();
      await expect(page.getByText(/Review this employee setup before retrying/)).toBeVisible();
      await expect(bonus).toHaveValue('321.09');
      await expect(page.getByRole('button', { name: 'Approve', exact: true })).toBeDisabled();
      const save = page.waitForResponse((response) => response.url().endsWith('/run_payroll') && response.request().method() === 'POST');
      await page.getByRole('button', { name: 'Recalculate', exact: true }).click();
      const result = await (await save).json();
      expect(result.results.errors).toEqual([]);
      const updated = result.pay_period.payroll_items.find((item: { employee_id: number }) => item.employee_id === fixture.employee_id);
      expect(Number(updated.bonus)).toBe(321.09);
      expect(Number(updated.gross_pay)).toBeCloseTo(grossWithoutBonus + 321.09, 2);
      await expect(bonus).toHaveValue('321.09');
      await expect(page.getByText('Recalculate to include your changes', { exact: true })).toHaveCount(0);
      await page.reload();
      await expect(bonus).toHaveValue('321.09');
      await bonus.fill('0');
      await bonus.press('Tab');
      const clear = page.waitForResponse((response) => response.url().endsWith('/run_payroll') && response.request().method() === 'POST');
      await page.getByRole('button', { name: 'Recalculate', exact: true }).click();
      const cleared = await (await clear).json();
      expect(cleared.results.errors).toEqual([]);
      const finalItem = cleared.pay_period.payroll_items.find((item: { employee_id: number }) => item.employee_id === fixture.employee_id);
      expect(Number(finalItem.bonus)).toBe(0);
      expect(Number(finalItem.gross_pay)).toBeCloseTo(grossWithoutBonus, 2);
      await page.screenshot({ path: 'test-results/feedback-bonus-worksheet.png', fullPage: true });
    } finally {
      await context.close();
    }
  });

  test('accepts a first direct loan entry with an untouched default and restores the default after clearing', async ({ browser }) => {
    const fieldResponse = await adminApi.post('admin/payroll_fields', { data: { payroll_field: {
      name: `Feedback loan ${randomUUID()}`, kind: 'deduction', tax_treatment: 'post_tax_deduction', category: 'loan',
      amount_type: 'fixed', default_amount: 50, show_in_payroll_grid: true, active: true,
    } } });
    expect(fieldResponse.ok()).toBeTruthy();
    const { payroll_field: field } = await fieldResponse.json();
    const assignment = await adminApi.post(`admin/employees/${fixture.employee_id}/payroll_fields`, { data: {
      employee_payroll_field: { payroll_field_definition_id: field.id, amount: 50, active: true },
    } });
    expect(assignment.ok()).toBeTruthy();
    const context = await browser.newContext({ extraHTTPHeaders: {
      'X-E2E-User-Email': fixture.accountant_email, 'X-Company-Id': String(fixture.company_id),
    } });
    try {
      const page = await context.newPage();
      await page.goto(`/companies/${fixture.company_id}/pay-runs/${fixture.bonus_sync_pay_period_id}/work`);
      const loan = page.getByRole('textbox', { name: 'Loan deduction this payroll for Avery Example', exact: true });
      if (!await loan.isVisible()) await page.getByRole('button', { name: '+ Tips & Deductions', exact: true }).click();
      const regularHours = page.getByRole('row').filter({ has: loan }).getByRole('textbox').first();
      await regularHours.fill('80');
      await regularHours.press('Tab');
      await loan.fill('75');
      await loan.press('Tab');
      const saved = page.waitForResponse((response) => response.url().endsWith('/run_payroll') && response.request().method() === 'POST');
      await page.getByRole('button', { name: /^(Calculate Payroll|Recalculate)$/ }).click();
      const body = await (await saved).json();
      expect(body.results.errors).toEqual([]);
      const item = body.pay_period.payroll_items.find((row: { employee_id: number }) => row.employee_id === fixture.employee_id);
      expect(Number(item.loan_deduction)).toBe(75);
      expect(Number(item.loan_payment)).toBe(75);
      await page.reload();
      await expect(loan).toHaveValue('75.00');
      await loan.fill('0');
      await loan.press('Tab');
      const cleared = page.waitForResponse((response) => response.url().endsWith('/run_payroll') && response.request().method() === 'POST');
      await page.getByRole('button', { name: /^(Calculate Payroll|Recalculate)$/ }).click();
      const final = await (await cleared).json();
      expect(final.results.errors).toEqual([]);
      const finalItem = final.pay_period.payroll_items.find((row: { employee_id: number }) => row.employee_id === fixture.employee_id);
      expect(Number(finalItem.loan_deduction)).toBe(0);
      const restoredDefault = finalItem.payroll_field_entries.find((entry: { payroll_field_definition_id: number }) => entry.payroll_field_definition_id === field.id);
      expect(restoredDefault).toMatchObject({ active: true, source: 'employee_default' });
      expect(Number(restoredDefault.amount)).toBe(50);
      expect(Number(finalItem.total_deductions)).toBeCloseTo(Number(item.total_deductions) - 25, 2);
      expect(Number(finalItem.net_pay)).toBeCloseTo(Number(item.net_pay) + 25, 2);
    } finally {
      await context.close();
    }
  });

  test('records a historical correction beside the locked source and exposes its immutable review workflow', async ({ browser }): Promise<void> => {
    const sourceBefore = await adminApi.get(`admin/imported_pay_periods/${fixture.historical_pay_period_id}`);
    expect(sourceBefore.ok()).toBeTruthy();
    const sourceBeforeBody = await responseJson(sourceBefore);
    const sourcePaycheckBefore = ((sourceBeforeBody.data as Record<string, unknown>).paychecks as Array<Record<string, unknown>>)[0];

    const adjustment = {
      kind: 'correction',
      effective_pay_date: '2025-12-19',
      reason: 'Gate 0 retained-source correction',
      external_reference: 'GATE0-ADJ-1',
      idempotency_key: 'gate0-historical-adjustment',
      gross_pay: 25,
      federal_income_tax: 5,
    };
    const previewResponse = await adminApi.post(
      `admin/historical_paychecks/${fixture.historical_paycheck_id}/adjustments/preview`,
      { data: { adjustment } },
    );
    expect(previewResponse.ok()).toBeTruthy();
    const preview = (await responseJson(previewResponse)).data as Record<string, unknown>;
    expect(preview).toMatchObject({ ready: true });

    const createResponse = await adminApi.post(
      `admin/historical_paychecks/${fixture.historical_paycheck_id}/adjustments`,
      { data: {
        adjustment,
        preview_digest: preview.digest,
        acknowledgement: 'RECORD HISTORICAL ADJUSTMENT',
      } },
    );
    expect(createResponse.ok()).toBeTruthy();
    const createdAdjustment = (await responseJson(createResponse)).data as Record<string, unknown>;

    const sourceAfter = await adminApi.get(`admin/imported_pay_periods/${fixture.historical_pay_period_id}`);
    const sourceAfterBody = await responseJson(sourceAfter);
    const sourcePaycheckAfter = ((sourceAfterBody.data as Record<string, unknown>).paychecks as Array<Record<string, unknown>>)[0];
    expect(sourcePaycheckAfter).toEqual(sourcePaycheckBefore);

    const staffContext = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.admin_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const staffPage = await staffContext.newPage();
    await staffPage.goto(`/companies/${fixture.company_id}/pay-runs/imported/${fixture.historical_pay_period_id}`);
    await staffPage.getByRole('button', { name: 'Adjustments' }).click();
    await expect(staffPage.getByText('Gate 0 retained-source correction')).toBeVisible();
    await expect(staffPage.getByText('Gross $25.00 · Net $20.00')).toBeVisible();
    await expect(staffPage.getByRole('button', { name: 'Reverse adjustment' })).toBeVisible();
    await staffContext.close();

    const accountantContext = await browser.newContext({
      extraHTTPHeaders: {
        'X-E2E-User-Email': fixture.accountant_email,
        'X-Company-Id': String(fixture.company_id),
      },
    });
    const accountantPage = await accountantContext.newPage();
    await accountantPage.goto(`/companies/${fixture.company_id}/pay-runs/imported/${fixture.historical_pay_period_id}`);
    await accountantPage.getByRole('button', { name: 'Adjustments' }).click();
    await expect(accountantPage.getByText('Gate 0 retained-source correction')).toBeVisible();
    await expect(accountantPage.getByRole('button', { name: 'Record adjustment' })).toHaveCount(0);
    await expect(accountantPage.getByRole('button', { name: 'Reverse adjustment' })).toHaveCount(0);
    await accountantContext.close();

    const eventResponse = await adminApi.post(
      `admin/historical_paycheck_adjustments/${String(createdAdjustment.id)}/event`,
      { data: { event_type: 'filing_reviewed_no_amendment', note: 'Reviewed in Gate 0' } },
    );
    expect(eventResponse.ok()).toBeTruthy();
  });

  test('creates and edits a verified loan repayment schedule through the real UI', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({ extraHTTPHeaders: {
      'X-E2E-User-Email': fixture.admin_email, 'X-Company-Id': String(fixture.company_id),
    } });
    const loanName = `Verified UI loan ${randomUUID()}`;
    let loanId: number | undefined;
    try {
      const page = await context.newPage();
      page.setDefaultTimeout(10_000);
      await page.goto('/employee-loans');
      await page.getByRole('button', { name: 'Set up deduction', exact: true }).click();
      await page.getByRole('combobox', { name: 'Employee *', exact: true }).selectOption(String(fixture.employee_id));
      await page.getByLabel('Deduction name *', { exact: true }).fill(loanName);
      await page.getByRole('combobox', { name: 'Payroll deduction schedule', exact: true }).selectOption('new');
      await page.getByLabel('Payment per payroll', { exact: true }).fill('250');
      await page.getByLabel('Confirmed opening balance *', { exact: true }).fill('650');
      await page.getByLabel('Balance verified as of *', { exact: true }).fill('2026-09-01');
      await page.getByRole('combobox', { name: 'Verification source', exact: true }).selectOption('statement');
      await page.getByLabel('First deduction payday', { exact: false }).fill('2026-09-10');
      const createdResponse = page.waitForResponse(response => response.url().endsWith('/admin/employee_loans') && response.request().method() === 'POST');
      await page.getByRole('button', { name: 'Create Loan', exact: true }).click();
      const created = await createdResponse;
      expect(created.status()).toBe(201);
      const createdLoan = (await created.json()).loan;
      loanId = createdLoan.id;
      expect(Number(createdLoan.current_balance)).toBe(650);
      expect(Number(createdLoan.payment_amount)).toBe(250);
      expect(createdLoan.first_deduction_date).toBe('2026-09-10');
      expect(createdLoan.scheduled).toBe(true);
      await page.getByRole('button', { name: new RegExp(loanName) }).click();
      await page.getByLabel('Payment each payday', { exact: true }).fill('200');
      await page.getByLabel('First deduction payday', { exact: true }).fill('2026-09-24');
      const updatedResponse = page.waitForResponse(response => response.url().endsWith(`/admin/employee_loans/${loanId}`) && response.request().method() === 'PATCH');
      await page.getByRole('button', { name: 'Save repayment schedule', exact: true }).click();
      expect((await updatedResponse).ok()).toBeTruthy();
      await page.reload();
      await page.getByRole('button', { name: new RegExp(loanName) }).click();
      await expect(page.getByLabel('Payment each payday', { exact: true })).toHaveValue('200.0');
      await expect(page.getByLabel('First deduction payday', { exact: true })).toHaveValue('2026-09-24');
      const saved = await adminApi.get(`admin/employee_loans/${loanId}`);
      const savedLoan = (await saved.json()).loan;
      expect(Number(savedLoan.payment_amount)).toBe(200);
      expect(savedLoan.first_deduction_date).toBe('2026-09-24');
      const schedules = await adminApi.get('admin/employee_loans');
      const schedule = (await schedules.json()).loan_schedules.find((row: { employee_id: number; deduction_type_id?: number }) => row.employee_id === fixture.employee_id && row.deduction_type_id === savedLoan.deduction_type_id);
      expect(Number(schedule.amount)).toBe(200);
      expect(schedule.tracked).toBe(true);
    } finally {
      if (loanId) await adminApi.delete(`admin/employee_loans/${loanId}`);
      await context.close();
    }
  });

  test('runs an open-ended deduction through pause, resume, and permanent stop', async ({ browser }): Promise<void> => {
    const context = await browser.newContext({ extraHTTPHeaders: {
      'X-E2E-User-Email': fixture.admin_email, 'X-Company-Id': String(fixture.company_id),
    } });
    const deductionName = `Verified recurring deduction ${randomUUID()}`;
    let loanId: number | undefined;
    try {
      const page = await context.newPage();
      page.setDefaultTimeout(10_000);
      page.on('dialog', async (dialog) => dialog.accept());
      await page.goto('/employee-loans');
      await page.getByRole('button', { name: 'Set up deduction', exact: true }).click();
      await page.getByRole('button', { name: /Recurring deduction — no balance/ }).click();
      await page.getByRole('combobox', { name: 'Employee *', exact: true }).selectOption(String(fixture.employee_id));
      await page.getByLabel('Deduction name *', { exact: true }).fill(deductionName);
      await page.getByLabel('Payment per payroll', { exact: true }).fill('125');
      await page.getByLabel('First deduction payday', { exact: false }).fill('2026-09-10');
      const createdResponse = page.waitForResponse(response => response.url().endsWith('/admin/employee_loans') && response.request().method() === 'POST');
      await page.getByRole('button', { name: 'Create Deduction', exact: true }).click();
      const created = await createdResponse;
      expect(created.status()).toBe(201);
      const createdLoan = (await created.json()).loan;
      loanId = createdLoan.id;
      expect(createdLoan.tracking_mode).toBe('recurring_no_balance');
      expect(createdLoan.original_amount).toBeNull();
      expect(createdLoan.current_balance).toBeNull();
      expect(createdLoan.scheduled).toBe(true);

      await page.getByRole('button', { name: new RegExp(deductionName) }).click();
      await expect(page.getByText('Recurring deduction without a known balance')).toBeVisible();
      await page.getByRole('button', { name: 'Pause', exact: true }).click();
      await expect(page.getByRole('button', { name: 'Resume', exact: true })).toBeVisible();
      await page.getByRole('button', { name: 'Resume', exact: true }).click();
      await expect(page.getByRole('button', { name: 'Pause', exact: true })).toBeVisible();
      await page.getByLabel('Reason to stop permanently', { exact: true }).fill('Synthetic client authorization');
      await page.getByRole('button', { name: 'Stop Permanently', exact: true }).click();
      await expect(page.getByRole('combobox').nth(1)).toHaveValue('stopped');
      await expect(page.getByRole('button', { name: new RegExp(`${deductionName}.*Stopped`) })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Pause', exact: true })).toHaveCount(0);
      await expect(page.getByRole('button', { name: 'Resume', exact: true })).toHaveCount(0);

      const saved = await adminApi.get(`admin/employee_loans/${loanId}`);
      const savedLoan = (await saved.json()).loan;
      expect(savedLoan.status).toBe('stopped');
      expect(savedLoan.stopped_at).toBeTruthy();
      expect(savedLoan.stopped_by_name).toBeTruthy();
      expect(savedLoan.notes).toContain('Synthetic client authorization');
    } finally {
      if (loanId) await adminApi.delete(`admin/employee_loans/${loanId}`);
      await context.close();
    }
  });

});

test('calculates two variable-pay owners with distinct recurring retirement funding through the worksheet', async ({ browser }) => {
  const fixture = loadFixture();
  const companyId = fixture.other_company_id;
  const headers = { 'X-E2E-User-Email': fixture.admin_email, 'X-Company-Id': String(companyId) };
  const api = await playwrightRequest.newContext({
    baseURL: process.env.E2E_API_URL || `http://127.0.0.1:${process.env.E2E_API_PORT || '4317'}/api/v1/`,
    extraHTTPHeaders: headers,
  });
  const context = await browser.newContext({ extraHTTPHeaders: headers });
  try {
    const employees: { id: number; first_name: string; last_name: string }[] = [];
    for (const [index, amount] of [900.00, 1200.00].entries()) {
      const employeeResponse = await api.post('admin/employees', { data: { employee: {
        first_name: 'Scenario', last_name: `Owner${index + 1}`, ssn: `900-88-100${index}`, ssn_confirmation: `900-88-100${index}`,
        employment_type: 'salary', salary_type: 'variable', pay_rate: 0, pay_frequency: 'biweekly',
        filing_status: 'single', allowances: 0, retirement_rate: 0, employer_retirement_match_rate: 0.04,
        hire_date: '2026-01-01', w4_effective_on: '2026-01-01',
        address_line1: '100 Synthetic Avenue', city: 'Hagatna', state: 'GU', zip: '96910',
        default_payroll_adjustments: [{ label: 'Recurring retirement-funding bonus', amount, treatment: 'taxable_addition', active: true }],
      } } });
      expect(employeeResponse.ok(), await employeeResponse.text()).toBeTruthy();
      const employee = (await employeeResponse.json()).data;
      employees.push(employee);
      const fieldResponse = await api.post('admin/payroll_fields', { data: { payroll_field: {
        name: `Owner ${index + 1} fixed 401(k)`, kind: 'deduction', tax_treatment: 'pre_tax_deduction', category: 'retirement',
        reporting_group: '401k_pre_tax', amount_type: 'fixed', default_amount: amount, show_in_payroll_grid: true, active: true,
      } } });
      expect(fieldResponse.ok(), await fieldResponse.text()).toBeTruthy();
      const field = (await fieldResponse.json()).payroll_field;
      const assignment = await api.post(`admin/employees/${employee.id}/payroll_fields`, { data: {
        employee_payroll_field: { payroll_field_definition_id: field.id, amount, active: true },
      } });
      expect(assignment.ok(), await assignment.text()).toBeTruthy();
    }
    const periodResponse = await api.post('admin/pay_periods', { data: { pay_period: {
      start_date: '2026-09-01', end_date: '2026-09-14', pay_date: '2026-09-18', run_purpose: 'regular', includes_base_salary: true,
    } } });
    expect(periodResponse.ok(), await periodResponse.text()).toBeTruthy();
    const periodId = (await periodResponse.json()).pay_period.id;
    const page = await context.newPage();
    await page.goto(`/companies/${companyId}/pay-runs/${periodId}/work`);
    for (const employee of employees) {
      const pay = page.getByRole('textbox', { name: `Pay this period for ${employee.first_name} ${employee.last_name}`, exact: true });
      await expect(pay).toBeVisible();
      await pay.fill('9000.00');
      await pay.press('Tab');
    }
    const calculated = page.waitForResponse((response) => response.url().endsWith('/run_payroll') && response.request().method() === 'POST');
    await page.getByRole('button', { name: /^(Calculate Payroll|Recalculate)$/ }).click();
    const body = await (await calculated).json();
    expect(body.results.errors).toEqual([]);
    for (const [index, employee] of employees.entries()) {
      const item = body.pay_period.payroll_items.find((row: { employee_id: number }) => row.employee_id === employee.id);
      expect(Number(item.gross_pay)).toBe([9900.00, 10200.00][index]);
      expect(Number(item.net_pay)).toBe([6466.34, 6443.39][index]);
      const detail = await api.get(`admin/pay_periods/${periodId}/payroll_items/${item.id}`);
      expect(detail.ok()).toBeTruthy();
      expect(Number((await detail.json()).payroll_item.ytd.retirement)).toBe([900.00, 1200.00][index]);
    }
    await page.reload();
    await expect(page.getByRole('textbox', { name: 'Pay this period for Scenario Owner1', exact: true })).toHaveValue('9000.00');
    await page.getByRole('textbox', { name: 'Pay this period for Scenario Owner1', exact: true }).scrollIntoViewIfNeeded();
    await page.screenshot({ path: 'test-results/client-variable-pay-worksheet.png', fullPage: true });
  } finally {
    await context.close();
    await api.dispose();
  }
});
