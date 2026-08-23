import { expect, request as playwrightRequest, test, type APIRequestContext, type APIResponse } from '@playwright/test';
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
