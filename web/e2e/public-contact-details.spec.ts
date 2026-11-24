import { expect, test, type Page, type Route } from '@playwright/test';

function json(route: Route, body: unknown, status = 200): Promise<void> {
  return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

async function mockClientSession(page: Page): Promise<void> {
  await page.route('**/api/v1/auth/me', (route) => json(route, {
    user: {
      id: 7,
      email: 'emma.client@example.test',
      name: 'Elena Mercer',
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

  await expect(table.getByText(/Someone else updated this employee while you were editing/i)).toBeVisible();
  await expect(table.getByText(/Someone else changed this to/i)).toBeVisible();
  await expect(table.getByText('coworker.update@example.com')).toBeVisible();

  // First PATCH only sent the edited field + stale revision + baseline.
  expect(patchBodies[0]).toEqual({
    employee: { email: 'my.final@example.com' },
    row_revision: '2026-11-24T01:00:00.000000Z',
    baseline_values: { email: 'maria.old@example.com' },
    response_view: 'contact',
  });

  // Clicking Keep yours retries with the latest revision and keeps coworker's address.
  await table.getByRole('button', { name: 'Keep yours' }).click();
  await expect(table.getByText('Saved')).toBeVisible();
  await expect(table.getByLabel('Email for Maria Cruz')).toHaveValue('my.final@example.com');
  await expect(table.getByLabel('Street address for Maria Cruz')).toHaveValue('200 Coworker Blvd');
  expect(patchBodies[1]).toEqual({
    employee: { email: 'my.final@example.com' },
    row_revision: '2026-11-24T01:05:00.000000Z',
    baseline_values: { email: 'coworker.update@example.com' },
    response_view: 'contact',
  });
});

test('Use theirs drops only the conflicting email draft and keeps the phone edit ready to save', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await mockClientSession(page);

  const mariaInitial = makeEmployee();
  const mariaCoworker = makeEmployee({
    email: 'coworker.update@example.com',
    contact_revision: '2026-11-24T01:05:00.000000Z',
    updated_at: '2026-11-24T01:05:00Z',
  });
  const patchBodies: Array<Record<string, unknown>> = [];

  await page.route('**/api/v1/client/employees**', async (route) => {
    const method = route.request().method();
    if (method === 'GET') {
      return json(route, {
        data: [mariaInitial],
        meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, needs_contact_details_count: 0 },
      });
    }
    if (method === 'PATCH') {
      patchBodies.push(route.request().postDataJSON() as Record<string, unknown>);
      if (patchBodies.length === 1) {
        return json(route, {
          error: 'Someone else updated this employee while you were editing.',
          code: 'contact_revision_conflict',
          conflicting_fields: ['email'],
          contact_revision: mariaCoworker.contact_revision,
          current_values: { email: mariaCoworker.email, phone: mariaCoworker.phone },
          data: mariaCoworker,
        }, 409);
      }
      return json(route, {
        data: { ...mariaCoworker, phone: '+16715550177', contact_revision: '2026-11-24T01:06:00.000000Z' },
        contact_warnings: [],
      });
    }
    return route.continue();
  });

  await page.goto('/companies/6/employees/contact-details');
  const table = page.locator('table');
  await expect(table.getByLabel('Email for Maria Cruz')).toHaveValue('maria.old@example.com');

  await table.getByLabel('Email for Maria Cruz').fill('my.final@example.com');
  await table.getByLabel('Mobile for Maria Cruz').fill('555-0177');
  await table.getByRole('button', { name: 'Save Maria Cruz' }).click();
  await expect(table.getByText(/Someone else changed this to/i)).toBeVisible();

  await table.getByRole('button', { name: 'Use theirs' }).click();
  await expect(table.getByLabel('Email for Maria Cruz')).toHaveValue('coworker.update@example.com');
  await expect(table.getByLabel('Mobile for Maria Cruz')).toHaveValue('555-0177');
  await expect(page.getByText(/1 unsaved row/i)).toBeVisible();

  await table.getByRole('button', { name: 'Save Maria Cruz' }).click();
  await expect(table.getByText('Saved')).toBeVisible();
  await expect(table.getByLabel('Mobile for Maria Cruz')).toHaveValue('+16715550177');
  expect(patchBodies[1]).toEqual({
    employee: { phone: '555-0177' },
    row_revision: '2026-11-24T01:00:00.000000Z',
    baseline_values: { phone: '+16715550100' },
    response_view: 'contact',
  });
});

test('paging away during a coworker save and returning triggers a 409 conflict banner instead of overwriting (desktop and 390px mobile)', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await mockClientSession(page);

  let coworkerSaved = false;
  const patchBodies: Array<Record<string, unknown>> = [];

  await page.route('**/api/v1/client/employees**', async (route) => {
    const method = route.request().method();
    const url = new URL(route.request().url());

    if (method === 'GET') {
      const pageNum = Number(url.searchParams.get('page') || '1');
      if (pageNum === 2) {
        // Simulate a coworker editing Maria's email while the user is on page 2.
        coworkerSaved = true;
        return json(route, {
          data: [makeEmployee({ id: 202, first_name: 'Zoe', last_name: 'Zeta', email: 'zoe@example.com' })],
          meta: { current_page: 2, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 2 },
        });
      }
      return json(route, {
        data: [
          makeEmployee({
            id: 101,
            first_name: 'Maria',
            last_name: 'Cruz',
            email: coworkerSaved ? 'coworker.saved@example.com' : 'maria.old@example.com',
            address_line1: coworkerSaved ? '300 Coworker St' : '100 Marine Corps Dr',
            contact_revision: coworkerSaved ? '2026-11-24T02:00:00.000000Z' : '2026-11-24T01:00:00.000000Z',
            updated_at: coworkerSaved ? '2026-11-24T02:00:00Z' : '2026-11-24T01:00:00Z',
          }),
        ],
        meta: { current_page: 1, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 2 },
      });
    }

    if (method === 'PATCH') {
      const body = route.request().postDataJSON() as Record<string, unknown>;
      patchBodies.push(body);
      // Server conflict check: rev-1 + baseline maria.old@example.com collides with coworker's save!
      if (body.row_revision !== '2026-11-24T02:00:00.000000Z') {
        const latest = makeEmployee({
          id: 101,
          first_name: 'Maria',
          last_name: 'Cruz',
          email: 'coworker.saved@example.com',
          address_line1: '300 Coworker St',
          contact_revision: '2026-11-24T02:00:00.000000Z',
          updated_at: '2026-11-24T02:00:00Z',
        });
        return json(route, {
          error: 'Someone else updated this employee while you were editing.',
          code: 'contact_revision_conflict',
          conflicting_fields: ['email'],
          contact_revision: latest.contact_revision,
          current_values: { email: latest.email },
          data: latest,
        }, 409);
      }
      return json(route, {
        data: makeEmployee({
          email: 'my.draft@example.com',
          address_line1: '300 Coworker St',
          contact_revision: '2026-11-24T02:05:00.000000Z',
        }),
        contact_warnings: [],
      });
    }

    return route.continue();
  });

  await page.goto('/companies/6/employees/contact-details');
  const table = page.locator('table');
  await expect(table.getByLabel('Email for Maria Cruz')).toHaveValue('maria.old@example.com');

  // 1. Draft an edit on page 1.
  await table.getByLabel('Email for Maria Cruz').fill('my.draft@example.com');

  // 2. Page away to page 2 (triggers simulated coworker save).
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(table.getByLabel('Email for Zoe Zeta')).toHaveValue('zoe@example.com');

  // 3. Page back to page 1: untouched street address refreshes, drafted email stays intact.
  await page.getByRole('button', { name: 'Previous' }).click();
  await expect(table.getByLabel('Email for Maria Cruz')).toHaveValue('my.draft@example.com');
  await expect(table.getByLabel('Street address for Maria Cruz')).toHaveValue('300 Coworker St');

  // 4. Save -> must send original revision & baseline and show 409 conflict banner, NOT overwrite!
  await table.getByRole('button', { name: 'Save Maria Cruz' }).click();
  await expect(table.getByText(/Someone else changed this to/i)).toBeVisible();
  await expect(table.getByText('coworker.saved@example.com')).toBeVisible();
  await expect(table.getByText('my.draft@example.com')).toBeVisible();
  await expect(table.getByRole('button', { name: 'Keep yours' })).toBeVisible();
  await expect(table.getByRole('button', { name: 'Use theirs' })).toBeVisible();

  expect(patchBodies[0]).toEqual({
    employee: { email: 'my.draft@example.com' },
    row_revision: '2026-11-24T01:00:00.000000Z',
    baseline_values: { email: 'maria.old@example.com' },
    response_view: 'contact',
  });

  // 5. Verify the conflict banner is readable without horizontal overflow at 390px mobile width.
  await page.setViewportSize({ width: 390, height: 844 });
  const mobileAlert = page.locator('[role="alert"]').filter({ hasText: 'coworker.saved@example.com' }).last();
  await expect(mobileAlert).toBeVisible();
  await expect(mobileAlert.getByRole('button', { name: 'Keep yours' })).toBeVisible();
  await expect(mobileAlert.getByRole('button', { name: 'Use theirs' })).toBeVisible();
  const hasHorizontalOverflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
  expect(hasHorizontalOverflow).toBe(false);
});

test('out-of-range page URL clamps to the last page with results while keeping filters and pagination visible', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await mockClientSession(page);

  await page.route('**/api/v1/client/employees**', async (route) => {
    const url = new URL(route.request().url());
    const pageNum = Number(url.searchParams.get('page') || '1');
    if (pageNum > 2) {
      return json(route, {
        data: [],
        meta: { current_page: pageNum, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 60 },
      });
    }
    return json(route, {
      data: [makeEmployee({ id: 202, first_name: 'Zoe', last_name: 'Zeta', email: '' })],
      meta: { current_page: 2, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 60 },
    });
  });

  await page.goto('/companies/6/employees/contact-details?needs_contact_details=true&page=5');
  const table = page.locator('table');
  await expect(table.getByLabel('Email for Zoe Zeta')).toBeVisible();
  await expect(page.getByText('Page 2 of 2')).toBeVisible();
  await expect(page.getByRole('button', { name: /Previous/i })).toBeEnabled();
  await expect(page).toHaveURL(/needs_contact_details=true/);
  await expect(page).toHaveURL(/page=2/);
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

test('staff tab switch to Shared & placeholder emails and back preserves pending drafts', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });

  await page.route('**/api/v1/auth/me', (route) => json(route, {
    user: {
      id: 2,
      email: 'staff.admin@example.test',
      name: 'Staff Admin',
      role: 'org_admin',
      organization_id: 1,
      organization_name: 'Cornerstone',
      company_id: 6,
      company_name: "MoSa's Demo",
      home_company_id: 6,
      assigned_company_ids: [6],
      capabilities: ['manage_client_configuration', 'manage_organization'],
    },
  }));
  await page.route('**/api/v1/companies', (route) => json(route, {
    companies: [{
      id: 6,
      name: "MoSa's Demo",
      active: true,
      payroll_environment: 'live',
      workspace_can_write: true,
      client_capabilities: ['manage_client_configuration', 'manage_organization'],
    }],
    can_manage_clients: true,
    can_view_client_management: true,
    can_switch_company: true,
    current_company_id: 6,
  }));
  await page.route('**/api/v1/admin/employees**', (route) => json(route, {
    data: [makeEmployee({ id: 101, first_name: 'Maria', last_name: 'Cruz', email: 'maria.old@example.com' })],
    meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, needs_contact_details_count: 0 },
  }));
  await page.route('**/api/v1/admin/employee_contact_hygiene/shared_emails**', (route) => json(route, {
    summary: { companies_affected: 0, distinct_flagged_emails: 0, total_employee_records: 0, active_employee_records: 0 },
    can_manage_placeholders: true,
    marked_placeholders: [],
    companies: [],
  }));

  await page.goto('/companies/6/employees/contact-details');
  const table = page.locator('table');
  await expect(table.getByLabel('Email for Maria Cruz')).toHaveValue('maria.old@example.com');

  await table.getByLabel('Email for Maria Cruz').fill('maria.unsaved@example.com');
  await expect(page.getByText('1 unsaved row')).toBeVisible();

  await page.getByRole('tab', { name: /Shared & placeholder emails/i }).click();
  await expect(page.getByRole('heading', { name: 'Shared and placeholder emails' })).toBeVisible();

  await page.getByRole('tab', { name: /Contact details/i }).click();
  await expect(table.getByLabel('Email for Maria Cruz')).toHaveValue('maria.unsaved@example.com');
  await expect(page.getByText('1 unsaved row')).toBeVisible();
});
