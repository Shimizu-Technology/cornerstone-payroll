import { expect, test, type Page } from '@playwright/test';

async function mockProfile(page: Page) {
  const patches: Record<string, unknown>[] = [];
  const assignments: Record<string, unknown>[] = [];
  const employee = {
    id: 31, company_id: 1, first_name: 'Imported', last_name: 'Employee', full_name: 'Imported Employee',
    ssn: '000000001', employment_type: 'salary', salary_type: 'variable', pay_rate: 0,
    status: 'active', pay_frequency: 'biweekly', filing_status: 'single', allowances: 0,
    additional_withholding: 0, w4_dependent_credit: 2000, w4_form_version: 2025,
    w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0,
    w4_effective_on: '2026-09-07', hire_date: null, retirement_rate: 0, roth_retirement_rate: 0,
    configuration_source: 'quickbooks_history', configuration_review_status: 'needs_review',
    configuration_review_items: [
      { code: 'verify_hire_date', message: 'Verify hire date', fields: ['hire_date'] },
      { code: 'employee_address_missing', message: 'Verify address', fields: ['address_line1', 'city', 'state', 'zip'] },
    ],
  };
  const field = { id: 5, name: 'Scheduled deduction', kind: 'deduction', amount_type: 'fixed', category: 'other', tax_treatment: 'post_tax', active: true, default_amount: 250 };
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    const method = route.request().method();
    let body: unknown = { data: [], meta: { total_pages: 1 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, email: 'review@example.test', name: 'Review Admin', role: 'admin', organization_id: 1, company_id: 1, assigned_company_ids: [1] } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Review Client', active: true, payroll_environment: 'live', pay_frequency: 'biweekly' }], can_manage_clients: true, can_switch_company: false, current_company_id: 1 };
    else if (path.endsWith('/employees/31')) {
      if (method === 'PATCH') patches.push(route.request().postDataJSON().employee);
      body = { data: employee };
    } else if (path.endsWith('/admin/payroll_fields')) body = { payroll_fields: [field] };
    else if (path.endsWith('/payroll_fields/bulk_update')) {
      assignments.push(route.request().postDataJSON());
      body = { employee_payroll_fields: [] };
    } else if (path.endsWith('/employee_payroll_fields')) body = { employee_payroll_fields: [] };
    else if (path.endsWith('/employees/31/payroll_fields')) body = { employee_payroll_fields: [{ id: 6, payroll_field_definition_id: 5, active: true, amount: 250, start_date: '2026-09-10', end_date: '2026-10-22', payroll_field: field }] };
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  return { patches, assignments };
}

test('saves a hire-only correction without asking to re-enter an unchanged imported SSN or missing address', async ({ page }) => {
  const { patches } = await mockProfile(page);
  await page.goto('/companies/1/employees/31/edit');
  await expect(page.locator('[name="ssn"]')).toHaveValue('000-00-0001');
  await page.locator('[name="hire_date"]').fill('2025-05-28');
  await page.getByRole('button', { name: 'Update Employee', exact: true }).click();
  await expect.poll(() => patches.length).toBe(1);
  expect(patches[0].hire_date).toBe('2025-05-28');
  expect(patches[0]).not.toHaveProperty('ssn');
  expect(patches[0]).not.toHaveProperty('configuration_review_items');
  expect(patches[0].w4_dependent_credit).toBe(2000);
});

test('requires confirmation when the identifier is actually replaced', async ({ page }) => {
  const { patches } = await mockProfile(page);
  await page.goto('/companies/1/employees/31/edit');
  await page.locator('[name="ssn"]').fill('000-00-0002');
  await expect(page.locator('[name="ssn_confirmation"]')).toHaveAttribute('required', '');
  await page.getByRole('button', { name: 'Update Employee', exact: true }).click();
  expect(patches).toHaveLength(0);
});
