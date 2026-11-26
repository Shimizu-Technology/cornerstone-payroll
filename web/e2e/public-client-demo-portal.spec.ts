import { expect, test, type Page, type Route } from '@playwright/test';

function json(route: Route, body: unknown): Promise<void> {
  return route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
}

// The exact company shape the server returns to a client of a demo employer:
// the live-client shape, with no workspace fields set.
const kitchen = {
  id: 97, organization_id: 4, organization_name: 'Cornerstone', name: 'Harbor Finch Kitchen', active: true,
  active_employees: 2, total_employees: 2, pay_frequency: 'biweekly', payroll_intake_source_types: [],
  historical_payroll_enabled: true, client_capabilities: [], client_management: false, payroll_environment: 'live',
  test_workspace: false, test_workspace_purpose: null, test_workspace_purpose_label: null, test_workspace_expires_at: null,
  test_workspace_archived_at: null, test_workspace_sealed_at: null, test_workspace_expired: false, test_workspace_read_only: false,
  migration_rehearsal_status: null, migration_source_company_id: null, migration_source_company_name: null,
  migration_source_batch_id: null, migration_rehearsal_completed_at: null, migration_rehearsal_error: null,
  practice_portal: false, workspace_can_write: true, workspace_write_permissions: null,
};

function employee(id: number, first_name: string, last_name: string, employment_type: string, pay_rate: number) {
  return {
    id, company_id: 97, first_name, last_name, email: null, phone: '+16715550161', employment_type, pay_rate,
    pay_frequency: 'biweekly', filing_status: 'single', allowances: 0, additional_withholding: 0, w4_dependent_credit: 0,
    w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0, w4_form_version: 2020,
    retirement_rate: 0, roth_retirement_rate: 0, status: 'active', address_line1: '101 Finch Cove Lane', address_line2: '',
    city: 'Hagåtña', state: 'GU', zip: '96910', email_verified_at: null, phone_confirmed_by_employee_at: null,
    contact_source: 'client', contact_revision: '2026-11-24T01:00:00.000000Z', updated_at: '2026-11-24T01:00:00Z',
  };
}

async function mockDemoClient(page: Page): Promise<void> {
  await page.route('**/api/v1/auth/me', (route) => json(route, { user: {
    id: 41, email: 'manager@harborfinch.example', name: 'Client Manager', role: 'client',
    organization_id: 4, organization_name: 'Cornerstone', company_id: 97,
    company_name: kitchen.name, home_company_id: 97, assigned_company_ids: [97],
  } }));
  await page.route('**/api/v1/companies', (route) => json(route, {
    companies: [kitchen], can_manage_clients: false, can_view_client_management: false,
    can_switch_company: false, billing_company_ids: [], current_company_id: 97,
  }));
  await page.route('**/api/v1/client/pay_periods**', (route) => json(route, {
    pay_periods: [{
      key: 'native:301', record_type: 'native', id: 301, company_id: 97,
      start_date: '2026-10-25', end_date: '2026-11-07', pay_date: '2026-11-13', status: 'committed',
      run_purpose: 'regular', includes_base_salary: true, includes_recurring_items: true,
      employee_count: 10, total_gross: 14382.5, total_net: 11640.12,
      source: { system: 'cornerstone', label: 'Cornerstone', detail: 'Cornerstone', locked: true },
      capabilities: { view: true },
    }],
    meta: { current_page: 1, per_page: 25, total_count: 1, total_pages: 1, statuses: { committed: 1 }, sources: {}, years: [2026] },
  }));
  await page.route('**/api/v1/client/employees**', (route) => json(route, {
    data: [employee(501, 'Employee', '01', 'hourly', 17.5), employee(502, 'Employee', '09', 'salary', 52000)],
    meta: { current_page: 1, total_pages: 1, total_count: 2, per_page: 50, needs_contact_details_count: 0 },
  }));
  await page.route('**/api/v1/client/departments**', (route) => json(route, { data: [] }));
  await page.route('**/api/v1/client/employee_intake_settings**', (route) => json(route, { data: {
    enabled: false, expires_at: null, reason: null, enabled_by_name: null, can_manage: false,
  } }));
}

for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
  test(`a demo employer's client portal looks like any client's at ${viewport.width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize(viewport);
    await mockDemoClient(page);

    await page.goto('/companies/97/pay-runs');
    await expect(page.getByText('Harbor Finch Kitchen').filter({ visible: true }).first()).toBeVisible();
    await expect(page.getByText(/Nov 13/).filter({ visible: true }).first()).toBeVisible();
    await expect(page.locator('body')).not.toContainText(/demo|practice|test workspace|copied history/i);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath(`demo-client-pay-runs-${viewport.width}.png`), fullPage: true });

    await page.goto('/companies/97/employees');
    await expect(page.getByText('Employee 01').filter({ visible: true }).first()).toBeVisible();
    await expect(page.locator('body')).not.toContainText(/demo|practice|test workspace/i);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath(`demo-client-employees-${viewport.width}.png`), fullPage: true });
  });
}
