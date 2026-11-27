import { expect, test, type Page } from '@playwright/test';
import { detailFor, employeeBaseUrl, json, mockEmployeeApi, signIn, statements2026, tenantQuery } from './employee-fixtures';
import type { EmployeeTaxFormCopy, EmployeeTaxForms } from '../src/services/employee-tax-forms-api';

const company = { id: 6, name: 'Demo Clockwork Bakery', active: true, test_workspace: false };
const copiesPath = '/api/v1/admin/employee_tax_forms';
const person = 'Fictional Worker A';
const posted: EmployeeTaxFormCopy = {
  id: 51, employee_id: 71, employee_name: person, status: 'posted', revision: 1, withdrawn_at: null, withdrawn_by: null, posted_at: '2027-01-22T22:00:00Z', withdrawal_note: null,
  inputs_changed_since_posting: true, notice: { status: 'sent', delivery_status: 'bounced' },
};

async function mockStaff(page: Page, canManage: boolean) {
  await page.route('**/api/v1/auth/me', (route) => json(route, { user: {
    id: 7, name: 'Demo Staff Reviewer', email: 'reviewer@example.test', role: 'admin',
    organization_id: 1, company_id: company.id, home_company_id: company.id, assigned_company_ids: [company.id],
  } }));
  await page.route('**/api/v1/companies', (route) => json(route, {
    companies: [{ ...company, workspace_can_write: true, client_capabilities: canManage ? ['manage_client_administration'] : [] }],
    current_company_id: company.id, can_switch_company: false,
  }));
  await page.route('**/api/v1/admin/year_end/checklist?*', (route) => json(route, { data: {
    company, tax_year: 2026, status: 'ready', issue_count: 0, next_step: null, files_w2: false, files_1099: false,
    permissions: { can_record_decision: false, can_acknowledge: false, can_mark_ready: false }, steps: [],
  } }));
}

async function expectNoSideScroll(page: Page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(page.viewportSize()!.width);
}

for (const width of [390, 1280]) {
  test(`staff posts, reviews and withdraws W-2 copies at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 });
    await mockStaff(page, true);
    const listing: EmployeeTaxForms = {
      can_post: false, blocker_message: 'Mark the W-2s ready on the current figures first.',
      w2_delivery: null, documents: [],
    };
    let queued = false;
    let withdrawAttempts = 0;
    await page.route(`**${copiesPath}**`, async (route) => {
      const request = route.request();
      expect(request.headers()['x-company-id']).toBe('6');
      const url = new URL(request.url());
      if (url.pathname === copiesPath) {
        expect(url.searchParams.get('year')).toBe('2026');
        return json(route, listing);
      }
      if (url.pathname.endsWith('/post_copies')) {
        expect(request.method()).toBe('POST');
        expect(request.postDataJSON()).toEqual({ year: 2026 });
        queued = true;
        return json(route, { queued: true }, 202);
      }
      expect(url.pathname).toBe(`${copiesPath}/51/withdraw`);
      expect(request.postDataJSON()).toEqual({ reason: 'Year-end figures were corrected' });
      withdrawAttempts += 1;
      if (withdrawAttempts === 1) return json(route, { error: 'Could not withdraw the copy. Try again.' }, 422);
      const withdrawn = { ...posted, status: 'withdrawn' as const, withdrawn_at: '2027-01-23T23:00:00Z', withdrawn_by: 'Demo Staff Reviewer', inputs_changed_since_posting: false, withdrawal_note: 'Year-end figures were corrected' };
      listing.documents[0] = withdrawn;
      return json(route, { document: withdrawn });
    });
    await page.route('**/api/v1/admin/employee_app_settings/w2_delivery', (route) => {
      expect(route.request().method()).toBe('PATCH');
      expect(route.request().headers()['x-company-id']).toBe('6');
      listing.w2_delivery = route.request().postDataJSON().w2_delivery;
      return json(route, { data: { w2_delivery: listing.w2_delivery } });
    });

    await page.goto('/companies/6/year-end?year=2026');
    await expect(page.getByRole('heading', { name: 'Employee app W-2 copies' })).toBeVisible();
    const post = page.getByRole('button', { name: 'Post 2026 copies' });
    await expect(page.getByText(listing.blocker_message!)).toBeVisible();
    await expect(post).toBeDisabled();
    await expect(page.getByText('No copies have posted for 2026.')).toBeVisible();

    const delivery = page.getByLabel('Paper W-2 delivery');
    await delivery.selectOption('mailed');
    await page.getByRole('button', { name: 'Save delivery' }).click();
    await expect(page.getByText('Paper W-2 delivery saved.')).toBeVisible();
    expect(listing.w2_delivery).toBe('mailed');
    await page.reload();
    await expect(delivery).toHaveValue('mailed');

    listing.can_post = true;
    listing.blocker_message = null;
    await page.getByRole('button', { name: 'Refresh list' }).click();
    await post.click();
    await expect(page.getByText(/^Posting requested/)).toBeVisible();
    expect(queued).toBe(true);

    listing.can_post = false;
    listing.blocker_message = 'Mark the W-2s ready on the current figures first.';
    listing.documents = [
      posted,
      { ...posted, id: 52, employee_id: 72, employee_name: 'Fictional Worker B', inputs_changed_since_posting: false, notice: { status: 'skipped', delivery_status: 'unknown' } },
      { ...posted, id: 53, employee_id: 73, employee_name: 'Fictional Worker C', inputs_changed_since_posting: false, notice: { status: 'sent', delivery_status: 'unknown' } },
      { ...posted, id: 54, employee_id: 74, employee_name: 'Fictional Worker D', inputs_changed_since_posting: false, notice: null },
    ];
    await page.getByRole('button', { name: 'Refresh list' }).click();
    for (const label of ['Bounced', 'Skipped', 'Sent · Delivery unknown', 'Not scheduled yet']) {
      await expect(page.getByText(new RegExp(`Email notice: ${label}$`))).toBeVisible();
    }
    await expect(page.getByText('W-2 figures changed since posting.')).toBeVisible();
    await expectNoSideScroll(page);

    await page.getByRole('button', { name: `Withdraw copy for ${person}` }).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog.getByRole('button', { name: 'Withdraw copy' })).toBeDisabled();
    await dialog.getByLabel('Reason for withdrawal').fill('Year-end figures were corrected');
    await dialog.getByRole('button', { name: 'Withdraw copy' }).click();
    await expect(dialog.getByRole('alert')).toContainText('Could not withdraw the copy. Try again.');
    await expect(dialog.getByLabel('Reason for withdrawal')).toHaveValue('Year-end figures were corrected');
    await dialog.getByRole('button', { name: 'Withdraw copy' }).click();
    await expect(page.getByText('Copy withdrawn.', { exact: true })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Copy history' })).toBeFocused();
    await page.reload();
    await expect(page.getByText('Withdrawal reason: Year-end figures were corrected')).toBeVisible();
    await expect(page.getByRole('button', { name: `Withdraw copy for ${person}` })).toHaveCount(0);
  });

  test(`employee opens the original pay stub PDF at ${width}px`, async ({ page }) => {
    test.skip(Boolean(process.env.E2E_BASE_URL && !process.env.E2E_EMPLOYEE_WEB_PORT), 'Needs an employee dev server');
    await page.setViewportSize({ width, height: 844 });
    await signIn(page);
    const log = await mockEmployeeApi(page);
    const revised = detailFor(statements2026.find((statement) => statement.id === 902)!);
    await page.route('**/api/v1/employee/statements/902', (route) => json(route, {
      ...revised,
      earlier_versions: [
        { id: '897', status: 'replaced', corrected: false, posted_at: '2026-09-27T02:00:00Z', payment_line: 'Direct deposit' },
        { id: '892', status: 'replaced', corrected: true, posted_at: '2026-09-26T02:00:00Z', payment_line: 'Check #1034' },
        { id: '882', status: 'replaced', posted_at: '2026-09-25T02:00:00Z', payment_line: 'Check #1034' },
      ],
    }));

    await page.goto(`${employeeBaseUrl}/pay/902?${tenantQuery}`);
    const history = page.getByText('Corrected — see the original');
    await expect(history).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Original pay stub' })).toBeHidden();
    await history.focus();
    await page.keyboard.press('Enter');
    const correction = page.getByRole('listitem').filter({ has: page.getByRole('heading', { name: 'Earlier correction' }) });
    await expect(correction.getByText('Check #1034')).toBeVisible();
    const detailsUpdate = page.getByRole('listitem').filter({ has: page.getByRole('heading', { name: 'Earlier pay stub' }) });
    await expect(detailsUpdate.getByText('Direct deposit')).toBeVisible();
    await expectNoSideScroll(page);

    await expect(page.getByRole('article')).toContainText('$•••');
    const download = page.waitForEvent('download');
    await page.getByRole('button', { name: 'Download original PDF (shows amounts)' }).click();
    expect((await download).suggestedFilename()).toBe('original-pay-stub-2026-09-25.pdf');
    expect(log.requests.find((request) => request.path === '/employee/statements/882/pdf')?.headers['x-employee-link-id']).toBe('42');
    expect(log.requests.some((request) => request.path === '/employee/statements/882')).toBe(false);
    await expect(page).toHaveURL(/\/pay\/902/);
  });
}

test('staff without client administration access never loads W-2 copies', async ({ page }) => {
  await mockStaff(page, false);
  const requests: string[] = [];
  page.on('request', (request) => {
    if (new URL(request.url()).pathname === copiesPath) requests.push(request.url());
  });
  await page.goto('/companies/6/year-end?year=2026');
  await expect(page.getByText('Ready', { exact: true })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Employee app W-2 copies' })).toHaveCount(0);
  expect(requests).toEqual([]);
});
