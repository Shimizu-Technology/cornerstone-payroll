import { expect, test, type Page } from '@playwright/test';

async function setup(page: Page) {
  const year = new Date().getFullYear();
  const reviews: Record<string, unknown>[] = [];
  const employee = {
    id: 31, company_id: 1, first_name: 'Retirement', last_name: 'Example', full_name: 'Retirement Example',
    employment_type: 'hourly', status: 'active', pay_rate: 25, pay_frequency: 'biweekly', filing_status: 'single',
    retirement_rate: 0, roth_retirement_rate: 0, date_of_birth: `${year - 61}-12-31`,
    current_retirement_election: { id: 2, plan_name: 'Verified standard 401(k)', effective_on: `${year}-01-01`, participating: true, eligible: true,
      traditional_contribution_type: 'fixed', traditional_amount: 500, traditional_rate: 0, roth_contribution_type: 'fixed', roth_amount: 250, roth_rate: 0,
      eligible_compensation: 'gross_wages', catch_up_enabled: true, limit_priority: 'proportional', employer_match_mode: 'none',
      employer_match_rate: 0, employer_match_ytd_before_system: 0, employer_match_destination: 'traditional', true_up_policy: 'none',
      plan_type: 'standard_401k', limitation_year_type: 'calendar', plan_source_reference: 'Verified test plan', roth_available: true },
  };
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = { data: [], meta: { total_pages: 1 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, email: 'retirement@example.test', name: 'Review Admin', role: 'org_admin', organization_id: 1, company_id: 1, assigned_company_ids: [1], capabilities: ['manage_client_configuration', 'payroll_operations'] } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Retirement QA Client', active: true, payroll_environment: 'live', pay_frequency: 'biweekly' }], can_manage_clients: true, can_switch_company: false, current_company_id: 1 };
    else if (path.endsWith('/employees/31')) body = { data: employee };
    else if (path.endsWith('/annual_retirement_limits')) body = { data: [{ id: 1, tax_year: year, elective_deferral_limit: '24500.0', catch_up_limit: '8000.0', enhanced_catch_up_limit: '11250.0', roth_catch_up_wage_threshold: '150000.0', annual_additions_limit: '72000.0', compensation_limit: '360000.0', source_name: 'IRS Notice 2025-67', source_url: 'https://www.irs.gov/pub/irs-drop/n-25-67.pdf' }], can_manage: false };
    else if (path.endsWith('/retirement_year_inputs')) {
      if (route.request().method() === 'POST') {
        const input = route.request().postDataJSON().retirement_year_input;
        reviews.unshift({ ...input, id: reviews.length + 1 });
        body = { data: reviews[0] };
      } else body = { data: reviews };
    }
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  return { year, reviews };
}

for (const width of [390, 1440]) {
  test(`records verified catch-up evidence and retains history at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const { year, reviews } = await setup(page);
    await page.goto('/companies/1/employees/31/pay-setup');
    await expect(page.getByText('$35,750.00', { exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Review yearly records', exact: true }).click();
    await page.getByRole('combobox', { name: `${year - 1} wages from this employer`, exact: true }).selectOption('verified');
    await page.getByRole('textbox', { name: /^Verified prior-year employer Social Security wages/ }).fill('175000');
    await page.getByRole('textbox', { name: 'Employer wage evidence reference', exact: true }).fill('Synthetic W-2GU verification');
    await page.getByRole('textbox', { name: 'Evidence reference', exact: true }).fill('Synthetic administrator review');
    await page.getByRole('textbox', { name: 'Review note', exact: true }).fill('Verified wages and outside deferrals');
    await page.getByRole('button', { name: 'Save verified records', exact: true }).click();
    await expect(page.getByRole('status')).toContainText('retirement records saved');
    await expect(page.getByText(/Roth catch-up is required for this employer/)).toBeVisible();
    expect(reviews[0]).toMatchObject({ prior_year_wage_status: 'verified', prior_year_fica_wages: 175000, tax_year: year });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true);
    await page.getByRole('button', { name: 'Record a new review', exact: true }).click();
    await page.getByRole('textbox', { name: 'Review note', exact: true }).fill('Second verification retained');
    await page.getByRole('button', { name: 'Save verified records', exact: true }).click();
    await expect(page.getByText('Previous evidence reviews', { exact: true })).toBeVisible();
    expect(reviews).toHaveLength(2);
  });
}

for (const width of [390, 1440]) {
  test(`keeps a contribution error visible at the top after submitting a long form at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await setup(page);
    await page.goto('/companies/1/employees/31/pay-setup');
    await page.getByRole('button', { name: 'Record contribution change', exact: true }).click();
    await page.getByRole('button', { name: 'Save contribution change', exact: true }).click();
    const toast = page.locator('[data-feedback-portal] [role="alert"]');
    await expect(toast).toContainText('Choose the first pay date');
    await expect(toast).toBeVisible();
    expect(await page.evaluate(() => Math.max(window.scrollY, ...Array.from(document.querySelectorAll("*"), (element) => element.scrollTop)))).toBeGreaterThan(500);
    const position = await toast.boundingBox();
    expect(position?.y).toBeGreaterThanOrEqual(0);
    expect((position?.y || 0) + (position?.height || 0)).toBeLessThan(900);
    await page.getByRole('button', { name: /Dismiss notification: Choose the first pay date/ }).click();
    await expect(toast).toHaveCount(0);
    await page.getByRole('button', { name: 'Save contribution change', exact: true }).click();
    await expect(toast).toContainText('Choose the first pay date');
    await expect(toast).toHaveCount(1);
    await expect(page.getByRole('button', { name: 'Save contribution change', exact: true })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true);
  });
}
