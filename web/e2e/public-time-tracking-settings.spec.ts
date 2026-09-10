import { expect, test, type Page } from '@playwright/test';

async function mockWorkspace(page: Page, options: { sources?: string[]; status?: string; linked?: boolean; voided?: boolean; secondClient?: boolean } = {}) {
  const requests: string[] = [];
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  page.on('console', (message) => { if (message.type() === 'error' && /Route render failed/.test(message.text())) errors.push(message.text()); });
  const source = { id: 7, company_id: 1, name: 'AIRE time clock', source_type: 'aire_services', base_url: 'https://example.test', shared_secret_configured: true, active: options.sources?.includes('aire_services') || false, last_synced_at: null };
  const company = { id: 1, name: 'Review Client', active: true, payroll_environment: 'live', active_employees: 0, total_employees: 0, pay_frequency: 'biweekly' };
  const companies = options.secondClient ? [company, { ...company, id: 2, name: 'Second Client' }] : [company];
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    requests.push(`${route.request().method()} ${path}`);
    let body: unknown = { data: [], meta: { total_pages: 1 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, email: 'review@example.test', name: 'Review Admin', role: 'admin', organization_id: 1, company_id: 1, assigned_company_ids: companies.map((item) => item.id) } };
    else if (path.endsWith('/companies')) body = { companies, can_manage_clients: true, can_switch_company: !!options.secondClient, current_company_id: 1 };
    else if (path.endsWith('/pay_periods/71')) body = { pay_period: {
      id: 71, company_id: 1, status: options.status || 'committed', correction_status: options.voided ? 'voided' : null,
      start_date: '2026-09-01', end_date: '2026-09-15', pay_date: '2026-09-18', run_purpose: 'regular', includes_base_salary: true,
      payroll_items: [], payroll_intake_source_types: [], employee_count: 0, total_gross: 0, total_net: 0,
      time_tracking: { active_source_types: options.sources || [], linked_aire_records: options.linked ? [{
        id: 81, source_name: 'Saved AIRE source', source_active: false, external_batch_id: 'AIRE-REVIEW-81',
        external_batch_checksum: 'a'.repeat(64), contract_version: '2.0', source_cutoff_at: '2026-09-15T12:00:00Z',
        applied_at: '2026-09-16T12:00:00Z', source_processing_status: 'committed',
        reconciliation_exceptions: [{ employee_name: 'Saved Employee', aire_regular_hours: '80.05', cornerstone_regular_hours: '80.00', aire_overtime_hours: '0', cornerstone_overtime_hours: '0', total_difference_hours: '0.05' }],
      }] : [] },
    } };
    else if (path.endsWith('/payroll_field_inputs')) body = { payroll_field_inputs: { fields: [], assignments: [] } };
    else if (path.endsWith('/supplemental_pay_periods')) body = { supplemental_pay_periods: [] };
    else if (path.endsWith('/checks')) body = { checks: [], meta: { total: 0 } };
    else if (path.endsWith('/timecards')) body = [];
    else if (path.endsWith('/non_employee_checks')) body = { non_employee_checks: [], meta: {} };
    else if (path.endsWith('/comparison')) return route.fulfill({ status: 422, contentType: 'application/json', body: JSON.stringify({ error: 'No prior payroll in this fixture.' }) });
    else if (path.endsWith('/time_tracking_sources')) body = { time_tracking_sources: route.request().headers()['x-company-id'] === '2'
      ? [{ ...source, id: 8, company_id: 2, name: 'Second client source' }] : [source] };
    else if (path.endsWith('/time_tracking_sources/7') && route.request().method() === 'PATCH') {
      source.active = route.request().postDataJSON().time_tracking_source.active;
      body = { time_tracking_source: source };
    }
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  return { requests, errors, source };
}

for (const scenario of [
  { name: 'client without a source', sources: [], status: 'committed', link: false, import: false },
  { name: 'client with active AIRE', sources: ['aire_services'], status: 'committed', link: true, import: false },
  { name: 'client with another integration', sources: ['cornerstone_tax'], status: 'committed', link: false, import: false },
  { name: 'draft without a source', sources: [], status: 'draft', link: false, import: false },
  { name: 'draft with time tracking', sources: ['custom'], status: 'draft', link: false, import: true },
  { name: 'voided payroll with active AIRE', sources: ['aire_services'], status: 'committed', voided: true, link: false, import: false },
]) {
  test(`shows only relevant integration actions for ${scenario.name}`, async ({ page }) => {
    const { errors } = await mockWorkspace(page, scenario);
    await page.goto('/companies/1/pay-runs/71/work');
    await expect(page.getByRole('region', { name: 'Process payroll workspace' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Processing Timeline', exact: true })).toBeVisible();
    await expect(page.getByText('Failed to load pay period', { exact: false })).toHaveCount(0);
    // Wait for the actual processing component, not just its loading container.
    await expect(page.getByRole('button', { name: scenario.status === 'draft' ? 'Calculate Payroll' : 'Correct Pay Date', exact: true })).toHaveCount(scenario.voided ? 0 : 1);
    await expect(page.getByRole('button', { name: 'Link AIRE Record', exact: true })).toHaveCount(scenario.link ? 1 : 0);
    await expect(page.getByRole('button', { name: 'Import Time Tracking', exact: true })).toHaveCount(scenario.import ? 1 : 0);
    await expect(page.getByRole('button', { name: 'View AIRE Record', exact: true })).toHaveCount(0);
    expect(errors).toEqual([]);
  });
}

test('reviews saved AIRE records while disabled without fetching or mutating the source', async ({ page }) => {
  const { requests, errors } = await mockWorkspace(page, { linked: true });
  await page.goto('/companies/1/pay-runs/71/work');
  await page.getByRole('button', { name: 'View AIRE Record', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Linked AIRE records' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByText('Saved AIRE source · AIRE-REVIEW-81')).toBeVisible();
  await expect(dialog.getByText('Integration disabled for this client')).toBeVisible();
  await expect(dialog.getByText('Recorded rounding differences')).toBeVisible();
  await expect(dialog.getByText(/Total difference: 0.05 hours/)).toBeVisible();
  await expect(dialog.getByRole('button', { name: /apply|link|import/i })).toHaveCount(0);
  expect(requests.some((request) => /time_tracking_sources|time_tracking_import/.test(request))).toBe(false);
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'View AIRE Record', exact: true })).toBeFocused();
  expect(errors).toEqual([]);
});

test('ignores a previous client source response after switching client settings', async ({ page }) => {
  await mockWorkspace(page, { secondClient: true });
  let release!: () => void;
  let signalStarted!: () => void;
  const started = new Promise<void>((resolve) => { signalStarted = resolve; });
  const released = new Promise<void>((resolve) => { release = resolve; });
  await page.route('**/api/v1/admin/time_tracking_sources', async (route) => {
    if (route.request().headers()['x-company-id'] !== '1') return route.fallback();
    signalStarted();
    await released;
    return route.fallback();
  });
  try {
    await page.goto('/time-tracking-sources');
    await started;
    await page.getByRole('link', { name: 'Client Management', exact: true }).click();
    await page.getByRole('button', { name: 'Time tracking settings for Second Client' }).filter({ visible: true }).click();
    await expect(page.getByRole('textbox', { name: 'Source name', exact: true })).toHaveValue('Second client source');
    const response = page.waitForResponse((res) => res.url().endsWith('/admin/time_tracking_sources') && res.request().headers()['x-company-id'] === '1');
    release();
    await response;
    await expect(page.getByRole('textbox', { name: 'Source name', exact: true })).toHaveValue('Second client source');
    await expect(page.getByText('Active client: Second Client')).toBeVisible();
  } finally { release(); }
});

test('opens client-specific settings and persists the integration switch in the source configuration', async ({ page }, testInfo) => {
  const { source, errors } = await mockWorkspace(page);
  await page.goto('/settings/clients');
  await page.getByRole('button', { name: 'Time tracking settings for Review Client' }).filter({ visible: true }).click();
  await expect(page).toHaveURL(/\/time-tracking-sources$/);
  const toggle = page.getByRole('switch', { name: /Enable time tracking integration for this client/ });
  await expect(toggle).not.toBeChecked();
  await toggle.check();
  await page.getByRole('button', { name: 'Save source', exact: true }).click();
  await expect(page.getByText('Time tracking source updated for this client.')).toBeVisible();
  expect(source.active).toBe(true);
  await toggle.scrollIntoViewIfNeeded();
  await page.screenshot({ path: testInfo.outputPath('client-time-tracking-setting.png'), fullPage: true });
  await page.reload();
  await expect(toggle).toBeChecked();
  await toggle.uncheck();
  await page.getByRole('button', { name: 'Save source', exact: true }).click();
  await expect(toggle).not.toBeChecked();
  await expect(page.getByText('Time tracking source updated for this client.')).toBeVisible();
  expect(source.active).toBe(false);
  expect(errors).toEqual([]);
});
