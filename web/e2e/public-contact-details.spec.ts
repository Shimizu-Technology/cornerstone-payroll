import { expect, test, type Page, type Route } from '@playwright/test';

function json(route: Route, body: unknown, status = 200): Promise<void> {
  return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

async function mockClientSession(page: Page): Promise<void> {
  await page.route('**/api/v1/auth/me', (route) => json(route, {
    user: {
      id: 7,
      email: 'emma.client@example.test',
      name: 'Emma Pleadwell',
      role: 'client',
      organization_id: 1,
      organization_name: 'Cornerstone',
      company_id: 6,
      company_name: "MoSa's Demo",
      home_company_id: 6,
      assigned_company_ids: [6],
    },
  }));
  await page.route('**/api/v1/companies', (route) => json(route, {
    companies: [{ id: 6, name: "MoSa's Demo", active: true, payroll_environment: 'live', workspace_can_write: true }],
    can_manage_clients: false,
    can_view_client_management: false,
    can_switch_company: false,
    current_company_id: 6,
  }));
}

function makeEmployee(overrides: Record<string, unknown> = {}) {
  return {
    id: 101,
    company_id: 6,
    first_name: 'Maria',
    last_name: 'Cruz',
    email: 'maria.old@example.com',
    phone: '+16715550100',
    employment_type: 'hourly',
    pay_rate: 16,
    pay_frequency: 'biweekly',
    filing_status: 'single',
    allowances: 0,
    additional_withholding: 0,
    w4_dependent_credit: 0,
    w4_step2_multiple_jobs: false,
    w4_step4a_other_income: 0,
    w4_step4b_deductions: 0,
    w4_form_version: 2020,
    retirement_rate: 0,
    roth_retirement_rate: 0,
    status: 'active',
    address_line1: '100 Marine Corps Dr',
    address_line2: '',
    city: 'Hagatna',
    state: 'GU',
    zip: '96910',
    email_verified_at: null,
    phone_confirmed_by_employee_at: null,
    contact_source: 'client',
    contact_revision: '2026-11-24T01:00:00.000000Z',
    contact_details_status: { needs_contact_details: false, missing_fields: [], email_issue: null },
    created_at: '2026-11-01T00:00:00Z',
    updated_at: '2026-11-24T01:00:00Z',
    ...overrides,
  };
}

test('contact details grid handles 409 conflict with keep/discard and partial field updates', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await mockClientSession(page);

  const mariaInitial = makeEmployee();
  const mariaCoworker = makeEmployee({
    email: 'coworker.update@example.com',
    address_line1: '200 Coworker Blvd',
    contact_revision: '2026-11-24T01:05:00.000000Z',
    updated_at: '2026-11-24T01:05:00Z',
  });

  const patchBodies: Array<Record<string, unknown>> = [];
  let patchCount = 0;

  await page.route('**/api/v1/client/employees**', async (route) => {
    const method = route.request().method();
    if (method === 'GET') {
      return json(route, {
        data: [mariaInitial],
        meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, needs_contact_details_count: 0 },
      });
    }
    if (method === 'PATCH') {
      patchCount += 1;
      patchBodies.push(route.request().postDataJSON() as Record<string, unknown>);
      if (patchCount === 1) {
        return json(route, {
          error: 'Another user updated this employee while you were editing.',
          code: 'contact_revision_conflict',
          conflicting_fields: ['email'],
          contact_revision: mariaCoworker.contact_revision,
          current_values: { email: mariaCoworker.email },
          data: mariaCoworker,
        }, 409);
      }
      return json(route, {
        data: {
          ...mariaCoworker,
          email: 'my.final@example.com',
          contact_revision: '2026-11-24T01:06:00.000000Z',
        },
        contact_warnings: [],
      });
    }
    return route.continue();
  });

  await page.goto('/companies/6/employees/contact-details');
  await expect(page.getByRole('heading', { name: 'Contact Details' })).toBeVisible();
  const table = page.locator('table');
  await expect(table.getByLabel('Email for Maria Cruz')).toHaveValue('maria.old@example.com');

  await table.getByLabel('Email for Maria Cruz').fill('my.final@example.com');
  await table.getByRole('button', { name: 'Save Maria Cruz' }).click();

  await expect(table.getByText(/Conflict: someone else updated this row before you saved/i)).toBeVisible();
  await expect(table.getByText('coworker.update@example.com')).toBeVisible();

  // First PATCH only sent the edited field + stale revision + baseline.
  expect(patchBodies[0]).toEqual({
    employee: { email: 'my.final@example.com' },
    row_revision: '2026-11-24T01:00:00.000000Z',
    baseline_values: { email: 'maria.old@example.com' },
  });

  // Clicking Keep my changes retries with the latest revision and keeps coworker's address.
  await table.getByRole('button', { name: 'Keep my changes' }).click();
  await expect(table.getByText('Saved')).toBeVisible();
  await expect(table.getByLabel('Email for Maria Cruz')).toHaveValue('my.final@example.com');
  await expect(table.getByLabel('Street address for Maria Cruz')).toHaveValue('200 Coworker Blvd');
  expect(patchBodies[1]).toEqual({
    employee: { email: 'my.final@example.com' },
    row_revision: '2026-11-24T01:05:00.000000Z',
    baseline_values: { email: 'coworker.update@example.com' },
  });
});

test('contact details grid paginates on the server while keeping filters and pending edits', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await mockClientSession(page);

  let visitedPage2 = false;
  const requestedUrls: string[] = [];

  await page.route('**/api/v1/client/employees**', async (route) => {
    const url = new URL(route.request().url());
    requestedUrls.push(url.search);
    const pageNum = Number(url.searchParams.get('page') || '1');
    if (pageNum === 2) {
      visitedPage2 = true;
      return json(route, {
        data: [makeEmployee({ id: 202, first_name: 'Zoe', last_name: 'Zeta', email: 'zoe@example.com' })],
        meta: { current_page: 2, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 2 },
      });
    }
    return json(route, {
      data: [
        makeEmployee({
          id: 101,
          first_name: 'Alice',
          last_name: 'Adams',
          email: 'alice@example.com',
          phone: '',
          address_line1: visitedPage2 ? '999 Coworker Updated Rd' : '10 First St',
        }),
      ],
      meta: { current_page: 1, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 2 },
    });
  });

  await page.goto('/companies/6/employees/contact-details?needs_contact_details=true');
  const table = page.locator('table');
  await expect(table.getByLabel('Mobile for Alice Adams')).toBeVisible();
  await expect(table.getByLabel('Street address for Alice Adams')).toHaveValue('10 First St');

  // Make an unsaved edit on page 1.
  await table.getByLabel('Mobile for Alice Adams').fill('555-0142');
  await expect(page.getByText('1 unsaved row')).toBeVisible();

  // Navigate to page 2 -> filter stays active and unsaved badge persists.
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(table.getByLabel('Email for Zoe Zeta')).toHaveValue('zoe@example.com');
  await expect(page.getByText('Page 2 of 2')).toBeVisible();
  await expect(page.getByText('1 unsaved row')).toBeVisible();
  expect(requestedUrls.some((qs) => qs.includes('page=2') && qs.includes('needs_contact_details=true'))).toBe(true);

  // Navigate back to page 1 -> untouched address refreshes from server while edited phone stays!
  await page.getByRole('button', { name: 'Previous' }).click();
  await expect(table.getByLabel('Mobile for Alice Adams')).toHaveValue('555-0142');
  await expect(table.getByLabel('Street address for Alice Adams')).toHaveValue('999 Coworker Updated Rd');
});
