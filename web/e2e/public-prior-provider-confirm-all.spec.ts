import { expect, test, type Page } from '@playwright/test';

// 20 pay dates × 3 employees, shaped like the Kasperbauer onboarding. All
// figures are synthetic.
const PAY_DATES = Array.from({ length: 10 }, (_, index) => index + 1).flatMap((month) => [
  `2026-${String(month).padStart(2, '0')}-${month === 10 ? '07' : '14'}`,
  `2026-${String(month).padStart(2, '0')}-28`,
]);
const EMPLOYEES = [1, 2, 3].map((id) => ({ id, name: `Employee ${id}`, ssn_last_four: `000${id}` }));

function check(employee: (typeof EMPLOYEES)[number], net = '1647.00') {
  return {
    employee_id: employee.id, source_employee_name: employee.name, provider_payment_reference: employee.id === 1 ? '007041' : '',
    gross_pay: '2000.00', federal_income_tax: '200.00', social_security_tax: '124.00', medicare_tax: '29.00',
    pretax_deductions: '0.00', after_tax_deductions: '0.00', net_pay: net,
    employer_social_security_tax: '124.00', employer_medicare_tax: '29.00', employer_contributions: '0.00',
    fit_taxable_wages: '2000.00', social_security_taxable_wages: '2000.00', social_security_taxable_tips: '0.00',
    medicare_taxable_wages: '2000.00', additional_medicare_taxable_wages: '0.00', non_taxable_pay: '0.00',
    reported_tips: '0.00', tips_paid_out: '0.00', retirement: '0.00', roth_retirement: '0.00', insurance: '0.00', loans: '0.00',
    earnings_breakdown: [{ label: 'Salary', amount: '2000.00' }], pretax_deduction_breakdown: [],
    after_tax_deduction_breakdown: [], employer_contribution_breakdown: [],
  };
}

function periods(failingNet = false) {
  return PAY_DATES.map((payDate, index) => {
    const day = new Date(`${payDate}T00:00:00Z`);
    const iso = (offset: number) => new Date(day.getTime() - offset * 86_400_000).toISOString().slice(0, 10);
    return {
      key: `run-${index + 1}`, run_id: index + 1, source_digest: `digest-${index + 1}`,
      start_date: iso(13), end_date: iso(1), pay_date: payDate, source_reference: '', register_totals: {},
      paychecks: EMPLOYEES.map((employee) => check(employee, failingNet && index === 5 && employee.id === 2 ? '1600.00' : '1647.00')),
    };
  });
}

const REGISTER_TOTALS = {
  gross_pay: '6000.00', federal_income_tax: '600.00', social_security_tax: '372.00', medicare_tax: '87.00',
  deductions: '0.00', net_pay: '4941.00', employer_taxes: '459.00', employer_contributions: '0.00',
};

async function fixture(page: Page, failingNet = false) {
  const requests: Record<string, unknown>[] = [];
  let draft: Record<string, unknown> = {
    payload: {
      tax_year: 2026, takeover_on: '2026-11-01', provider_name: 'Example previous provider',
      complete_history_confirmed: false, same_employer_confirmed: false,
      identities: Object.fromEntries(EMPLOYEES.map((employee) => [employee.id, { source_name: employee.name, ssn_last4: employee.ssn_last_four }])),
      periods: periods(failingNet),
    },
    step: 2, lock_version: 3, updated_at: '2026-11-03T00:00:00Z', updated_by_name: 'CEO',
  };
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = { data: [], meta: { total_pages: 1 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, role: 'accountant', capabilities: ['payroll_operations'], email: 'review@example.test', name: 'Reviewer', organization_id: 1, company_id: 1, assigned_company_ids: [1] } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Example payroll client', active: true, payroll_environment: 'live', pay_frequency: 'semimonthly' }], can_manage_clients: false, can_switch_company: false, current_company_id: 1 };
    else if (path.endsWith('/prior_provider_histories/draft/confirm_registers')) {
      const input = route.request().postDataJSON() as { payload: { periods: Record<string, unknown>[] }; register_name: string };
      requests.push(input);
      draft = {
        payload: {
          ...input.payload,
          periods: input.payload.periods.map((period) => ({ ...period, source_reference: `${input.register_name} — paid ${period.pay_date}`, register_totals: REGISTER_TOTALS })),
        },
        step: 2, lock_version: 4, updated_at: '2026-11-03T01:00:00Z', updated_by_name: 'Reviewer',
      };
      body = { draft };
    } else if (path.endsWith('/prior_provider_histories/draft')) body = { draft };
    else if (path.endsWith('/prior_provider_histories')) body = {
      company_id: 1, enabled: false, can_manage: true, candidates: periods(), eligible_run_count: 20,
      candidates_overflow: false, employees: EMPLOYEES, draft, onboardings: [], readiness_gaps: [],
    };
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  return requests;
}

async function shot(page: Page, name: string) {
  const dir = process.env.E2E_SCREENSHOT_DIR;
  if (dir) await page.screenshot({ path: `${dir}/${name}.png`, fullPage: false });
}

for (const width of [1280, 390]) {
  test(`confirm all lists failing pay dates and stays disabled at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await fixture(page, true);
    await page.goto('/companies/1/prior-provider-history');
    await page.getByLabel('Register name (fills every pay date)').fill('ADP payroll register 2026');
    const panel = page.getByRole('region', { name: /Already checked every pay date/ });
    await expect(panel.getByText('1 pay date needs individual review first:')).toBeVisible();
    await expect(panel.getByRole('button', { name: 'Paid Mar 28, 2026' })).toBeVisible();
    await expect(panel.getByText(/Employee 2: Net pay — Gross − taxes − deductions is \$1,647\.00; net differs by −\$47\.00/)).toBeVisible();
    await expect(panel.getByRole('button', { name: /Confirm all pay dates match/ })).toBeDisabled();
    await panel.scrollIntoViewIfNeeded();
    await shot(page, `confirm-all-failing-${width}`);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  });

  test(`confirm all attests 20 pay dates in one dialog at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    const requests = await fixture(page);
    await page.goto('/companies/1/prior-provider-history');
    await expect(page.getByText('0 of 20 pay dates match')).toBeVisible();
    await page.getByLabel('Register name (fills every pay date)').fill('ADP payroll register 2026');
    const panel = page.getByRole('region', { name: /Already checked every pay date/ });
    await panel.scrollIntoViewIfNeeded();
    // The long action label wraps inside its card instead of running off a phone screen.
    const actionButton = panel.getByRole('button', { name: /Confirm all pay dates match/ });
    const action = await actionButton.boundingBox();
    const card = await panel.boundingBox();
    expect(action && card && action.x + action.width <= card.x + card.width + 0.5).toBe(true);
    // The label itself must wrap rather than overflow the button.
    expect(await actionButton.evaluate((element) => element.scrollWidth <= element.clientWidth + 1)).toBe(true);
    await shot(page, `confirm-all-ready-${width}`);
    await panel.getByRole('button', { name: /Confirm all pay dates match/ }).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog.getByRole('heading', { name: 'Confirm all 20 pay dates?' })).toBeVisible();
    await expect(dialog.getByText('20 pay dates · 60 paychecks · $120,000.00 gross · $98,820.00 net')).toBeVisible();
    const statement = 'I confirm these 20 pay dates / 60 paychecks totaling $120,000.00 gross / $98,820.00 net match the previous provider’s paid registers.';
    await expect(dialog.getByRole('button', { name: 'Confirm all 20 pay dates' })).toBeDisabled();
    await dialog.getByLabel(statement).check();
    await shot(page, `confirm-all-dialog-${width}`);
    await dialog.getByRole('button', { name: 'Confirm all 20 pay dates' }).click();
    await expect(page.getByText(/All 20 pay dates are confirmed against the registers/)).toBeVisible();
    await expect(page.getByText('20 of 20 pay dates match')).toBeVisible();
    await expect(dialog).toBeHidden();
    await shot(page, `confirm-all-done-${width}`);
    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({
      register_name: 'ADP payroll register 2026', lock_version: 3, step: 2,
      acknowledgement: 'CONFIRM ALL PAY DATES MATCH THE PAID REGISTERS',
      confirmed: { period_count: 20, paycheck_count: 60, gross_pay: '120000.00', net_pay: '98820.00' },
    });
    // Check numbers entered per paycheck travel unchanged with the confirmation.
    expect((requests[0] as { payload: { periods: { paychecks: { provider_payment_reference: string }[] }[] } }).payload.periods[0].paychecks[0].provider_payment_reference).toBe('007041');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  });
}
