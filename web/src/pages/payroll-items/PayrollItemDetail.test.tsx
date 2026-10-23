// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { useState } from 'react';
import { PayrollItemReviewDialog } from '@/components/payroll/PayrollItemReviewDialog';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Employee, PayPeriod, PayrollItem } from '@/types';
import { PayrollItemDetail } from './PayrollItemDetail';

const apiMocks = vi.hoisted(() => ({ employee: vi.fn(), payPeriod: vi.fn(), payrollItem: vi.fn(), activeCompany: { id: 1, name: 'Synthetic Payroll' } as Record<string, unknown> }));
vi.mock('@/services/api', () => ({
  employeesApi: { get: apiMocks.employee },
  payPeriodsApi: { get: apiMocks.payPeriod },
  payrollItemsApi: { get: apiMocks.payrollItem },
}));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: apiMocks.activeCompany }) }));
vi.mock('@/components/payroll/PayrollResultBreakdown', () => ({
  PayrollResultBreakdown: () => null,
  PaycheckWithholdingContext: () => null,
  PaycheckRetirementContext: () => null,
}));

const employee = { id: 7, company_id: 1, first_name: 'Casey', last_name: 'Employee', payment_delivery_method: 'paper_check' } as Employee;
const baseItem = { id: 3, employee_id: 7, employment_type: 'hourly', pay_rate: 25, hours_worked: 4, total_hours: 4, gross_pay: 100, net_pay: 92.35, total_deductions: 7.65, effective_payment_delivery_method: 'paper_check', earnings_statement_eligible: true } as PayrollItem;

function renderDetail(item: PayrollItem, status: PayPeriod['status'] = 'committed') {
  apiMocks.payPeriod.mockResolvedValue({ pay_period: { id: 2, company_id: 1, start_date: '2026-11-01', end_date: '2026-11-15', pay_date: '2026-11-30', status, payroll_items: [item] } });
  // The detail serializer omits check_status/voided; the page retains them from
  // the pay-period summary instead of inferring history from today's employee.
  const detail = { ...item };
  delete detail.check_status;
  delete detail.voided;
  apiMocks.payrollItem.mockResolvedValue({ payroll_item: detail });
  render(<MemoryRouter initialEntries={['/companies/1/pay-runs/2/payroll-items/3']}><Routes><Route path="/companies/:companyId/pay-runs/:id/payroll-items/:payrollItemId" element={<PayrollItemDetail />} /></Routes></MemoryRouter>);
}

describe('PayrollItemDetail payment labels', () => {
  afterEach(cleanup);
  beforeEach(() => { apiMocks.activeCompany = { id: 1, name: 'Synthetic Payroll' }; vi.clearAllMocks(); apiMocks.employee.mockResolvedValue({ data: employee }); });

  it('keeps the direct payroll-item route readable for a workspace reviewer', async () => {
    apiMocks.activeCompany = { id: 1, name: 'Synthetic Payroll', payroll_environment: 'migration_rehearsal', workspace_can_write: false };
    renderDetail({ ...baseItem, check_number: '8111', check_status: 'delivered' });
    expect(await screen.findByText(/You have read-only access to this workspace/)).toBeTruthy();
    expect(screen.getByText('Issued')).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Employee workspace' })).toBeTruthy();
    expect(screen.getByText('Payment context')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Save|Void|Reissue|Record Issued/ })).toBeNull();
  });

  it.each(['calculated', 'approved', 'committed'] as const)('shows earned zero-net %s rows as statement only', async (status) => {
    renderDetail({ ...baseItem, net_pay: 0, total_deductions: 100, check_number: null, check_status: null }, status);
    expect((await screen.findAllByText('Earnings statement only')).length).toBeGreaterThan(0);
    expect(screen.getByText('$0 net · earnings statement only')).toBeDefined();
    expect(screen.getByText('No payment issued')).toBeDefined();
    expect(screen.queryByText('Paper check')).toBeNull();
    expect(screen.queryByText('Check not assigned')).toBeNull();
    expect(screen.queryByText('Check status')).toBeNull();
    expect(screen.queryByText('Pending')).toBeNull();
  });

  it.each(['paper_check', 'direct_deposit'] as const)('shows signed negative %s corrections without suggesting a payment', async (method) => {
    renderDetail({ ...baseItem, gross_pay: -25, net_pay: -23.09, total_deductions: -1.91, effective_payment_delivery_method: method, check_number: null });
    await screen.findAllByText('Earnings statement only');
    expect(screen.getByText('Adjustment · earnings statement only')).toBeDefined();
    expect(screen.getByText('No payment issued')).toBeDefined();
    expect(screen.queryByText('Direct deposit · earnings stub')).toBeNull();
    expect(screen.queryByText('Direct deposit (stub only)')).toBeNull();
    expect(screen.queryByText('Paper check')).toBeNull();
  });

  it.each([false, true])('does not present draft inputs or stale eligible=%s values as an earnings statement', async (eligible) => {
    renderDetail({ ...baseItem, gross_pay: eligible ? 100 : 0, net_pay: 0, total_deductions: eligible ? 100 : 0, earnings_statement_eligible: eligible }, 'draft');
    await screen.findByText('Payment context');
    expect(screen.queryByText('Earnings statement only')).toBeNull();
    expect(screen.getByText('Pending')).toBeDefined();
  });

  it('shows earned zero-net direct-deposit preferences as statement only', async () => {
    renderDetail({ ...baseItem, net_pay: 0, total_deductions: 100, effective_payment_delivery_method: 'direct_deposit', check_number: null });
    await screen.findAllByText('Earnings statement only');
    expect(screen.getByText('No payment issued')).toBeDefined();
    expect(screen.queryByText('Direct deposit (stub only)')).toBeNull();
    expect(screen.queryByText('Available to print; bank transfer not confirmed')).toBeNull();
  });

  it.each([['unprinted', 'Assigned'], ['prepared', 'Prepared'], ['printed', 'Printed'], ['delivered', 'Issued']] as const)('retains positive check %s evidence from the summary', async (check_status, label) => {
    renderDetail({ ...baseItem, check_number: '30000', check_status });
    await screen.findByText('Payment context');
    expect(screen.getByText(label)).toBeDefined();
    expect(screen.getByText('Paper check')).toBeDefined();
    expect(screen.queryByText('No payment issued')).toBeNull();
  });

  it('retains voided check evidence even when the amount is zero', async () => {
    renderDetail({ ...baseItem, net_pay: 0, check_number: '30000', voided: true, check_status: 'voided', earnings_statement_eligible: false });
    await screen.findByText('Payment context');
    expect(screen.getAllByText('Voided').length).toBe(2);
    expect(screen.getByText('Paper check')).toBeDefined();
    expect(screen.queryByText('Earnings statement only')).toBeNull();
  });

  it('retains a saved issued check instead of asserting no payment from its current zero value', async () => {
    renderDetail({ ...baseItem, net_pay: 0, check_number: '30000', check_status: 'delivered' });
    await screen.findByText('Payment context');
    expect(screen.getByText('Issued')).toBeDefined();
    expect(screen.queryByText('No payment issued')).toBeNull();
  });

  it.each([null, '2026-11-22T09:00:00Z'])('shows persisted bank payment evidence independently of statement printed=%s', async (printedAt) => {
    const confirmed = { ...baseItem, effective_payment_delivery_method: 'direct_deposit', check_number: null,
      check_printed_at: printedAt, payment_confirmation: { settled_on: '2026-11-22', bank_reference: 'SIM-P03-BANK-20261122-REPLACEMENT', confirmed_at: '2026-11-22T07:04:00Z' } } as PayrollItem;
    renderDetail(confirmed);
    expect(await screen.findByText('Bank paid Nov 22, 2026 · SIM-P03-BANK-20261122-REPLACEMENT')).toBeDefined();
    expect(screen.getByText('Bank payment confirmed')).toBeDefined();
    expect(screen.getByText('Available to print; not payment evidence')).toBeDefined();
    expect(screen.queryByText('Direct-deposit stub; transfer not confirmed')).toBeNull();
    expect(screen.queryByText('Available to print; bank transfer not confirmed')).toBeNull();
    expect(screen.queryByText('Earnings statement only')).toBeNull();
  });

  it('shows the exact mixed-case bank reference without capitalizing or overflowing it', async () => {
    const reference = `sim-mixed-${'a'.repeat(180)}`;
    renderDetail({ ...baseItem, effective_payment_delivery_method: 'direct_deposit', check_number: null,
      payment_confirmation: { settled_on: '2026-11-22', bank_reference: reference, confirmed_at: '2026-11-22T07:04:00Z' } } as PayrollItem);
    const evidence = await screen.findByText(reference);
    expect(evidence.style.textTransform).toBe('none');
    expect(evidence.style.overflowWrap).toBe('anywhere');
  });

  it('keeps void status distinct from retained bank confirmation history', async () => {
    renderDetail({ ...baseItem, effective_payment_delivery_method: 'direct_deposit', check_number: null, voided: true,
      payment_confirmation: { settled_on: '2026-11-22', bank_reference: 'SIM-RETAINED-BANK', confirmed_at: '2026-11-22T07:04:00Z' } } as PayrollItem);
    expect(await screen.findByText('Voided payroll item')).toBeDefined();
    expect(screen.getByText('Retained bank settlement')).toBeDefined();
    expect(screen.getByText('SIM-RETAINED-BANK')).toBeDefined();
    expect(screen.queryByText('Bank payment confirmed')).toBeNull();
    expect(screen.queryByText('Direct-deposit stub; transfer not confirmed')).toBeNull();
  });

  it('does not turn a printed eligible direct-deposit statement into confirmation', async () => {
    renderDetail({ ...baseItem, effective_payment_delivery_method: 'direct_deposit', check_number: null,
      check_printed_at: '2026-11-22T07:00:00Z', earnings_statement_eligible: true } as PayrollItem);
    await screen.findByText('Payment context');
    expect(screen.getByText('Direct-deposit stub; transfer not confirmed')).toBeDefined();
    expect(screen.queryByText('Bank payment confirmed')).toBeNull();
  });

  it('keeps saved positive direct-deposit behavior despite the employee default', async () => {
    renderDetail({ ...baseItem, effective_payment_delivery_method: 'direct_deposit', check_number: null });
    await screen.findByText('Payment context');
    expect(screen.getByText('Direct deposit (stub only)')).toBeDefined();
    expect(screen.getByText('Available to print; bank transfer not confirmed')).toBeDefined();
    expect(screen.queryByText('Earnings statement only')).toBeNull();
  });
});


it('reviews the exact scoped payroll item in context and closes without losing the filter or focus', async () => {
  apiMocks.payPeriod.mockResolvedValue({ pay_period: { id: 2, company_id: 1, start_date: '2026-11-01', end_date: '2026-11-15', pay_date: '2026-11-30', status: 'committed', payroll_items: [baseItem] } });
  apiMocks.payrollItem.mockResolvedValue({ payroll_item: baseItem });
  apiMocks.employee.mockResolvedValue({ data: employee });
  function Harness() {
    const [open, setOpen] = useState(false);
    return <><input aria-label="Employee filter" defaultValue="Casey" /><button onClick={() => setOpen(true)}>Review Casey</button>
      <PayrollItemReviewDialog companyId={1} payRunId={2} item={open ? { id: 3, employee_name: 'Casey Employee' } : null} returnTo="/companies/1/pay-runs/2/work" onClose={() => setOpen(false)} /></>;
  }
  render(<MemoryRouter initialEntries={['/companies/1/pay-runs/2/work']}><Harness /></MemoryRouter>);
  const trigger = screen.getByRole('button', { name: 'Review Casey' }); trigger.focus(); fireEvent.click(trigger);
  expect(await screen.findByRole('dialog', { name: 'Casey Employee · Payroll details' })).toBeTruthy();
  await screen.findByText('Gross pay');
  expect(apiMocks.payrollItem).toHaveBeenCalledWith(2, 3, 1);
  expect(screen.getByRole('link', { name: 'Open full payroll record' }).getAttribute('href')).toContain('/companies/1/pay-runs/2/payroll-items/3');
  fireEvent.keyDown(document, { key: 'Escape' });
  expect(screen.queryByRole('dialog')).toBeNull();
  expect((screen.getByRole('textbox', { name: 'Employee filter' }) as HTMLInputElement).value).toBe('Casey');
  expect(document.activeElement).toBe(trigger);
  cleanup();
});
