import { expect, request as playwrightRequest, test, type APIRequestContext, type APIResponse, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

interface Gate0Fixture {
  schema_version: number;
  company_id: number;
  other_company_id: number;
  admin_email: string;
  manager_email: string;
  accountant_email: string;
  client_email: string;
  inactive_user_email: string;
  employee_id: number;
  client_employee_id: number;
  other_employee_id: number;
  workflow_pay_period_id: number;
  workflow_payroll_item_id: number;
  time_import_pay_period_id: number;
  time_tracking_source_id: number;
  first_time_import_id: number;
  retry_time_import_id: number;
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

  test('keeps accountant payroll operations available while denying client configuration', async ({ browser }) => {
    const payrollPeriods = await accountantApi.get('admin/pay_periods');
    expect(payrollPeriods.ok()).toBeTruthy();

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
    await expect(accountantPage.getByRole('link', { name: 'Pay Schedule' })).toHaveCount(0);
    await expect(accountantPage.getByRole('link', { name: 'Client Changes' })).toHaveCount(0);

    await accountantPage.goto('/pay-schedule-settings');
    await expect(accountantPage).toHaveURL(/\/app$/);
    await accountantContext.close();
  });

  test('hides prior-company dashboard data while a company switch is loading', async ({ browser }): Promise<void> => {
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
    await expect(page.getByText('2 total records')).toBeVisible();
    await page.getByRole('button', { name: /Synthetic Payroll Company/ }).click();
    await page.getByRole('button', { name: /Synthetic Boundary Company/ }).click();
    await boundaryRequestStarted;
    await expect(page.getByText('2 total records')).toHaveCount(0);
    await expect(page.getByText('1 total records')).toHaveCount(0);

    releaseBoundaryResponse?.();
    await expect(page.getByText('1 total records')).toBeVisible();
    await context.close();
  });

  test('binds the fixture identity, rejects inactive access, and enforces role and company boundaries', async () => {
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

  test('keeps SSNs masked and routes client payroll changes to staff approval', async () => {
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

  test('reports an unavailable time source without leaking its secret', async () => {
    const response = await adminApi.post(
      `admin/pay_periods/${fixture.time_import_pay_period_id}/preview_time_tracking_import`,
      { data: { source_id: fixture.time_tracking_source_id } },
    );
    expect(response.status()).toBe(422);
    const body = JSON.stringify(await responseJson(response));
    expect(body).not.toContain('gate0-fixture-secret-must-never-leak');
    expect(body).not.toMatch(/shared[_ -]?secret/i);
  });

  test('keeps company, queue, and relationship context across canonical payroll records', async ({ browser }) => {
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

    await page.route('**/api/v1/admin/pay_periods**', async (route): Promise<void> => {
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

    releaseDelayedResponse?.();
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

    releaseDelayedEmployeeResponse?.();
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

  test('redirects legacy record URLs without creating back-navigation loops', async ({ browser }) => {
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

    await context.close();
  });

  test('keeps connected payroll records usable on a mobile viewport', async ({ browser }) => {
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

  test('calculates, reviews, rolls back approval, commits, and rejects a retry or edit after commit', async ({ page }) => {
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
    await page.getByRole('button', { name: 'View', exact: true }).first().click();
    await expect(page).toHaveURL(new RegExp(
      `/companies/${fixture.company_id}/pay-runs/\\d+/overview\\?return_to=${encodeURIComponent(listUrl)}`,
    ));
    await page.getByRole('button', { name: 'Back to List', exact: true }).click();
    await expect(page).toHaveURL(listUrl);

    await context.close();
  });

  test('preserves a filtered pay-run return path when opening a correction workspace', async ({ page }): Promise<void> => {
    const voidResponse = await adminApi.post(
      `admin/pay_periods/${fixture.workflow_pay_period_id}/void`,
      { data: { reason: 'Verify filtered correction navigation' } },
    );
    expect(voidResponse.ok()).toBeTruthy();

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

  test('applies time to an editable period and rejects a second import after commit', async () => {
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
});
