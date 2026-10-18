import { expect, test } from '@playwright/test';

test('keyboard focus stays on the same client through delayed grant and revoke confirmation', async ({ page }) => {
  const clients = [{ id: 1, name: 'Pacific QA' }, { id: 2, name: 'Harbor QA' }];
  const accountant = { id: 2, name: 'Assigned Accountant', email: 'accountant@example.test', role: 'accountant', active: true,
    assigned_company_ids: [1, 2], assigned_companies: clients, created_at: '2026-01-01', updated_at: '2026-01-01' };
  const assignments = clients.map((company, index) => ({ id: (index + 1) * 10, user_id: 2, company_id: company.id,
    company_name: company.name, client_management: false, test_workspace: false, expires_at: null }));
  const patches: Array<{ id: number; enabled: boolean }> = [];
  let reads = 0;
  let release: (() => void) | undefined;
  await page.route('**/api/v1/**', async route => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith('/auth/me')) return route.fulfill({ json: { user: { id: 1, name: 'Firm Admin', role: 'org_admin', company_id: 1, assigned_company_ids: [1, 2], capabilities: ['manage_users'] } } });
    if (path.endsWith('/companies')) return route.fulfill({ json: { companies: clients, current_company_id: 1, can_switch_company: true } });
    if (path.endsWith('/admin/users')) return route.fulfill({ json: { data: [accountant] } });
    if (path.endsWith('/company_assignments')) {
      reads += 1;
      if (reads > 1) await new Promise<void>(resolve => { release = resolve; });
      return route.fulfill({ json: { data: assignments } });
    }
    if (/\/company_assignments\/\d+$/.test(path)) {
      const id = Number(path.split('/').pop());
      const enabled = route.request().postDataJSON().company_assignment.client_management;
      assignments.find(assignment => assignment.id === id)!.client_management = enabled;
      patches.push({ id, enabled });
      return route.fulfill({ json: { data: assignments.find(assignment => assignment.id === id) } });
    }
    return route.fulfill({ json: { data: [] } });
  });
  try {
    await page.goto('/settings/users');
    await page.getByRole('button', { name: 'Client management', exact: true }).click();
    const action = page.getByRole('region', { name: 'Harbor QA' }).getByRole('button');
    await action.focus();
    for (const [index, enabled] of [true, false].entries()) {
      await page.keyboard.press('Enter');
      await expect.poll(() => reads).toBe(index + 2);
      await expect(action).toBeFocused();
      await expect(action).toHaveAttribute('aria-disabled', 'true');
      await page.keyboard.press('Enter');
      expect(patches).toHaveLength(index + 1);
      release!();
      await expect(action).toHaveAttribute('aria-label', `${enabled ? 'Revoke' : 'Grant'} Client management for Harbor QA`);
      await expect(action).not.toHaveAttribute('aria-disabled', 'true');
      await expect(action).toBeFocused();
    }
    expect(patches).toEqual([{ id: 20, enabled: true }, { id: 20, enabled: false }]);
    expect(assignments[0].client_management).toBe(false);
  } finally {
    release?.();
  }
});
