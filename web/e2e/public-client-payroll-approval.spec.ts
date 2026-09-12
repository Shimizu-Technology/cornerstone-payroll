import { expect, test, type Page, type Route } from '@playwright/test';

const acknowledgement = 'I approve this exact payroll review revision for processing.';

async function fulfillJson(route: Route, body: unknown, status = 200): Promise<void> {
  await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

function payrollReview(status: 'pending' | 'approved'): Record<string, unknown> {
  return {
    id: 91,
    revision: 3,
    schema_version: 'v1',
    calculation_checksum: 'a'.repeat(64),
    checksum_short: 'aaaaaaaaaaaa',
    status,
    source_manifest: {},
    generated_at: '2026-09-13T01:00:00Z',
    generated_by_name: 'Cornerstone Payroll',
    approved_at: status === 'approved' ? '2026-09-13T02:00:00Z' : null,
    approved_by_id: status === 'approved' ? 7 : null,
    approved_by_name: status === 'approved' ? 'MoSa Approver' : null,
    approval_recorded_by_name: status === 'approved' ? 'MoSa Approver' : null,
    approval_method: status === 'approved' ? 'client_portal' : null,
    approval_notes: status === 'approved' ? 'Looks correct.' : null,
    approval_evidence_reference: null,
    acknowledgement,
  };
}

function payPeriod(status: 'pending' | 'approved'): Record<string, unknown> {
  return {
    id: 702,
    company_id: 1,
    start_date: '2026-08-16',
    end_date: '2026-08-31',
    pay_date: '2026-09-05',
    status: 'calculated',
    run_purpose: 'regular',
    includes_base_salary: true,
    includes_recurring_items: true,
    employee_count: 2,
    total_gross: '6500.00',
    total_net: '4890.00',
    client_payroll_approval_required: true,
    payroll_review: payrollReview(status),
    payroll_items: [
      {
        id: 801, employee_id: 21, employee_name: 'Mo Example', employment_type: 'salary',
        total_hours: '0.0', hours_worked: '0.0', pay_rate: '4000.00', gross_pay: '4000.00',
        withholding_tax: '620.00', social_security_tax: '248.00', medicare_tax: '58.00',
        additional_medicare_tax: '0.00', state_withheld: '0.00', retirement_payment: '200.00',
        roth_retirement_payment: '0.00', loan_payment: '150.00', loan_deduction: '150.00',
        insurance_payment: '75.00', total_deductions: '1351.00', net_pay: '2649.00',
      },
      {
        id: 802, employee_id: 22, employee_name: 'Sara Example', employment_type: 'salary',
        total_hours: '0.0', hours_worked: '0.0', pay_rate: '2500.00', gross_pay: '2500.00',
        withholding_tax: '350.00', social_security_tax: '155.00', medicare_tax: '36.25',
        additional_medicare_tax: '0.00', state_withheld: '0.00', retirement_payment: '125.00',
        roth_retirement_payment: '0.00', loan_payment: '0.00', loan_deduction: '0.00',
        insurance_payment: '0.00', total_deductions: '666.25', net_pay: '1833.75',
      },
    ],
  };
}

async function mockClientShell(page: Page): Promise<void> {
  await page.route('**/api/v1/auth/me', (route) => fulfillJson(route, {
    user: {
      id: 7,
      email: 'approver@mosa.example',
      name: 'MoSa Approver',
      role: 'client',
      organization_id: 1,
      organization_name: 'Cornerstone',
      company_id: 1,
      company_name: "MoSa's",
      home_company_id: 1,
      assigned_company_ids: [1],
    },
  }));
  await page.route('**/api/v1/companies', (route) => fulfillJson(route, {
    companies: [{
      id: 1,
      name: "MoSa's",
      active: true,
      active_employees: 2,
      total_employees: 2,
      pay_frequency: 'biweekly',
      historical_payroll_enabled: true,
      client_payroll_approval_required: true,
      payroll_environment: 'live',
    }],
    can_manage_clients: false,
    can_view_client_management: false,
    can_switch_company: false,
    current_company_id: 1,
  }));
}

test('client reviews complex payroll and explicitly approves the exact calculation revision', async ({ page }): Promise<void> => {
  await mockClientShell(page);
  let approvalPayload: Record<string, unknown> | null = null;

  await page.route('**/api/v1/client/pay_periods/702**', async (route): Promise<void> => {
    if (route.request().method() === 'POST') {
      approvalPayload = route.request().postDataJSON() as Record<string, unknown>;
      await fulfillJson(route, { payroll_review: payrollReview('approved') });
      return;
    }
    await fulfillJson(route, { pay_period: payPeriod('pending') });
  });

  await page.goto('/companies/1/pay-runs/702/overview');

  await expect(page.getByRole('heading', { name: 'Payroll review revision 3' })).toBeVisible();
  await expect(page.getByText('Review ID aaaaaaaaaaaa')).toBeVisible();
  const payrollTable = page.getByRole('table');
  await expect(payrollTable.getByText('Mo Example')).toBeVisible();
  await expect(payrollTable.getByText('Sara Example')).toBeVisible();
  await expect(payrollTable.getByRole('columnheader', { name: 'Retirement' })).toBeVisible();
  await expect(payrollTable.getByRole('columnheader', { name: 'Loans' })).toBeVisible();

  const approveButton = page.getByRole('button', { name: 'Approve This Exact Revision' });
  await expect(approveButton).toBeDisabled();
  await page.getByPlaceholder('Optional: add a note for Cornerstone about this payroll.').fill('Looks correct.');
  await page.getByRole('checkbox').check();
  const approvalResponse = page.waitForResponse((response) => response.request().method() === 'POST' && response.url().includes('/api/v1/client/pay_periods/702/approve_review'));
  await approveButton.click();
  await approvalResponse;

  expect(approvalPayload).toEqual({ acknowledgement, notes: 'Looks correct.' });
  await expect(page.getByText('Approved by MoSa Approver. Cornerstone may now complete its payroll review.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Approve This Exact Revision' })).toHaveCount(0);
});
