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
    let employee = {
      id: 31, company_id: 1, first_name: 'Synthetic', last_name: 'Lifecycle Worker', status: 'active',
      employment_type: 'salary', salary_type: 'annual', pay_frequency: 'biweekly', pay_rate: 0,
      w4_effective_on: null, w4_form_version: 2020, ssn_last_four: '1234', readiness_gate_enforced: true,
    };
    const item = {
      id: 45, company_id: 1, employee_id: 31, employee_name: 'Synthetic Lifecycle Worker',
      event_kind: 'termination', affects_pay: true, source_actor_name: 'Synthetic Client Manager',
      effective_on: '2026-11-27', created_at: revision, updated_at: revision, can_review: true,
      changed_fields: ['termination_date'], before_values: { termination_date: null }, after_values: { termination_date: '2026-11-27' },
      readiness_checklist: { status: 'ready', rates_on: '2026-11-28', w4_on: '2026-12-02', missing_keys: [], items: [] },
      return_note: null, client_response_note: null, verification_note: null, resubmitted_at: null, audit_references: [],
      warnings: { committed_pay_period_ids: [], possible_self_created_hire: false, review_final_pay: true,
        post_termination_committed_pay_period_ids: [21], direct_deposit_missing_bank_details: false, tax_filing_impact: null, approved_pay_period_ids: [24] },
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
        const pageNumber = Number(url.searchParams.get('page') ?? 1);
        const row = pageNumber === 2 ? { ...item, id: 46, employee_name: 'Synthetic Earlier Worker' } : item;
        const data = status === url.searchParams.get('status') ? [{ ...row, status }] : [];
        body = { data, meta: { current_page: pageNumber, total_pages: 2, total_count: 26 } };
      } else if (path.endsWith('/employee_verification_items/search')) {
        body = { data: [{ ...item, status }], meta: { current_page: 1, total_pages: 1, total_count: 1 } };
      } else if (path.endsWith('/45/return_to_client')) {
        savedNotes.push(route.request().postDataJSON());
        status = 'returned_to_client';
        body = { data: { ...item, status } };
      } else if (path.endsWith('/employee_verification_items/45')) {
        body = { data: { ...item, status } };
      } else if (path.endsWith('/admin/employees/31')) {
        if (route.request().method() === 'GET') {
          expect(url.searchParams.get('mask_tax_ids')).toBe('true');
        } else {
          const update = route.request().postDataJSON();
          expect(update.mask_tax_ids).toBe(true);
          expect(update.employee).toMatchObject({ first_name: 'Synthetic Corrected' });
          for (const field of ['ssn', 'pay_rate', 'w4_effective_on']) expect(update.employee).not.toHaveProperty(field);
          employee = { ...employee, first_name: update.employee.first_name };
        }
        body = { data: employee };
      } else if (path.endsWith('/admin/payroll_fields')) {
        body = { payroll_fields: [] };
      } else if (path.endsWith('/admin/employees/31/payroll_fields')) {
        body = { employee_payroll_fields: [] };
      } else if (path.endsWith('/cable_ticket')) {
        await route.fulfill({ status: 204 });
        return;
      } else if (path.endsWith('/counts')) {
        body = { data: { pending_verifications: 1, waiting_count: 1, unread_count: 0 } };
      }
      await route.fulfill({ json: body });
    });

    await page.goto('/companies/1/verifications');
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.getByRole('button', { name: /Synthetic Earlier Worker/ })).toBeVisible();
    await expect(page).toHaveURL(/\?page=2$/);
    await page.getByRole('button', { name: 'Previous' }).click();
    await expect(page.getByRole('button', { name: /Synthetic Lifecycle Worker/ })).toBeVisible();
    const input = page.getByLabel('Search by employee');
    await expect(input).toHaveCSS('font-size', '16px');
    const searchRequest = page.waitForRequest(request => new URL(request.url()).pathname.endsWith('/employee_verification_items/search'));
    await input.fill(item.employee_name);
    const request = await searchRequest;
    expect(request.method()).toBe('POST');
    expect(new URL(request.url()).search).toBe('');
    expect(request.postDataJSON()).toMatchObject({ employee_search: item.employee_name });
    await expect(page).toHaveURL(/\/verifications$/);
    await page.getByRole('button', { name: /Synthetic Lifecycle Worker/ }).click();
    const details = page.getByRole('heading', { name: item.employee_name });
    await expect(details).toBeFocused();
    await expect(page.getByText('Backdated termination.')).toBeVisible();
    const fixHref = await page.getByRole('link', { name: 'Fix & verify' }).getAttribute('href');
    expect(new URL(fixHref!, 'https://example.test').searchParams.get('return_to')).toBe('/companies/1/verifications?item_id=45');
    if (width === 390) {
      await expect(page.getByRole('button', { name: 'Back to employee changes' })).toBeVisible();
      await expect(page.getByLabel('Search by employee')).toBeHidden();
    } else {
      const search = page.getByLabel('Search by employee');
      await expect(search).toBeVisible();
      expect((await details.boundingBox())!.x).toBeGreaterThan((await search.boundingBox())!.x);
    }
    await page.getByRole('link', { name: 'Fix & verify' }).click();
    await expect(page.getByText('Changing approved payroll may require client re-approval')).toBeVisible();
    const ssn = page.locator('[name="ssn"]');
    await expect(ssn).toHaveAttribute('type', 'password');
    await expect(ssn).toHaveValue('');
    await expect(page.getByText(/Saved SSN ending in 1234/)).toBeVisible();
    await page.getByLabel(/^First Name/).fill('Synthetic Corrected');
    await page.getByRole('button', { name: 'Update Employee' }).click();
    const verifyFix = page.getByRole('dialog', { name: 'Mark the saved fix verified?' });
    await expect(verifyFix).toBeVisible();
    expect(employee.first_name).toBe('Synthetic Corrected');
    await verifyFix.getByRole('button', { name: 'Cancel' }).click();

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

  test(`org admin can resolve residual readiness after rollback at ${width}px`, async ({ page }) => {
    const consoleErrors: string[] = [];
    page.on('pageerror', error => consoleErrors.push(error.message));
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.setViewportSize({ width, height: 900 });
    let gateEnforced = true;
    let overrideActive = false;
    const writes: unknown[] = [];
    const worker = { id: 31, company_id: 1, first_name: 'Synthetic', last_name: 'Readiness Worker', status: 'active', employment_type: 'hourly' };
    await page.route('**/api/v1/**', async route => {
      const request = route.request();
      const url = new URL(request.url());
      const path = url.pathname;
      let body: unknown = { data: [], meta: {} };
      if (path.endsWith('/auth/me')) {
        body = { user: { id: 1, email: 'admin@example.test', name: 'Synthetic Org Admin', role: 'org_admin',
          organization_id: 1, company_id: 1, capabilities: ['payroll_operations', 'override_employee_readiness'] } };
      } else if (path.endsWith('/companies')) {
        body = { companies: [{ id: 1, name: 'Synthetic Lifecycle Client', organization_id: 1, active: true,
          payroll_environment: 'live', staff_employee_lifecycle_available: true, workspace_can_write: true }], current_company_id: 1 };
      } else if (path.endsWith('/admin/employees/31')) {
        expect(url.searchParams.get('mask_tax_ids')).toBe('true');
        body = { data: { ...worker, readiness_gate_enforced: gateEnforced } };
      } else if (path.endsWith('/readiness_override') && request.method() === 'GET') {
        body = url.searchParams.has('pay_period_id')
          ? { data: { default_w4_acknowledgement_required: true, checklist: { status: 'incomplete', rates_on: '2026-11-29',
            w4_on: '2026-12-04', missing_keys: ['tax_form'], items: [] } } }
          : { data: { today: '2026-11-28', latest_expiration: '2026-12-28',
            pay_periods: [{ id: 14, start_date: '2026-11-16', end_date: '2026-11-29', pay_date: '2026-12-04' }],
            active_overrides: overrideActive ? [{ id: 19, pay_period_id: 14, expires_on: null }] : [] } };
      } else if (path.endsWith('/readiness_override') && request.method() === 'POST') {
        writes.push(request.postDataJSON());
        overrideActive = true;
      } else if (path.endsWith('/clear_readiness_gate')) {
        writes.push(request.postDataJSON());
        gateEnforced = false;
      } else if (path.endsWith('/readiness_override/19')) {
        expect(request.method()).toBe('DELETE');
        writes.push(request.postDataJSON());
        overrideActive = false;
      } else if (path.endsWith('/cable_ticket')) {
        await route.fulfill({ status: 204 });
        return;
      }
      await route.fulfill({ json: body });
    });

    await page.goto('/companies/1/employees/31/activity');
    const identity = page.getByRole('region', { name: 'Employee identity' });
    const trigger = page.getByRole('button', { name: 'Readiness override' });
    await expect(trigger).toHaveCSS('min-height', '44px');
    await trigger.click();
    await page.keyboard.press('Escape');
    await expect(trigger).toBeFocused();
    await trigger.click();
    const grant = page.getByRole('dialog', { name: 'Readiness override' });
    const reason = grant.getByRole('textbox', { name: /Reason/ });
    await expect(reason).toHaveCSS('font-size', '16px');
    await expect(grant.getByLabel('Override scope')).toHaveCSS('font-size', '16px');
    await expect(grant.getByRole('button', { name: 'Allow in payroll' })).toHaveCSS('min-height', '44px');
    expect(await grant.evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true);
    await reason.fill('Record a test payroll exception.');
    await grant.getByRole('checkbox', { name: /IRS Pub 15-T/ }).check();
    await grant.getByRole('button', { name: 'Allow in payroll' }).click();
    await expect(page.getByText('Override active', { exact: true })).toBeVisible();

    await page.getByRole('button', { name: 'Clear readiness gate' }).click();
    const clear = page.getByRole('dialog', { name: 'Clear readiness gate' });
    await expect(clear.getByRole('textbox')).toBeFocused();
    await clear.getByRole('textbox').fill('The readiness gate was applied in error.');
    await clear.getByRole('button', { name: 'Clear readiness gate' }).click();
    await expect(trigger).toHaveCount(0);
    await expect(identity).toBeFocused();

    await page.getByRole('button', { name: 'Revoke override' }).click();
    const revoke = page.getByRole('dialog', { name: 'Revoke readiness override' });
    await expect(revoke.getByRole('textbox')).toBeFocused();
    await revoke.getByRole('textbox').fill('The test override is no longer needed.');
    await revoke.getByRole('button', { name: 'Revoke readiness override' }).click();
    await expect(page.getByText('Readiness override revoked.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Revoke override' })).toHaveCount(0);
    await expect(identity).toBeFocused();
    expect(writes).toEqual([
      { pay_period_id: 14, reason: 'Record a test payroll exception.', default_w4_acknowledged: true },
      { reason: 'The readiness gate was applied in error.' },
      { reason: 'The test override is no longer needed.' },
    ]);
    expect(consoleErrors).toEqual([]);
  });
}
