import { expect, test } from '@playwright/test';

for (const width of [390, 1440]) {
  test(`staff can review and send back an employee update at ${width}px`, async ({ page }) => {
    const consoleErrors: string[] = [];
    page.on('pageerror', error => consoleErrors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') consoleErrors.push(message.text()); });
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.setViewportSize({ width, height: 900 });
    const revision = '2026-11-28T11:00:00.123456Z';
    let status = 'pending_verification';
    const savedNotes: unknown[] = [];
    const item = {
      id: 45, company_id: 1, employee_id: 31, employee_name: 'Synthetic Lifecycle Worker',
      event_kind: 'termination', affects_pay: true, source_actor_name: 'Synthetic Client Manager',
      effective_on: '2026-11-27', created_at: revision, updated_at: revision, can_review: true,
      changed_fields: ['termination_date'], before_values: { termination_date: null }, after_values: { termination_date: '2026-11-27' },
      readiness_checklist: { status: 'ready', rates_on: '2026-11-28', w4_on: '2026-12-02', missing_keys: [], items: [] },
      return_note: null, client_response_note: null, verification_note: null, resubmitted_at: null, audit_references: [],
      warnings: { committed_pay_period_ids: [], possible_self_created_hire: false, review_final_pay: true,
        post_termination_committed_pay_period_ids: [21], direct_deposit_missing_bank_details: false, tax_filing_impact: null, approved_pay_period_ids: [] },
    };
    await page.route('**/api/v1/**', async route => {
      const url = new URL(route.request().url());
      const path = url.pathname;
      let body: unknown = { data: [] };
      if (path.endsWith('/auth/me')) {
        body = { user: { id: 1, email: 'staff@example.test', name: 'Synthetic Staff Manager', role: 'manager',
          organization_id: 1, company_id: 1, assigned_company_ids: [1], capabilities: ['payroll_operations', 'manage_client_configuration'] } };
      } else if (path.endsWith('/companies')) {
        body = { companies: [{ id: 1, name: 'Synthetic Lifecycle Client', organization_id: 1, active: true,
          payroll_environment: 'live', client_managed_employee_lifecycle: true, client_capabilities: ['manage_client_configuration'] }],
        can_manage_clients: false, can_view_client_management: true, can_switch_company: false, current_company_id: 1 };
      } else if (path.endsWith('/employee_verification_items')) {
        const data = status === url.searchParams.get('status') ? [{ ...item, status }] : [];
        body = { data, meta: { current_page: 1, total_pages: 1, total_count: data.length } };
      } else if (path.endsWith('/45/return_to_client')) {
        savedNotes.push(route.request().postDataJSON());
        status = 'returned_to_client';
        body = { data: { ...item, status } };
      } else if (path.endsWith('/employee_verification_items/45')) {
        body = { data: { ...item, status } };
      } else if (path.endsWith('/cable_ticket')) {
        await route.fulfill({ status: 204 });
        return;
      } else if (path.endsWith('/counts')) {
        body = { data: { pending_verifications: 1, waiting_count: 1, unread_count: 0 } };
      }
      await route.fulfill({ json: body });
    });

    await page.goto('/companies/1/verifications');
    await page.getByRole('button', { name: /Synthetic Lifecycle Worker/ }).click();
    const details = page.getByRole('heading', { name: item.employee_name });
    await expect(details).toBeFocused();
    await expect(page.getByText('Backdated termination.')).toBeVisible();
    if (width === 390) {
      await expect(page.getByRole('button', { name: 'Back to employee changes' })).toBeVisible();
      await expect(page.getByLabel('Search by employee')).toBeHidden();
    } else {
      const search = page.getByLabel('Search by employee');
      await expect(search).toBeVisible();
      expect((await details.boundingBox())!.x).toBeGreaterThan((await search.boundingBox())!.x);
    }
    const trigger = page.getByRole('button', { name: 'Send back to client' });
    await trigger.click();
    await page.keyboard.press('Escape');
    await expect(trigger).toBeFocused();
    await trigger.click();
    const dialog = page.getByRole('dialog', { name: 'Send back to client' });
    const note = dialog.getByRole('textbox');
    await expect(note).toBeFocused();
    expect(await note.evaluate(element => getComputedStyle(element).fontSize)).toBe('16px');
    await expect(dialog.getByRole('button', { name: 'Send back', exact: true })).toHaveCSS('min-height', '44px');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth
      && Array.from(document.querySelectorAll('main, [role="dialog"]')).every(element => element.scrollWidth <= element.clientWidth))).toBe(true);
    await note.fill('Please confirm the last day worked.');
    await dialog.getByRole('button', { name: 'Send back', exact: true }).click();
    await expect(page.getByRole('region', { name: 'Verification details' }).getByText('Sent back to client', { exact: true })).toBeVisible();
    expect(savedNotes).toEqual([{ updated_at: revision, return_note: 'Please confirm the last day worked.' }]);
    expect(consoleErrors).toEqual([]);
  });
}
