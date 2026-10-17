import { expect, test, type Page } from '@playwright/test';

async function fixture(page: Page, enabled = false, canManage = true): Promise<Record<string, unknown>[]> {
  let settings = { enabled, can_manage: canManage, reason: enabled ? 'Employer information pending' : null, expires_at: enabled ? new Date(Date.now() + 3_600_000).toISOString() : null, enabled_by_name: enabled ? 'Synthetic Admin' : null };
  const saved: Record<string, unknown>[] = [];
  const employee = {
    id: 31, company_id: 1, first_name: 'Pending', last_name: 'Worker', full_name: 'Pending Worker',
    employment_type: 'salary', salary_type: 'per_period', pay_rate: 1000, status: 'active',
    pay_frequency: 'biweekly', filing_status: 'single', allowances: 0, additional_withholding: 0,
    w4_dependent_credit: 0, w4_form_version: 2020, w4_step2_multiple_jobs: false,
    w4_step4a_other_income: 0, w4_step4b_deductions: 0, retirement_rate: 0, roth_retirement_rate: 0,
    intake_readiness: {
      profile_incomplete: true, missing_fields: ['ssn', 'hire_date', 'address_line1', 'city', 'state', 'zip', 'withholding_election'],
      exception: { reason: 'Employer information pending', authorized_by_name: 'Synthetic Admin', created_by_name: 'Chels', follow_up_owner_id: 2, follow_up_owner_name: 'Chels', follow_up_due_on: '2026-10-16', payroll_eligible_from: null, payroll_setup_confirmed_at: null, payroll_setup_confirmed_by_name: null },
    },
  };
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    const method = route.request().method();
    let body: unknown = { data: [], meta: { total_pages: 1, current_page: 1, total_count: 0 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, email: 'intake@example.test', name: 'Synthetic Admin', role: canManage ? 'org_admin' : 'accountant', company_id: 1, organization_id: 1, assigned_company_ids: [1], capabilities: canManage ? ['manage_client_configuration', 'manage_organization'] : [] } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Synthetic Intake Client', active: true, payroll_environment: 'live', pay_frequency: 'biweekly' }], can_manage_clients: canManage, can_switch_company: false, current_company_id: 1 };
    else if (path.endsWith('/employee_intake_settings')) {
      if (method === 'PATCH') {
        const input = route.request().postDataJSON().employee_intake_settings;
        settings = { ...settings, ...input, enabled_by_name: 'Synthetic Admin' };
      }
      body = { data: settings };
    } else if (path.endsWith('/admin/employees') && method === 'POST') {
      saved.push(route.request().postDataJSON().employee);
      body = { data: employee };
    } else if (path.endsWith('/employees/31')) {
      if (method === 'PATCH') saved.push(route.request().postDataJSON().employee);
      body = { data: employee };
    } else if (path.endsWith('/admin/employees')) body = { data: [employee], meta: { total_pages: 1, current_page: 1, total_count: 1 } };
    else if (path.endsWith('/employee_pay_history')) body = { report: { history: [], summary: {} } };
    else if (path.endsWith('/admin/payroll_fields')) body = { payroll_fields: [] };
    else if (path.endsWith('/payroll_fields')) body = { employee_payroll_fields: [] };
    else if (path.endsWith('/document_requirements')) body = { data: [], readiness: { total: 2, required: 2, satisfied: 0, ready_for_payroll: false } };
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  return saved;
}

test('administrator opens and closes the scoped temporary entry window', async ({ page }) => {
  await fixture(page);
  await page.goto('/companies/1/employees');
  await page.getByText('Allow incomplete entry temporarily').click();
  await page.getByLabel('Reason', { exact: true }).fill('Employer information pending');
  await page.getByRole('button', { name: 'Enable incomplete entry' }).click();
  await expect(page.getByText('Incomplete employee entry is temporarily enabled', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Require full details again' }).click();
  await expect(page.getByText('Full employee details required', { exact: true })).toBeVisible();
});

test('authorized incomplete entry saves a name and valid pay setup without inventing filing details', async ({ page }) => {
  const saved = await fixture(page, true);
  await page.goto('/companies/1/employees/new');
  await expect(page.getByText('Incomplete employee entry is enabled for this client.')).toBeVisible();
  await page.locator('[name="first_name"]').fill('Pending');
  await page.locator('[name="last_name"]').fill('Worker');
  await page.locator('[name="employment_type"]').selectOption('salary');
  await page.locator('[name="salary_type"]').selectOption('per_period');
  await page.locator('[name="pay_rate"]').fill('1000');
  await expect(page.locator('[name="ssn"]')).not.toHaveAttribute('required');
  await expect(page.locator('[name="ssn_confirmation"]')).not.toHaveAttribute('required');
  await expect(page.locator('[name="address_line1"]')).not.toHaveAttribute('required');
  await page.getByRole('button', { name: 'Create Employee', exact: true }).click();
  await expect.poll(() => saved.length).toBe(1);
  expect(saved[0].ssn).toBe('');
  expect(saved[0].hire_date).toBe('');
  expect(saved[0].address_line1).toBe('');
  expect(saved[0].w4_effective_on).toBe('');
});

test('restoring strict intake still allows partial completion of an approved employee', async ({ page }) => {
  const saved = await fixture(page, false);
  await page.goto('/companies/1/employees/31/edit');
  await page.locator('[name="city"]').fill('Hagåtña');
  await page.getByRole('button', { name: 'Update Employee', exact: true }).click();
  await expect.poll(() => saved.length).toBe(1);
  expect(saved[0].city).toBe('Hagåtña');
  expect(saved[0].zip).toBe('');
});

test('operators see profile gaps without administrator toggle controls on a phone', async ({ page }) => {
  await fixture(page, false, false);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/companies/1/employees');
  await expect(page.getByText('Profile incomplete', { exact: true }).first()).toBeVisible();
  await expect(page.getByText('Allow incomplete entry temporarily')).toHaveCount(0);
  await expect(page.getByLabel('Profile completeness')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)).toBe(false);
});
