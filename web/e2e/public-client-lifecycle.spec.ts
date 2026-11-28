import { expect, test, type Page, type Route } from '@playwright/test';

const companyId = 97;
const employeesPath = `/companies/${companyId}/employees`;
const today = '2026-11-28';
const staffNote = 'Please confirm the employee’s payment method.';

function json(route: Route, body: unknown) {
  return route.fulfill({ json: body });
}

function readiness(ready: boolean) {
  const required = [
    ['tax_id', 'Tax ID', 'SSN missing'],
    ['date_of_birth', 'Date of birth', 'Date of birth missing'],
    ['hire_date', 'Hire date', 'Hire date missing'],
    ['home_address', 'Home address', 'Home address missing'],
    ['pay_setup', 'Pay setup', 'Pay rate missing'],
    ['tax_form', 'W-4', 'W-4 missing'],
    ['payment_method', 'Payment method', 'Payment method not chosen'],
  ];
  return {
    status: ready ? 'ready' : 'incomplete',
    rates_on: '2026-11-30',
    w4_on: '2026-12-04',
    direct_deposit_missing_bank_details: ready,
    missing_keys: ready ? [] : required.map(([key]) => key),
    items: required.map(([key, label, missing]) => ({
      key, label, applicable: true, complete: ready, missing_label: ready ? null : missing,
    })),
  };
}

async function fixture(page: Page) {
  const company = { id: companyId, name: 'Synthetic Payroll Demo', active: true, pay_frequency: 'biweekly',
    employee_lifecycle_mode: 'client_managed', payroll_environment: 'live', workspace_can_write: true };
  const lifecycle = {
    own_record: false, today, compensation_default_on: '2026-11-30',
    approved_runs: [{ start_date: '2026-11-10', end_date: '2026-11-18' }],
    last_committed_period_end: '2026-11-12', former_access_years: 2, rehire_readiness: readiness(true),
  };
  const worker = {
    id: 501, company_id: companyId, first_name: 'Rowan', last_name: 'Fixture', employment_type: 'hourly',
    status: 'active', termination_date: null as string | null, pay_frequency: 'biweekly', pay_rate: 0,
    payment_delivery_method: null as string | null, readiness: readiness(false), lifecycle_edit_context: lifecycle,
  };
  const returned = { id: 24, employee_id: worker.id, event_kind: 'payment_method_change', return_note: staffNote };
  let created = false;
  let hasReturnedItem = false;
  await page.route('**/api/v1/**', (route) => json(route, { data: [], pay_stubs: [] }));
  await page.route('**/api/v1/cable_ticket', (route) => json(route, { ticket: 'synthetic-ticket', expires_in: 60 }));
  await page.routeWebSocket(/\/cable\?ticket=/, (socket) => {
    socket.send(JSON.stringify({ type: 'welcome' }));
    socket.onMessage((payload) => {
      const message = JSON.parse(payload.toString());
      if (message.command === 'subscribe') {
        socket.send(JSON.stringify({ type: 'confirm_subscription', identifier: message.identifier }));
      }
    });
  });
  await page.route('**/api/v1/auth/me', (route) => json(route, { user: {
    id: 41, email: 'manager@example.test', name: 'Sloane Fixture', role: 'client', company_id: companyId,
    company_name: company.name, home_company_id: companyId, assigned_company_ids: [companyId],
  } }));
  await page.route('**/api/v1/companies', (route) => json(route, { companies: [company], current_company_id: companyId }));
  await page.route('**/api/v1/client/employee_intake_settings**', (route) => json(route, { data: { enabled: false } }));
  await page.route('**/api/v1/client/verification_items**', (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith('/respond')) {
      expect(route.request().postDataJSON()).toEqual({ note: 'Direct deposit is correct.' });
      hasReturnedItem = false;
      return json(route, { data: { ...returned, status: 'pending_verification' } });
    }
    expect(url.searchParams.get('status')).toBe('returned_to_client');
    const data = hasReturnedItem ? [returned] : [];
    return json(route, { data, meta: { current_page: 1, total_pages: 1, total_count: data.length, per_page: 200 } });
  });
  await page.route('**/api/v1/client/employees**', (route) => {
    const url = new URL(route.request().url());
    const method = route.request().method();
    if (url.pathname.endsWith('/terminate')) {
      const { termination } = route.request().postDataJSON();
      expect(termination).toMatchObject({ last_worked_on: '2026-11-11', effective_date: '2026-11-11',
        reason_category: 'end_of_contract', final_pay_notes: 'Review unused leave.' });
      worker.status = 'terminated';
      worker.termination_date = termination.effective_date;
      return json(route, { data: worker, message: 'Termination saved.', warnings: ['Cornerstone will review the earlier payroll.'] });
    }
    if (url.pathname.endsWith('/rehire')) {
      expect(route.request().postDataJSON()).toEqual({ rehire: { effective_date: today } });
      worker.status = 'active';
      worker.termination_date = null;
      return json(route, { data: worker, message: 'Rehire saved.' });
    }
    if (method === 'POST') {
      const { employee } = route.request().postDataJSON();
      expect(employee).toMatchObject({ first_name: 'Rowan', last_name: 'Fixture', employment_type: 'hourly' });
      expect(employee).not.toHaveProperty('ssn');
      expect(employee).not.toHaveProperty('w4_effective_on');
      expect(employee).not.toHaveProperty('payment_delivery_method');
      created = true;
      return json(route, { data: worker, message: 'Saved as Incomplete.' });
    }
    if (method === 'PATCH') {
      const { employee } = route.request().postDataJSON();
      expect(employee).toMatchObject({
        payment_delivery_method: 'direct_deposit', ssn: '900-11-2233', ssn_confirmation: '900-11-2233',
        pay_rate: 18.25, date_of_birth: '1990-01-05', hire_date: '2026-11-07',
        address_line1: '100 Synthetic Lane', city: 'Hagåtña', state: 'GU', zip: '96910',
        w4_election_received: true, w4_effective_on: '2026-12-04', w4_signed_on: '2026-11-07',
      });
      worker.payment_delivery_method = 'direct_deposit';
      worker.pay_rate = 18.25;
      worker.readiness = readiness(true);
      hasReturnedItem = true;
      return json(route, { data: worker, message: 'Saved. Cornerstone will verify the update.' });
    }
    if (url.pathname.endsWith('/501')) return json(route, { data: worker });
    const data = created && (url.searchParams.get('needs_attention') !== 'true' || hasReturnedItem) ? [worker] : [];
    return json(route, { data, meta: { current_page: 1, total_pages: 1, total_count: data.length, per_page: 500 } });
  });
}

async function noPageOverflow(page: Page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(page.viewportSize()!.width);
}

for (const width of [390, 1280]) {
  test(`client manager completes employee lifecycle at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 });
    const errors: string[] = [];
    page.on('pageerror', (error) => errors.push(error.message));
    page.on('console', (message) => { if (message.type() === 'error') errors.push(message.text()); });
    await fixture(page);
    await page.goto(employeesPath);

    await page.getByRole('button', { name: 'Add Employee' }).first().click();
    const firstName = page.getByLabel('First Name');
    await firstName.fill('Rowan');
    await page.getByLabel('Last Name').fill('Fixture');
    if (width === 390) {
      expect(await firstName.evaluate((node) => getComputedStyle(node).fontSize)).toBe('16px');
      expect((await page.getByRole('button', { name: 'Save employee' }).boundingBox())?.height).toBeGreaterThanOrEqual(44);
    }
    await noPageOverflow(page);
    await page.getByRole('button', { name: 'Save employee' }).click();

    await expect(page.getByRole('heading', { name: 'Ready to pay' })).toBeVisible();
    await expect(page.getByText(/Incomplete — can’t be paid yet/)).toBeVisible();
    await page.getByRole('link', { name: 'Complete setup' }).click();
    await expect(page.locator('#employee-personal')).toBeFocused();
    await page.locator('[name="ssn"]').fill('900112233');
    await page.getByLabel(/Re-enter Social Security Number/).fill('900112233');
    await expect(page.locator('[name="ssn"]')).toHaveAttribute('type', 'password');
    await expect(page.getByLabel(/Re-enter Social Security Number/)).toHaveAttribute('type', 'password');
    await page.getByLabel('Date of Birth').fill('1990-01-05');
    await page.getByLabel('Hire Date').fill('2026-11-07');
    await page.getByRole('textbox', { name: /^Hourly Rate/ }).fill('18.25');
    await page.getByLabel('Address Line 1').fill('100 Synthetic Lane');
    await page.getByLabel('City', { exact: true }).fill('Hagåtña');
    await page.getByLabel('State', { exact: true }).fill('GU');
    await page.getByLabel('ZIP Code').fill('96910');
    await page.getByLabel('Record a received W-4').check();
    await page.getByLabel(/Signed date on source W-4/).fill('2026-11-07');
    await page.getByLabel('How this employee is paid').selectOption('direct_deposit');
    await expect(page.getByText(/confirm bank setup before payday/)).toBeVisible();
    const electionDate = page.getByLabel(/^Effective date/);
    await electionDate.fill('');
    await page.getByRole('button', { name: 'Save employee' }).click();
    await expect(page.getByText('Enter the date this W-4 became effective')).toBeVisible();
    await expect(electionDate).toBeFocused();
    await electionDate.fill('2026-12-04');
    await page.getByRole('button', { name: 'Save employee' }).click();
    await expect(page.getByRole('heading', { name: 'Rowan Fixture' })).toBeVisible();
    await expect(page.getByText(/Withholding as of Dec 4, 2026/)).toBeVisible();
    await expect(page.getByText(/Incomplete —/)).toHaveCount(0);
    await noPageOverflow(page);

    await page.getByRole('link', { name: 'Back', exact: true }).click();
    await page.getByRole('button', { name: 'Show employees' }).click();
    await expect(page.getByRole('combobox', { name: 'Cornerstone review' })).toHaveValue('true');
    await page.getByRole('button', { name: 'Rowan Fixture' }).click();
    await expect(page.getByText(staffNote)).toBeVisible();
    await page.getByRole('button', { name: 'Reply to Cornerstone' }).click();
    await page.getByRole('textbox', { name: 'Reply to Cornerstone' }).fill('Direct deposit is correct.');
    await page.getByRole('button', { name: 'Send reply' }).click();
    await expect(page.getByText('Response sent to Cornerstone for review.')).toBeVisible();
    await expect(page.getByText(staffNote)).toHaveCount(0);

    await page.getByRole('button', { name: 'Terminate', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'Terminate Rowan Fixture' });
    const terminationDate = dialog.getByLabel('Termination date');
    const lastWorked = dialog.getByLabel('Last day worked');
    await expect(terminationDate).toHaveAttribute('max', today);
    await terminationDate.fill('2026-11-11');
    await expect(lastWorked).toHaveValue('2026-11-11');
    await dialog.getByLabel('Reason').selectOption('end_of_contract');
    await lastWorked.fill('2026-11-12');
    await expect(dialog.getByText('The termination date must be on or after the last day worked.')).toBeVisible();
    await expect(dialog.getByRole('button', { name: 'Terminate', exact: true })).toBeDisabled();
    await lastWorked.fill('2026-11-11');
    await dialog.getByLabel(/Final pay and unused PTO/).fill('Review unused leave.');
    await expect(dialog.getByText(/approve the updated payroll again/)).toBeVisible();
    await expect(dialog.getByText(/already finalized/)).toBeVisible();
    expect(await dialog.evaluate((node) => node.scrollWidth)).toBeLessThanOrEqual(await dialog.evaluate((node) => node.clientWidth));
    await dialog.getByRole('button', { name: 'Terminate', exact: true }).click();
    await expect(page.getByText('Cornerstone will review the earlier payroll.')).toBeVisible();
    await expect(page.locator('[tabindex="-1"]').filter({ has: page.getByText('Termination saved.', { exact: true }) })).toBeFocused();

    await page.getByRole('button', { name: 'Rehire', exact: true }).click();
    const rehire = page.getByRole('dialog', { name: 'Rehire Rowan Fixture' });
    await expect(rehire.getByRole('heading', { name: 'Ready to pay after rehire' })).toBeVisible();
    await rehire.getByRole('button', { name: 'Rehire', exact: true }).click();
    await expect(page.getByText('Rehire saved.')).toBeVisible();
    expect(errors).toEqual([]);
  });
}
