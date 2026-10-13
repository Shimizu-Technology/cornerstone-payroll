import { expect, request, test, type APIRequestContext, type Locator, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

interface Fixture {
  accountant_email: string;
  admin_email: string;
  companies: { aire: number; mosa: number };
  employees: Record<'recipient' | 'coworker' | 'admin_recipient' | 'chief' | 'inherited' | 'zero' | 'private_owner', number>;
  fields: Record<'fixed' | 'percentage' | 'manual' | 'contribution' | 'personal' | 'paused' | 'ended' | 'standalone', number>;
  assignments: Record<'inherited' | 'zero' | 'personal' | 'percentage' | 'manual' | 'contribution' | 'paused' | 'ended', number>;
  periods: Record<'history' | 'chief_history' | 'regular' | 'before_start' | 'special' | 'hospitality' | 'admin_regular', number>;
  loan_id: number;
}
interface Definition { id: number; name: string; owner_employee_id: number | null; default_amount: number | null; assigned_employee_count: number; active_assignment_count: number }
interface Assignment { id: number; employee_id: number; payroll_field_definition_id: number; amount: number | null; percentage: number | null; active: boolean; start_date: string | null; end_date: string | null; payroll_field: Definition }
interface Entry { label: string; amount: number | string; kind: string; tax_treatment: string; source: string; payroll_field_definition_id: number }
interface Item { id: number; employee_id: number; gross_pay: string; net_pay: string; withholding_tax: string; payroll_field_entries: Entry[]; payroll_adjustments: { label: string; amount: number }[] }
interface Period { id: number; status: string; payroll_items: Item[] }

if (process.env.E2E_PAY_ITEMS_LANE !== 'true') throw new Error('Pay-item workflow requires its isolated synthetic release lane.');
const fixture = JSON.parse(readFileSync(process.env.E2E_FIXTURE_PATH || resolve('.e2e-fixtures/pay-items.json'), 'utf8')) as Fixture;
const apiBase = process.env.E2E_API_URL || `http://127.0.0.1:${process.env.E2E_API_PORT || '4317'}/api/v1/`;
test.use({ extraHTTPHeaders: { 'X-E2E-User-Email': fixture.accountant_email } });

test.describe('Pay-item scope, accountant workflow, and saved payroll regression', () => {
  test.describe.configure({ mode: 'serial' });
  test.setTimeout(90_000);
  let aireApi: APIRequestContext;
  let mosaApi: APIRequestContext;
  let personal: Assignment;
  let shared: Assignment;
  let history: Period;
  let chiefHistory: Period;

  test.beforeAll(async () => {
    const context = (companyId: number) => request.newContext({ baseURL: apiBase, extraHTTPHeaders: {
      'X-E2E-User-Email': fixture.accountant_email, 'X-Company-Id': String(companyId),
    } });
    aireApi = await context(fixture.companies.aire);
    mosaApi = await context(fixture.companies.mosa);
    history = await period(mosaApi, fixture.periods.history);
    chiefHistory = await period(aireApi, fixture.periods.chief_history);
  });
  test.beforeEach(async ({ page }) => {
    // The payday fixtures are fixed; keep form defaults independent of the date
    // this release lane is rerun. Timers still run normally.
    await page.clock.setFixedTime(new Date('2026-10-13T00:00:00+10:00'));
  });
  test.afterAll(async () => { await aireApi.dispose(); await mosaApi.dispose(); });

  async function assignments(api: APIRequestContext, employeeId: number): Promise<Assignment[]> {
    const response = await api.get(`admin/employees/${employeeId}/payroll_fields?include_inactive=true`);
    expect(response.ok(), await response.text()).toBeTruthy();
    return (await response.json()).employee_payroll_fields;
  }
  async function period(api: APIRequestContext, id: number): Promise<Period> {
    const response = await api.get(`admin/pay_periods/${id}`);
    expect(response.ok(), await response.text()).toBeTruthy();
    return (await response.json()).pay_period;
  }
  async function openEmployee(page: Page, companyId: number, employeeId: number): Promise<void> {
    await page.goto(`/companies/${companyId}/employees/${employeeId}/edit`);
    await expect(page.locator('input[name="first_name"]')).toHaveValue('QA');
    await expect(page.getByRole('button', { name: 'Add addition', exact: true })).toBeVisible();
  }
  async function startAddition(page: Page): Promise<Locator> {
    await page.getByRole('button', { name: 'Add addition', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'Add addition', exact: true });
    await expect(dialog).toBeVisible();
    return dialog;
  }
  async function fillAddition(dialog: Locator, name: string, amount: string): Promise<void> {
    await dialog.getByLabel('Name', { exact: true }).fill(name);
    await dialog.getByLabel('Tax treatment', { exact: true }).selectOption('taxable_addition');
    await dialog.getByLabel('Amount type', { exact: true }).selectOption('fixed');
    await dialog.getByLabel(/^Amount(?! type)/).fill(amount);
  }
  async function saveAddition(page: Page, dialog: Locator): Promise<void> {
    await dialog.getByRole('button', { name: 'Save addition', exact: true }).click();
    await expect(dialog).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Add addition', exact: true })).toBeEnabled();
  }
  async function calculate(api: APIRequestContext, id: number): Promise<Period> {
    const response = await api.post(`admin/pay_periods/${id}/run_payroll`);
    expect(response.ok(), await response.text()).toBeTruthy();
    const saved = await period(api, id);
    expect(saved.status).toBe('calculated');
    return saved;
  }
  function item(saved: Period, employeeId: number): Item {
    const row = saved.payroll_items.find(candidate => candidate.employee_id === employeeId);
    expect(row).toBeDefined();
    return row!;
  }

  test('accountant discovers the local action and saves a private recurring $250 addition', async ({ page }) => {
    await openEmployee(page, fixture.companies.aire, fixture.employees.recipient);
    const dialog = await startAddition(page);
    await expect(dialog.getByRole('radio', { name: /^Only QA Allowance Recipient/ })).toBeChecked();
    await fillAddition(dialog, 'Assistant Chief Pilot QA', '250');
    await dialog.getByLabel(/^First payday/).fill('2026-10-13');
    await expect(dialog.getByLabel(/^Last payday/)).toHaveValue('');
    await expect(dialog.getByLabel(/Payee|Reference number/)).toHaveCount(0);
    await saveAddition(page, dialog);
    personal = (await assignments(aireApi, fixture.employees.recipient)).find(row => row.payroll_field.name === 'Assistant Chief Pilot QA')!;
    expect(personal.amount).toBe(250);
    expect(personal.start_date).toBe('2026-10-13');
    expect(personal.end_date).toBeNull();
    expect(personal.payroll_field.owner_employee_id).toBe(fixture.employees.recipient);
    const row = page.getByTestId(`pay-item-${personal.id}`);
    await expect(row).toContainText('Employee-specific');
    await page.reload();
    await expect(page.getByTestId(`pay-item-${personal.id}`)).toContainText('Assistant Chief Pilot QA');
    expect((await assignments(aireApi, fixture.employees.coworker))).toHaveLength(0);
  });

  test('admin uses the same accessible form on a 390px viewport', async ({ browser }) => {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, extraHTTPHeaders: { 'X-E2E-User-Email': fixture.admin_email } });
    try {
      const page = await context.newPage();
      await page.clock.setFixedTime(new Date('2026-10-13T00:00:00+10:00'));
      await openEmployee(page, fixture.companies.aire, fixture.employees.admin_recipient);
      const trigger = page.getByRole('button', { name: 'Add addition', exact: true });
      await trigger.focus();
      await page.keyboard.press('Enter');
      const dialog = page.getByRole('dialog', { name: 'Add addition', exact: true });
      await fillAddition(dialog, 'Admin allowance QA', '250');
      await dialog.getByLabel(/^First payday/).fill('2026-10-13');
      const bounds = await dialog.boundingBox();
      expect(bounds!.width).toBeLessThanOrEqual(390);
      expect(bounds!.x).toBeGreaterThanOrEqual(0);
      await dialog.getByRole('button', { name: 'Save addition', exact: true }).focus();
      await page.keyboard.press('Enter');
      await expect(dialog).toHaveCount(0);
      const saved = (await assignments(aireApi, fixture.employees.admin_recipient)).find(row => row.payroll_field.name === 'Admin allowance QA');
      expect(saved!.amount).toBe(250);
      await expect(page.getByTestId(`pay-item-${saved!.id}`)).toContainText('Employee-specific');
    } finally { await context.close(); }
  });

  test('accountant creates a reusable field and assigns it only to the current employee', async ({ page }) => {
    await openEmployee(page, fixture.companies.aire, fixture.employees.admin_recipient);
    const dialog = await startAddition(page);
    await fillAddition(dialog, 'Reusable aviation allowance QA', '75');
    await dialog.getByRole('radio', { name: /^Reusable for Synthetic Aviation QA/ }).check();
    await expect(dialog).toContainText(/assign|other employees/i);
    await saveAddition(page, dialog);
    shared = (await assignments(aireApi, fixture.employees.admin_recipient)).find(row => row.payroll_field.name === 'Reusable aviation allowance QA')!;
    expect(shared.payroll_field.owner_employee_id).toBeNull();
    expect(shared.payroll_field.assigned_employee_count).toBe(1);
    await expect(page.getByTestId(`pay-item-${shared.id}`)).toContainText('Client-wide');
    expect((await assignments(aireApi, fixture.employees.coworker))).toHaveLength(0);
  });

  test('accountant assigns an existing shared field without creating a duplicate definition', async ({ page }) => {
    const before = await aireApi.get('admin/payroll_fields');
    const beforeFields = (await before.json()).payroll_fields as Definition[];
    await openEmployee(page, fixture.companies.aire, fixture.employees.coworker);
    const dialog = await startAddition(page);
    await dialog.getByRole('radio', { name: 'Use existing client field', exact: true }).check();
    await dialog.getByLabel('Client field', { exact: true }).selectOption(String(shared.payroll_field_definition_id));
    await dialog.getByRole('radio', { name: 'Set employee amount', exact: true }).check();
    await dialog.getByLabel(/^Amount(?! type)/).fill('90');
    await saveAddition(page, dialog);
    const saved = await assignments(aireApi, fixture.employees.coworker);
    expect(saved).toHaveLength(1);
    expect(saved[0].payroll_field_definition_id).toBe(shared.payroll_field_definition_id);
    expect(saved[0].amount).toBe(90);
    const after = await aireApi.get('admin/payroll_fields');
    expect((await after.json()).payroll_fields).toHaveLength(beforeFields.length);
    await expect(page.getByTestId(`pay-item-${saved[0].id}`)).toContainText('Client-wide');
  });

  test('blank inheritance and an explicit $0 survive date and note edits', async ({ page }) => {
    for (const [employeeId, assignmentId, expected] of [
      [fixture.employees.inherited, fixture.assignments.inherited, null],
      [fixture.employees.zero, fixture.assignments.zero, 0],
    ] as const) {
      await openEmployee(page, fixture.companies.mosa, employeeId);
      if (employeeId === fixture.employees.inherited) {
        await expect(page.getByTestId(`pay-item-${fixture.assignments.ended}`)).toContainText('Ended 2026-09-30');
        await page.getByRole('checkbox', { name: /^Show stopped items/ }).check();
        await expect(page.getByTestId(`pay-item-${fixture.assignments.paused}`)).toContainText('Paused');
      }
      await page.getByTestId(`pay-item-${assignmentId}`).getByRole('button', { name: 'Edit', exact: true }).click();
      const dialog = page.getByRole('dialog', { name: 'Edit addition', exact: true });
      await dialog.getByLabel(/^First payday/).fill('2026-10-01');
      await dialog.locator('summary').filter({ hasText: 'More options' }).click();
      await dialog.getByLabel(/^Notes/).fill('Synthetic date-only edit preserves amount semantics.');
      await saveAddition(page, dialog);
      expect((await assignments(mosaApi, employeeId)).find(row => row.id === assignmentId)!.amount).toBe(expected);
    }
    await openEmployee(page, fixture.companies.mosa, fixture.employees.inherited);
    await page.getByTestId(`pay-item-${fixture.assignments.percentage}`).getByRole('button', { name: 'Edit', exact: true }).click();
    const percentageDialog = page.getByRole('dialog', { name: 'Edit deduction', exact: true });
    await percentageDialog.getByLabel(/^First payday/).fill('2026-10-01');
    await percentageDialog.locator('summary').filter({ hasText: 'More options' }).click();
    await percentageDialog.getByLabel(/^Notes/).fill('Synthetic percentage inheritance remains blank.');
    await percentageDialog.getByRole('button', { name: 'Save deduction', exact: true }).click();
    await expect(percentageDialog).toHaveCount(0);
    expect((await assignments(mosaApi, fixture.employees.inherited)).find(row => row.id === fixture.assignments.percentage)!.percentage).toBeNull();
  });

  test('regular payroll applies scoped additions once, honors dates, and retains the legacy chief allowance', async ({ page }) => {
    await page.goto(`/companies/${fixture.companies.aire}/pay-runs/${fixture.periods.regular}/work`);
    await page.getByRole('button', { name: /^(Calculate Payroll|Recalculate)$/ }).filter({ visible: true }).click();
    await expect.poll(async () => (await period(aireApi, fixture.periods.regular)).status).toBe('calculated');
    const saved = await period(aireApi, fixture.periods.regular);
    const recipient = item(saved, fixture.employees.recipient);
    const entries = recipient.payroll_field_entries.filter(entry => entry.payroll_field_definition_id === personal.payroll_field_definition_id);
    expect(entries).toHaveLength(1);
    expect(Number(entries[0].amount)).toBe(250);
    expect(entries[0].source).toBe('employee_default');
    expect(Number(recipient.gross_pay)).toBe(1250);
    expect(Number(recipient.withholding_tax)).toBe(0);
    expect(Number(item(saved, fixture.employees.coworker).gross_pay)).toBe(1090);
    expect(item(saved, fixture.employees.coworker).payroll_field_entries.some(entry => entry.payroll_field_definition_id === personal.payroll_field_definition_id)).toBe(false);
    const chief = item(saved, fixture.employees.chief);
    expect(chief.payroll_adjustments.filter(row => row.label === 'Chief Pilot')).toHaveLength(1);
    expect(Number(chief.payroll_adjustments.find(row => row.label === 'Chief Pilot')!.amount)).toBe(750);
    expect(Number(chief.gross_pay)).toBe(1950);
    const earlier = item(await calculate(aireApi, fixture.periods.before_start), fixture.employees.recipient);
    expect(Number(earlier.gross_pay)).toBe(1000);
    expect(earlier.payroll_field_entries).toHaveLength(0);
    const special = item(await calculate(aireApi, fixture.periods.special), fixture.employees.recipient);
    expect(Number(special.gross_pay)).toBe(1000);
    expect(special.payroll_field_entries).toHaveLength(0);
  });

  test('existing shared shapes preserve fixed, percentage, manual, contribution, loan, and historical snapshots', async () => {
    const saved = await calculate(mosaApi, fixture.periods.hospitality);
    const inherited = item(saved, fixture.employees.inherited);
    const entry = (id: number) => inherited.payroll_field_entries.find(row => row.payroll_field_definition_id === id);
    expect(Number(entry(fixture.fields.fixed)!.amount)).toBe(125);
    expect(Number(entry(fixture.fields.manual)!.amount)).toBe(35);
    expect(Number(entry(fixture.fields.percentage)!.amount)).toBe(27.2);
    expect(Number(entry(fixture.fields.contribution)!.amount)).toBe(50);
    expect(Number(entry(fixture.fields.standalone)!.amount)).toBe(40);
    expect(entry(fixture.fields.paused)).toBeUndefined();
    expect(entry(fixture.fields.ended)).toBeUndefined();
    expect(Number(inherited.gross_pay)).toBe(1360);
    const zero = item(saved, fixture.employees.zero);
    expect(Number(zero.gross_pay)).toBe(1200);
    const zeroEntry = zero.payroll_field_entries.find(row => row.payroll_field_definition_id === fixture.fields.fixed);
    expect(Number(zeroEntry?.amount || 0)).toBe(0);
    expect(Number(item(saved, fixture.employees.private_owner).gross_pay)).toBe(1280);
    expect(inherited.payroll_field_entries.some(row => row.payroll_field_definition_id === fixture.fields.personal)).toBe(false);
    const loanResponse = await mosaApi.get(`admin/employee_loans/${fixture.loan_id}`);
    expect(Number((await loanResponse.json()).loan.current_balance)).toBe(1000);
    expect(await period(mosaApi, fixture.periods.history)).toEqual(history);
    expect(await period(aireApi, fixture.periods.chief_history)).toEqual(chiefHistory);
  });

  test('server failure keeps values and a retry creates exactly one saved item', async ({ page }) => {
    await openEmployee(page, fixture.companies.aire, fixture.employees.admin_recipient);
    const path = `**/api/v1/admin/employees/${fixture.employees.admin_recipient}/payroll_fields/create_and_assign`;
    let first = true;
    await page.route(path, async route => {
      if (first) { first = false; await route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ error: 'Synthetic temporary failure. Please retry.' }) }); }
      else await route.continue();
    });
    const dialog = await startAddition(page);
    await fillAddition(dialog, 'Retry allowance QA', '11');
    await dialog.getByRole('button', { name: 'Save addition', exact: true }).click();
    await expect(dialog.getByRole('alert')).toContainText(/failure|retry/i);
    await expect(dialog.getByLabel('Name', { exact: true })).toHaveValue('Retry allowance QA');
    await expect(dialog.getByLabel(/^Amount(?! type)/)).toHaveValue('11');
    await saveAddition(page, dialog);
    expect((await assignments(aireApi, fixture.employees.admin_recipient)).filter(row => row.payroll_field.name === 'Retry allowance QA')).toHaveLength(1);
  });

  test('unfinished pay item blocks profile submit and survives reload until explicitly discarded', async ({ page }) => {
    await openEmployee(page, fixture.companies.aire, fixture.employees.recipient);
    const dialog = await startAddition(page);
    await fillAddition(dialog, 'Unfinished allowance QA', '19');
    await expect(page.getByRole('button', { name: 'Update Contractor', exact: true })).toBeDisabled();
    await page.reload();
    const restored = page.getByRole('dialog', { name: 'Add addition', exact: true });
    await expect(restored).toBeVisible();
    await expect(restored.getByLabel('Name', { exact: true })).toHaveValue('Unfinished allowance QA');
    await page.keyboard.press('Escape');
    const discard = page.getByRole('dialog', { name: /Discard/i });
    await expect(discard).toBeVisible();
    await discard.getByRole('button', { name: /Discard/i }).click();
    await expect(restored).toHaveCount(0);
    expect((await assignments(aireApi, fixture.employees.recipient)).some(row => row.payroll_field.name === 'Unfinished allowance QA')).toBe(false);
  });

  test('a delayed saved response cannot insert the old employee item into another client', async ({ page }) => {
    await openEmployee(page, fixture.companies.aire, fixture.employees.admin_recipient);
    let started!: () => void;
    let release!: () => void;
    const began = new Promise<void>(resolveStarted => { started = resolveStarted; });
    const released = new Promise<void>(resolveRelease => { release = resolveRelease; });
    const path = `/api/v1/admin/employees/${fixture.employees.admin_recipient}/payroll_fields/create_and_assign`;
    await page.route(`**${path}`, async route => {
      const response = await route.fetch();
      started();
      await released;
      await route.fulfill({ response });
    });
    const dialog = await startAddition(page);
    await fillAddition(dialog, 'Delayed scoped allowance QA', '17');
    await dialog.getByRole('button', { name: 'Save addition', exact: true }).click();
    await began;
    const destination = `/companies/${fixture.companies.mosa}/employees/${fixture.employees.private_owner}/edit`;
    await page.evaluate(pathname => { window.history.pushState({}, '', pathname); window.dispatchEvent(new PopStateEvent('popstate')); }, destination);
    await expect(page).toHaveURL(destination);
    await expect(page.locator('input[name="last_name"]')).toHaveValue('Private Owner');
    const delivered = page.waitForResponse(response => new URL(response.url()).pathname === path && response.request().method() === 'POST');
    release();
    expect((await delivered).ok()).toBeTruthy();
    await expect(page.getByText('Delayed scoped allowance QA', { exact: true })).toHaveCount(0);
    expect((await assignments(aireApi, fixture.employees.admin_recipient)).filter(row => row.payroll_field.name === 'Delayed scoped allowance QA')).toHaveLength(1);
    expect((await assignments(mosaApi, fixture.employees.private_owner)).some(row => row.payroll_field.name === 'Delayed scoped allowance QA')).toBe(false);
  });

  test('personal editing affects only that employee and preserves saved payroll history', async ({ page }) => {
    const before = await calculate(aireApi, fixture.periods.regular);
    await openEmployee(page, fixture.companies.aire, fixture.employees.recipient);
    await page.getByTestId(`pay-item-${personal.id}`).getByRole('button', { name: 'Edit', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'Edit addition', exact: true });
    await dialog.getByLabel('Name', { exact: true }).fill('Assistant Chief Pilot QA renamed');
    await dialog.getByLabel('Tax treatment', { exact: true }).selectOption('non_taxable_addition');
    await dialog.getByLabel(/^Amount(?! type)/).fill('260');
    await dialog.getByLabel(/^Last payday/).fill('2026-12-31');
    await saveAddition(page, dialog);
    const saved = (await assignments(aireApi, fixture.employees.recipient)).find(row => row.id === personal.id)!;
    expect(saved.amount).toBe(260);
    expect(saved.end_date).toBe('2026-12-31');
    expect(saved.payroll_field.name).toBe('Assistant Chief Pilot QA renamed');
    expect(saved.payroll_field.owner_employee_id).toBe(fixture.employees.recipient);
    const invalidated = await period(aireApi, fixture.periods.regular);
    expect(invalidated.status).toBe('draft');
    expect(invalidated.payroll_items).toEqual(before.payroll_items);
    expect((await period(aireApi, fixture.periods.before_start)).status).toBe('calculated');
    expect((await period(aireApi, fixture.periods.special)).status).toBe('calculated');
    expect(await period(aireApi, fixture.periods.chief_history)).toEqual(chiefHistory);
  });

  test('a future addition does not invalidate earlier or recurring-off payrolls', async ({ page }) => {
    const before = await calculate(aireApi, fixture.periods.regular);
    await openEmployee(page, fixture.companies.aire, fixture.employees.recipient);
    const dialog = await startAddition(page);
    await fillAddition(dialog, 'Future allowance QA', '10');
    await dialog.getByLabel(/^First payday/).fill('2026-11-01');
    await saveAddition(page, dialog);
    const future = (await assignments(aireApi, fixture.employees.recipient)).find(row => row.payroll_field.name === 'Future allowance QA')!;
    await expect(page.getByTestId(`pay-item-${future.id}`)).toContainText('Starts 2026-11-01');
    const unaffected = await period(aireApi, fixture.periods.regular);
    expect(unaffected.status).toBe('calculated');
    expect(unaffected.payroll_items).toEqual(before.payroll_items);
    expect((await period(aireApi, fixture.periods.before_start)).status).toBe('calculated');
    expect((await period(aireApi, fixture.periods.special)).status).toBe('calculated');
  });

  test('stopping and reactivating a schedule retains its identity and history', async ({ page }) => {
    await openEmployee(page, fixture.companies.mosa, fixture.employees.private_owner);
    const row = page.getByTestId(`pay-item-${fixture.assignments.personal}`);
    page.on('dialog', dialog => dialog.accept());
    await row.getByRole('button', { name: 'Stop', exact: true }).click();
    await expect(row.getByRole('button', { name: 'Reactivate', exact: true })).toBeVisible();
    expect((await assignments(mosaApi, fixture.employees.private_owner)).find(candidate => candidate.id === fixture.assignments.personal)!.active).toBe(false);
    await row.getByRole('button', { name: 'Reactivate', exact: true }).click();
    await expect(row.getByRole('button', { name: 'Stop', exact: true })).toBeVisible();
    const saved = (await assignments(mosaApi, fixture.employees.private_owner)).filter(candidate => candidate.id === fixture.assignments.personal);
    expect(saved).toHaveLength(1);
    expect(saved[0].active).toBe(true);
    expect(await period(mosaApi, fixture.periods.history)).toEqual(history);
  });

  test('accountant can open the shared library and sees client scope and assignment impact', async ({ page }) => {
    await page.goto(`/companies/${fixture.companies.mosa}/payroll-fields`);
    await expect(page.getByRole('heading', { name: 'Client-wide payroll fields', exact: true })).toBeVisible();
    await expect(page.getByText('Shared fixed allowance', { exact: true }).filter({ visible: true })).toBeVisible();
    await expect(page.getByText('Private allowance', { exact: true })).toHaveCount(0);
    const response = await mosaApi.get('admin/payroll_fields');
    expect(response.ok()).toBeTruthy();
    const fields = (await response.json()).payroll_fields as Definition[];
    const fixed = fields.find(row => row.id === fixture.fields.fixed)!;
    expect(fixed.assigned_employee_count).toBe(2);
    expect(fixed.active_assignment_count).toBe(2);
    expect(fields.every(row => row.owner_employee_id === null)).toBe(true);
    expect(await period(mosaApi, fixture.periods.history)).toEqual(history);
  });

  test('deduction and employer contribution actions save distinct items with the correct effect on pay', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await openEmployee(page, fixture.companies.aire, fixture.employees.admin_recipient);
    for (const [action, name, amount, save] of [
      ['Add deduction', 'Standalone personal deduction QA', '20', 'Save deduction'],
      ['Add employer contribution', 'Personal employer benefit QA', '40', 'Save contribution'],
    ]) {
      await page.getByRole('button', { name: action, exact: true }).click();
      const dialog = page.getByRole('dialog', { name: action, exact: true });
      await dialog.getByLabel('Name', { exact: true }).fill(name);
      await dialog.getByLabel(/^Amount(?! type)/).fill(amount);
      await dialog.getByRole('button', { name: save, exact: true }).click();
      await expect(dialog).toHaveCount(0);
      const saved = (await assignments(aireApi, fixture.employees.admin_recipient)).find(row => row.payroll_field.name === name)!;
      expect(saved.amount).toBe(Number(amount));
      await expect(page.getByTestId(`pay-item-${saved.id}`)).toContainText('Employee-specific');
    }
    const saved = item(await calculate(aireApi, fixture.periods.admin_regular), fixture.employees.admin_recipient);
    const deduction = saved.payroll_field_entries.find(row => row.label === 'Standalone personal deduction QA')!;
    const contribution = saved.payroll_field_entries.find(row => row.label === 'Personal employer benefit QA')!;
    expect(deduction.kind).toBe('deduction');
    expect(deduction.tax_treatment).toBe('post_tax_deduction');
    expect(Number(deduction.amount)).toBe(20);
    expect(contribution.kind).toBe('employer_contribution');
    expect(Number(contribution.amount)).toBe(40);
    const additions = saved.payroll_field_entries.filter(row => row.kind === 'addition').reduce((sum, row) => sum + Number(row.amount), 0);
    expect(Number(saved.gross_pay)).toBe(1000 + additions);
    expect(Number(saved.net_pay)).toBe(Number(saved.gross_pay) - 20);
  });

  test('shared default editing shows impact, requires recalculation, and preserves explicit zero and committed history', async ({ page }) => {
    const before = await calculate(mosaApi, fixture.periods.hospitality);
    await page.goto(`/companies/${fixture.companies.mosa}/payroll-fields`);
    const row = page.getByTestId(`shared-field-${fixture.fields.fixed}`);
    await expect(row).toContainText(/Used by 2 people/);
    await row.getByRole('button', { name: 'Edit', exact: true }).click();
    await expect(page.getByLabel('Name', { exact: true })).toHaveValue('Shared fixed allowance');
    await page.getByLabel('Default amount', { exact: true }).fill('126');
    await page.getByRole('button', { name: 'Save changes', exact: true }).click();
    const review = page.getByRole('dialog', { name: 'Review shared field changes', exact: true });
    await expect(review).toBeVisible();
    await expect(review).toContainText(/2 people/);
    await expect(review).toContainText(/recalculat/i);
    await review.getByRole('button', { name: 'Save changes', exact: true }).click();
    await expect(review).toHaveCount(0);
    const response = await mosaApi.get(`admin/payroll_fields/${fixture.fields.fixed}`);
    const definition = (await response.json()).payroll_field as Definition;
    expect(definition.default_amount).toBe(126);
    expect(definition.owner_employee_id).toBeNull();
    expect(definition.assigned_employee_count).toBe(2);
    expect(definition.active_assignment_count).toBe(2);
    const invalidated = await period(mosaApi, fixture.periods.hospitality);
    expect(invalidated.status).toBe('draft');
    expect(invalidated.payroll_items).toEqual(before.payroll_items);
    expect(await period(mosaApi, fixture.periods.history)).toEqual(history);
    const recalculated = await calculate(mosaApi, fixture.periods.hospitality);
    const inherited = item(recalculated, fixture.employees.inherited);
    const fixed = inherited.payroll_field_entries.find(entry => entry.payroll_field_definition_id === fixture.fields.fixed)!;
    expect(Number(fixed.amount)).toBe(126);
    expect(fixed.label).toBe('Shared fixed allowance');
    expect(fixed.tax_treatment).toBe('taxable_addition');
    expect(fixed.source).toBe('employee_default');
    expect(Number(inherited.gross_pay)).toBe(1361);
    const explicitZero = item(recalculated, fixture.employees.zero);
    expect(Number(explicitZero.gross_pay)).toBe(1200);
    expect(Number(explicitZero.payroll_field_entries.find(entry => entry.payroll_field_definition_id === fixture.fields.fixed)?.amount || 0)).toBe(0);
    expect((await assignments(mosaApi, fixture.employees.inherited)).find(assignment => assignment.id === fixture.assignments.inherited)!.amount).toBeNull();
    expect((await assignments(mosaApi, fixture.employees.zero)).find(assignment => assignment.id === fixture.assignments.zero)!.amount).toBe(0);
  });

  test('accountant creates, edits, archives, and reactivates a reusable field without assigning it to anyone', async ({ page }) => {
    await page.goto(`/companies/${fixture.companies.mosa}/payroll-fields`);
    await page.getByLabel('Name', { exact: true }).fill('Library reusable allowance QA');
    await page.getByLabel('Type', { exact: true }).selectOption('addition');
    await page.getByLabel('Tax treatment', { exact: true }).selectOption('taxable_addition');
    await page.getByLabel('Amount type', { exact: true }).selectOption('fixed');
    await page.getByLabel('Default amount', { exact: true }).fill('30');
    await page.getByRole('button', { name: 'Create field', exact: true }).click();
    const response = await mosaApi.get('admin/payroll_fields');
    const field = ((await response.json()).payroll_fields as Definition[]).find(definition => definition.name === 'Library reusable allowance QA')!;
    expect(field.owner_employee_id).toBeNull();
    expect(field.assigned_employee_count).toBe(0);
    const row = page.getByTestId(`shared-field-${field.id}`);
    await expect(row).toContainText('Client-wide');
    await expect(row).toContainText('Used by 0 people');
    await row.getByRole('button', { name: 'Edit', exact: true }).click();
    await page.getByLabel('Name', { exact: true }).fill('Library reimbursement QA');
    await page.getByLabel('Tax treatment', { exact: true }).selectOption('non_taxable_addition');
    await page.getByRole('button', { name: 'Save changes', exact: true }).click();
    // Fields used by nobody can save without an impact confirmation.
    const confirmation = page.getByRole('dialog', { name: 'Review shared field changes', exact: true });
    if (await confirmation.isVisible()) await confirmation.getByRole('button', { name: 'Save changes', exact: true }).click();
    await expect(row).toContainText('Library reimbursement QA');
    await row.getByRole('button', { name: 'Archive', exact: true }).click();
    const archive = page.getByRole('dialog', { name: 'Review shared field changes', exact: true });
    await archive.getByRole('button', { name: 'Archive field', exact: true }).click();
    await expect(archive).toHaveCount(0);
    await expect(row).toContainText('Archived');
    await row.getByRole('button', { name: 'Reactivate', exact: true }).click();
    const reactivate = page.getByRole('dialog', { name: 'Review shared field changes', exact: true });
    await reactivate.getByRole('button', { name: 'Reactivate field', exact: true }).click();
    await expect(reactivate).toHaveCount(0);
    await expect(row).toContainText('Active');
    for (const employeeId of [fixture.employees.inherited, fixture.employees.zero, fixture.employees.private_owner]) {
      expect((await assignments(mosaApi, employeeId)).some(assignment => assignment.payroll_field_definition_id === field.id)).toBe(false);
    }
    expect(await period(mosaApi, fixture.periods.history)).toEqual(history);
  });

  test('optional legacy conversion atomically replaces the chief allowance and recalculates it exactly once', async ({ page }) => {
    await openEmployee(page, fixture.companies.aire, fixture.employees.chief);
    const additions = page.getByRole('region', { name: 'Additions', exact: true });
    await expect(additions).toContainText('Chief Pilot');
    await expect(additions).toContainText('Existing recurring item');
    await additions.getByRole('button', { name: 'Update setup', exact: true }).click();
    const heading = page.getByRole('heading', { name: 'Update recurring item setup', exact: true });
    const converter = heading.locator('ancestor::div[contains(@class, "rounded-2xl")][1]');
    await expect(converter.getByPlaceholder('Auto loan, 401(k), phone allowance')).toHaveValue('Chief Pilot');
    await converter.getByRole('combobox').filter({ has: page.locator('option[value="other"]') }).selectOption('other');
    await converter.getByLabel(/^First payday/).fill('2026-10-13');
    await converter.getByRole('button', { name: 'Save setup', exact: true }).click();
    await expect(heading).toHaveCount(0);
    const chiefAssignments = await assignments(aireApi, fixture.employees.chief);
    expect(chiefAssignments.filter(assignment => assignment.payroll_field.name === 'Chief Pilot')).toHaveLength(1);
    const replacement = chiefAssignments.find(assignment => assignment.payroll_field.name === 'Chief Pilot')!;
    expect(replacement.amount).toBe(750);
    expect(replacement.payroll_field.owner_employee_id).toBe(fixture.employees.chief);
    const employee = await aireApi.get(`admin/employees/${fixture.employees.chief}`);
    expect((await employee.json()).data.default_payroll_adjustments).toEqual([]);
    await page.reload();
    await expect(page.getByTestId(`pay-item-${replacement.id}`)).toContainText('Chief Pilot');
    expect(await period(aireApi, fixture.periods.chief_history)).toEqual(chiefHistory);
    const saved = await calculate(aireApi, fixture.periods.regular);
    const chief = item(saved, fixture.employees.chief);
    expect(Number(chief.gross_pay)).toBe(1950);
    expect(chief.payroll_adjustments.some(adjustment => adjustment.label === 'Chief Pilot')).toBe(false);
    const entries = chief.payroll_field_entries.filter(entry => entry.payroll_field_definition_id === replacement.payroll_field_definition_id);
    expect(entries).toHaveLength(1);
    expect(Number(entries[0].amount)).toBe(750);
    expect(entries[0].source).toBe('employee_default');
    expect(await period(aireApi, fixture.periods.chief_history)).toEqual(chiefHistory);
  });
});
