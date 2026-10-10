import { expect, request, test, type APIRequestContext, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

interface Scenario { period_id: number; item_id: number; employee_id: number; loan_id?: number }
interface Fixture {
  company_id: number;
  accountant_email: string;
  desktop: Scenario;
  mobile: Scenario;
  reopen: Scenario;
  approved_refresh: Scenario;
  delivered: Scenario;
  multirate: Scenario;
  unavailable: Scenario;
  unselected_employee_id: number;
}
interface Item { employee_id: number; hours_worked: string; overtime_hours: string; gross_pay: string; withholding_tax: string; net_pay: string; loan_payment: string; voided: boolean }
interface Period { id: number; status: string; correction_status: string | null; source_pay_period_id: number | null; payroll_items: Item[] }

if (process.env.E2E_REFRESH_LANE !== 'true') throw new Error('Payroll refresh tests require the isolated refresh lane.');
const fixture = JSON.parse(readFileSync(process.env.E2E_FIXTURE_PATH || resolve('.e2e-fixtures/payroll-refresh.json'), 'utf8')) as Fixture;
const apiBase = process.env.E2E_API_URL || `http://127.0.0.1:${process.env.E2E_API_PORT || '4317'}/api/v1/`;

test.describe('Synthetic payroll refresh and unpaid correction', () => {
  test.describe.configure({ mode: 'serial' });
  test.setTimeout(120_000);
  let api: APIRequestContext;

  test.beforeAll(async () => {
    api = await request.newContext({ baseURL: apiBase, extraHTTPHeaders: {
      'X-E2E-User-Email': fixture.accountant_email, 'X-Company-Id': String(fixture.company_id),
    } });
  });
  test.afterAll(async () => { await api.dispose(); });

  async function period(id: number): Promise<Period> {
    const response = await api.get(`admin/pay_periods/${id}`);
    expect(response.ok()).toBeTruthy();
    return (await response.json()).pay_period as Period;
  }
  async function loan(id: number): Promise<{ current_balance: string; transactions: { transaction_type: string; amount: string }[] }> {
    const response = await api.get(`admin/employee_loans/${id}`);
    expect(response.ok()).toBeTruthy();
    return (await response.json()).loan;
  }
  async function open(page: Page, id: number): Promise<void> {
    await page.goto(`/companies/${fixture.company_id}/pay-runs/${id}/work`);
    await expect(page.getByText('Synthetic Payroll Refresh QA', { exact: true }).filter({ visible: true }).first()).toBeVisible();
  }
  async function chooseLoan(page: Page, name: string): Promise<void> {
    await page.getByRole('combobox', { name: `${name} repayment choice`, exact: true }).filter({ visible: true }).selectOption('override');
    await page.getByLabel(`${name} repayment amount`, { exact: true }).filter({ visible: true }).fill('300');
    await expect(page.getByRole('button', { name: 'Refresh current setup', exact: true })).toBeDisabled();
  }
  async function calculate(page: Page, id: number): Promise<void> {
    await page.getByRole('button', { name: /^(Calculate Payroll|Recalculate)$/ }).filter({ visible: true }).click();
    await expect.poll(async () => (await period(id)).status, { timeout: 30_000 }).toBe('calculated');
    const saved = await period(id);
    expect(saved.payroll_items).toHaveLength(1);
    expect(Number(saved.payroll_items[0].gross_pay)).toBe(1620.8);
    expect(Number(saved.payroll_items[0].withholding_tax)).toBe(103.66);
    expect(Number(saved.payroll_items[0].loan_payment)).toBe(300);
    expect(Number(saved.payroll_items[0].net_pay)).toBe(1093.15);
    expect(Number(saved.payroll_items[0].hours_worked)).toBe(80.3);
    expect(Number(saved.payroll_items[0].overtime_hours)).toBe(14);
    expect(saved.payroll_items[0].employee_id).not.toBe(fixture.unselected_employee_id);
  }
  async function finalize(page: Page, id: number, loanId: number): Promise<void> {
    await page.getByRole('button', { name: 'Approve', exact: true }).filter({ visible: true }).click();
    await expect.poll(async () => (await period(id)).status, { timeout: 30_000 }).toBe('approved');
    await page.getByRole('button', { name: 'Commit & Finalize', exact: true }).filter({ visible: true }).click();
    const commitDialog = page.getByRole('dialog', { name: 'Commit and finalize payroll?', exact: true });
    await expect(commitDialog).toBeVisible();
    await expect(commitDialog.getByText('Synthetic Payroll Refresh QA', { exact: true })).toBeVisible();
    await expect(commitDialog.getByText(`#${id}`, { exact: true })).toBeVisible();
    await commitDialog.getByRole('button', { name: 'Confirm commit', exact: true }).click();
    await expect(commitDialog).not.toBeVisible();
    await expect.poll(async () => (await period(id)).status, { timeout: 30_000 }).toBe('committed');
    const savedLoan = await loan(loanId);
    expect(Number(savedLoan.current_balance)).toBe(2959.97);
    const payments = savedLoan.transactions.filter(row => row.transaction_type === 'payment');
    expect(payments).toHaveLength(1);
    expect(Number(payments[0].amount)).toBe(300);
    const checks = await api.get(`admin/non_employee_checks?pay_period_id=${id}`);
    expect(checks.ok()).toBeTruthy();
    const body = await checks.json();
    const active = (body.non_employee_checks || body.checks || []).filter((row: { voided: boolean }) => !row.voided);
    expect(active).toHaveLength(1);
    expect(Number(active[0].amount)).toBe(103.66);
  }

  test('accountant applies a named loan on a special run without expanding the roster', async ({ page }) => {
    await open(page, fixture.desktop.period_id);
    await chooseLoan(page, 'QA Desktop Loan');
    await calculate(page, fixture.desktop.period_id);
    await finalize(page, fixture.desktop.period_id, fixture.desktop.loan_id!);
  });

  test('one period void retires employee and FIT checks and restores the tracked balance', async ({ page }) => {
    await open(page, fixture.desktop.period_id);
    await page.getByRole('button', { name: 'Void This Pay Period', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: /Void Pay Period/ });
    await dialog.getByLabel(/Reason for voiding/).fill('Synthetic QA replaces an unissued payroll.');
    await dialog.getByRole('checkbox', { name: /I confirm all active payments/ }).check();
    await dialog.getByLabel(/Type VOID/).fill('VOID');
    await dialog.getByRole('button', { name: 'Void Pay Period', exact: true }).click();
    await expect.poll(async () => (await period(fixture.desktop.period_id)).correction_status, { timeout: 30_000 }).toBe('voided');
    expect((await period(fixture.desktop.period_id)).payroll_items.every(item => item.voided)).toBeTruthy();
    expect(Number((await loan(fixture.desktop.loan_id!)).current_balance)).toBe(3259.97);
    const response = await api.get(`admin/non_employee_checks?pay_period_id=${fixture.desktop.period_id}`);
    const checks = (await response.json()).non_employee_checks;
    expect(checks.every((row: { voided: boolean }) => row.voided)).toBeTruthy();
  });

  test('phone employee card supports linked repayment through commit', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await open(page, fixture.mobile.period_id);
    await chooseLoan(page, 'QA Mobile Loan');
    await calculate(page, fixture.mobile.period_id);
    await finalize(page, fixture.mobile.period_id, fixture.mobile.loan_id!);
  });

  test('reopening unpaid payroll creates a linked draft and preserves entered wages', async ({ page }) => {
    await open(page, fixture.reopen.period_id);
    await page.getByRole('button', { name: 'Reopen unpaid payroll', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'Reopen unpaid payroll', exact: true });
    await dialog.getByLabel('Reason for reopening', { exact: true }).fill('Synthetic QA adds the saved loan to unissued pay.');
    await dialog.getByRole('checkbox', { name: /I confirm all active payments/ }).check();
    await dialog.getByRole('button', { name: 'Reopen and create draft', exact: true }).click();
    await expect(page).not.toHaveURL(new RegExp(`/pay-runs/${fixture.reopen.period_id}/`));
    await expect(page).toHaveURL(/\/pay-runs\/\d+\/work/);
    const id = Number(page.url().match(/\/pay-runs\/(\d+)\//)![1]);
    const draft = await period(id);
    expect(draft.status).toBe('draft');
    expect(draft.source_pay_period_id).toBe(fixture.reopen.period_id);
    expect(draft.payroll_items).toHaveLength(1);
    expect(Number(draft.payroll_items[0].hours_worked)).toBe(80.3);
    expect(Number(draft.payroll_items[0].overtime_hours)).toBe(14);
    await chooseLoan(page, 'QA Reopen Loan');
    await calculate(page, id);
    await finalize(page, id, fixture.reopen.loan_id!);
    expect((await period(fixture.reopen.period_id)).correction_status).toBe('voided');
  });

  test('refreshing current setup withdraws approval and applies the new scheduled loan once', async ({ page }) => {
    await open(page, fixture.approved_refresh.period_id);
    await page.getByRole('button', { name: 'Refresh current setup', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'Refresh current setup', exact: true });
    await dialog.getByRole('checkbox', { name: 'Include recurring employee setup', exact: true }).check();
    await dialog.getByRole('button', { name: 'Refresh and recalculate', exact: true }).click();
    await expect.poll(async () => (await period(fixture.approved_refresh.period_id)).status, { timeout: 30_000 }).toBe('calculated');
    const refreshed = await period(fixture.approved_refresh.period_id);
    expect(refreshed.payroll_items).toHaveLength(1);
    expect(Number(refreshed.payroll_items[0].hours_worked)).toBe(80.3);
    expect(Number(refreshed.payroll_items[0].loan_payment)).toBe(300);
    expect(Number(refreshed.payroll_items[0].net_pay)).toBe(1093.15);
    expect(Number((await loan(fixture.approved_refresh.loan_id!)).current_balance)).toBe(3259.97);
    await finalize(page, fixture.approved_refresh.period_id, fixture.approved_refresh.loan_id!);
  });

  test('copied multi-rate payroll keeps original rates even after one rate is deactivated', async ({ page }) => {
    await open(page, fixture.multirate.period_id);
    await page.getByRole('button', { name: 'Reopen unpaid payroll', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'Reopen unpaid payroll', exact: true });
    await dialog.getByLabel('Reason for reopening', { exact: true }).fill('Synthetic QA preserves captured multi-rate earnings.');
    await dialog.getByRole('checkbox', { name: /I confirm all active payments/ }).check();
    await dialog.getByRole('button', { name: 'Reopen and create draft', exact: true }).click();
    await expect(page).not.toHaveURL(new RegExp(`/pay-runs/${fixture.multirate.period_id}/`));
    const id = Number(page.url().match(/\/pay-runs\/(\d+)\//)![1]);
    await chooseLoan(page, 'QA Multi Rate Loan');
    await page.getByRole('button', { name: 'Calculate Payroll', exact: true }).filter({ visible: true }).click();
    await expect.poll(async () => (await period(id)).status, { timeout: 30_000 }).toBe('calculated');
    const saved = await period(id);
    expect(saved.payroll_items).toHaveLength(1);
    expect(Number(saved.payroll_items[0].gross_pay)).toBe(1280);
    expect(Number(saved.payroll_items[0].loan_payment)).toBe(300);
    expect(Number(saved.payroll_items[0].hours_worked)).toBe(80);
    expect(Number(saved.payroll_items[0].overtime_hours)).toBe(0);
    await page.getByRole('button', { name: 'Recalculate', exact: true }).filter({ visible: true }).click();
    await expect.poll(async () => Number((await period(id)).payroll_items[0].gross_pay), { timeout: 30_000 }).toBe(1280);
  });

  test('phone recovery clears an unavailable saved loan without losing entered hours', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await open(page, fixture.unavailable.period_id);
    await expect(page.getByRole('alert').filter({ visible: true })).toContainText('This saved repayment is no longer available');
    const choice = page.getByRole('combobox', { name: 'QA Unavailable Loan Loan repayment choice', exact: true }).filter({ visible: true });
    await choice.selectOption('default');
    await expect(page.getByRole('button', { name: 'Refresh current setup', exact: true })).toBeDisabled();
    await page.getByRole('button', { name: 'Calculate Payroll', exact: true }).filter({ visible: true }).click();
    await expect.poll(async () => (await period(fixture.unavailable.period_id)).status, { timeout: 30_000 }).toBe('calculated');
    const saved = await period(fixture.unavailable.period_id);
    expect(saved.payroll_items).toHaveLength(1);
    expect(Number(saved.payroll_items[0].hours_worked)).toBe(80.3);
    expect(Number(saved.payroll_items[0].overtime_hours)).toBe(14);
    expect(Number(saved.payroll_items[0].gross_pay)).toBe(1620.8);
    expect(Number(saved.payroll_items[0].loan_payment)).toBe(0);
    expect(Number(saved.payroll_items[0].net_pay)).toBe(1393.15);
    expect(Number((await loan(fixture.unavailable.loan_id!)).current_balance)).toBe(3259.97);
  });

  test('phone correction dialog blocks delivered payroll without changing its state', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await open(page, fixture.delivered.period_id);
    await page.getByRole('button', { name: 'Reopen unpaid payroll', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'Reopen unpaid payroll', exact: true });
    await expect(dialog.getByRole('alert')).toContainText(/issued|delivered|paid/i);
    await expect(dialog.getByRole('button', { name: 'Reopen and create draft', exact: true })).toBeDisabled();
    const bounds = await dialog.boundingBox();
    expect(bounds?.width).toBeLessThanOrEqual(390);
    expect((await period(fixture.delivered.period_id)).status).toBe('committed');
    expect((await period(fixture.delivered.period_id)).correction_status).toBeNull();
  });
});
