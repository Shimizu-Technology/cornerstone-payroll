// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import userEvent from '@testing-library/user-event';
import type { TimeTrackingImportData, TimeTrackingPreviewRow } from '@/services/api';
import type { Employee, PayPeriod } from '@/types';
import { TimeTrackingImportModal } from './TimeTrackingImportModal';

const apiMocks = vi.hoisted(() => ({
  listSources: vi.fn(),
  preview: vi.fn(),
  apply: vi.fn(),
  reconcile: vi.fn(),
  correctionPreview: vi.fn(),
  correctionConfirm: vi.fn(),
  company: { activeCompany: null as { id: number; name: string } | null, companies: [] as Array<{ id: number; name: string }> },
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ isAdmin: true }),
}));

vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => apiMocks.company }));

vi.mock('react-router', async () => {
  const actual = await vi.importActual<typeof import('react-router')>('react-router');
  return { ...actual, useNavigate: () => vi.fn() };
});

vi.mock('@/services/api', () => ({
  ApiError: class ApiError extends Error {
    data?: unknown;
  },
  timeTrackingSourcesApi: { list: apiMocks.listSources },
  payPeriodsApi: { previewTimeTrackingCorrection: apiMocks.correctionPreview, confirmTimeTrackingCorrection: apiMocks.correctionConfirm, previewTimeTrackingImport: apiMocks.preview, applyTimeTrackingImport: apiMocks.apply, reconcileTimeTrackingImport: apiMocks.reconcile },
}));

const payPeriod = {
  id: 17,
  company_id: 3,
  start_date: '2026-10-01',
  end_date: '2026-10-15',
  pay_date: '2026-10-31',
  status: 'draft',
  run_purpose: 'regular',
  includes_base_salary: true,
  includes_recurring_items: true,
} as PayPeriod;

const source = {
  id: 12,
  company_id: 3,
  name: 'time tracking Services',
  source_type: 'aire_services' as const,
  base_url: 'https://aire.example.com',
  active: true,
  shared_secret_configured: true,
  delegation_token_configured: true,
  last_synced_at: null,
};

const otherSource = {
  ...source,
  id: 8,
  name: 'Field Time Clock',
  source_type: 'custom' as const,
};

beforeEach(() => {
  vi.clearAllMocks();
  apiMocks.company.activeCompany = { id: 3, name: 'Mosa Restaurant' };
  apiMocks.company.companies = [];
  apiMocks.listSources.mockResolvedValue({ time_tracking_sources: [source] });
  apiMocks.preview.mockResolvedValue({
    import: {
      id: 99,
      status: 'previewed',
      time_tracking_source_id: source.id,
      source_name: source.name,
      start_date: payPeriod.start_date,
      end_date: payPeriod.end_date,
      fetch_start_date: payPeriod.start_date,
      fetch_end_date: payPeriod.end_date,
      warnings: [],
      processed_payload: {
        ready: true,
        rows: [],
        exclusions: [],
        validation_version: 'payroll_batch_v2',
        summary: { total_hours: 72.5 },
        issues: {},
      },
      external_batch_id: 'time tracking-PAY-17',
      external_batch_checksum: 'checksum',
      contract_version: 'payroll_batch_v2',
      source_cutoff_at: '2026-10-23T00:00:00+10:00',
      applied_at: null,
      source_processing_status: null,
      source_processing_synced_at: null,
      source_processing_sync_error: null,
    },
  });
});

afterEach(() => cleanup());

describe('TimeTrackingImportModal guided time tracking review', () => {
  it('opens the configured time tracking batch directly in review', async () => {
    render(
      <TimeTrackingImportModal
        open
        onClose={vi.fn()}
        payPeriod={payPeriod}
        employees={[]}
        onImportComplete={vi.fn()}
        initialSourceId={source.id}
        autoPreview
      />
    );

    await waitFor(() => expect(apiMocks.preview).toHaveBeenCalledWith(payPeriod.id, {
      source_id: source.id,
      start_date: payPeriod.start_date,
      end_date: payPeriod.end_date,
    }));
    expect(await screen.findByText('Review time tracking hours')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Retrieve Finalized Batch' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Add time tracking Hours to Payroll' })).toBeTruthy();
  });

  it('keeps the first configured provider for the general import action', async () => {
    apiMocks.listSources.mockResolvedValue({ time_tracking_sources: [otherSource, source] });

    render(
      <TimeTrackingImportModal
        open
        onClose={vi.fn()}
        payPeriod={payPeriod}
        employees={[]}
        onImportComplete={vi.fn()}
      />
    );

    expect(await screen.findByText('Field Time Clock')).toBeTruthy();
    expect(apiMocks.preview).not.toHaveBeenCalled();
    screen.getByRole('button', { name: 'Fetch Hours' }).click();

    await waitFor(() => expect(apiMocks.preview).toHaveBeenCalledWith(payPeriod.id, {
      source_id: otherSource.id,
      start_date: payPeriod.start_date,
      end_date: payPeriod.end_date,
    }));
  });
});

const employee: Employee = {
  id: 7, company_id: 3, first_name: 'Test', last_name: 'Direct', employment_type: 'hourly',
  wage_rates: [{ id: 22, label: 'Regular', rate: 25, is_primary: true, active: true }],
  pay_rate: 25, pay_frequency: 'semimonthly', filing_status: 'single', allowances: 0,
  additional_withholding: 0, w4_dependent_credit: 0, w4_step2_multiple_jobs: false,
  w4_step4a_other_income: 0, w4_step4b_deductions: 0, w4_form_version: 2020,
  retirement_rate: 0, roth_retirement_rate: 0, status: 'active',
  created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z',
};

const row: TimeTrackingPreviewRow = {
  source_user_id: 'user-7', source_email: 'test@example.test', source_display_name: 'Test Direct',
  employee_id: employee.id, employee_name: 'Test Direct', match_method: 'saved_mapping', match_score: 100,
  regular_hours: 14, overtime_hours: 0, total_hours: 14, estimated_gross_delta: 350,
  categories: [{ source_category_id: 'regular', key: 'regular', name: 'Regular', regular_hours: 14, overtime_hours: 0, total_hours: 14, employee_wage_rate_id: 22 }],
  issues: {}, warnings: [], ready: true,
};

async function review(overrides: Partial<TimeTrackingImportData['processed_payload']> = {}, period = payPeriod, reviewEmployees = [employee]) {
  const response = await apiMocks.preview();
  const data: TimeTrackingImportData = {
    ...response.import,
    external_batch_checksum: 'a'.repeat(64),
    processed_payload: { ...response.import.processed_payload, rows: [row], finalized_at: '2026-10-23T00:00:01+10:00', ...overrides },
  };
  apiMocks.preview.mockResolvedValue({ import: data });
  apiMocks.preview.mockClear();
  const onImportComplete = vi.fn();
  render(<TimeTrackingImportModal open onClose={vi.fn()} payPeriod={period} employees={reviewEmployees} onImportComplete={onImportComplete} initialSourceId={source.id} autoPreview />);
  await screen.findByText('Test Direct', { selector: 'h3' });
  return { data, onImportComplete };
}

describe('TimeTrackingImportModal payroll-first review', () => {
  it('leads with payroll context, payable hours and held entries while audit details start collapsed', async () => {
    await review({ exclusions: [{ source_time_entry_id: 'held-1', source_user_id: 'user-7', display_name: 'Test Direct', reason: 'pending_approval', original_work_date: '2026-10-02', held_total_hours: 4, held_regular_hours: 4, held_overtime_hours: 0 }] });
    expect(screen.getByText('Mosa Restaurant')).toBeTruthy();
    expect(screen.getByText('Work period: Oct 1 - 15, 2026')).toBeTruthy();
    expect(screen.getByText('Pay date: Oct 31, 2026')).toBeTruthy();
    expect(screen.getByText('Verified cutoff:')).toBeTruthy();
    const summary = screen.getByRole('region', { name: 'Hours included in this review' });
    expect(within(summary).getByText('14.00')).toBeTruthy();
    expect(within(summary).getByText('0.00')).toBeTruthy();
    expect(screen.getByText('$350.00')).toBeTruthy();
    expect(screen.getByText('1 held entry · 4.00 held hours at cutoff.')).toBeTruthy();
    expect(screen.getByText('Pending Approval')).toBeTruthy();
    const disclosure = screen.getByText('Batch audit details').closest('details')!;
    expect(disclosure.open).toBe(false);
    expect(screen.getByText('a'.repeat(64)).className).toContain('break-all');
    expect(within(disclosure).getByText('time tracking-PAY-17')).toBeTruthy();
    expect(within(disclosure).getByText('payroll_batch_v2')).toBeTruthy();
    expect(summary.compareDocumentPosition(disclosure) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    await userEvent.click(screen.getByText('Batch audit details'));
    expect(disclosure.open).toBe(true);
  });

  it.each(['pending_payment_attestation', 'payment_attested_pending_evidence'])(
    'describes %s neutrally and keeps its held hours out of the apply payload',
    async (reason) => {
      const { data } = await review({ exclusions: [{
        source_time_entry_id: 'reported-paid-entry', source_user_id: 'reported-paid-user',
        display_name: 'Reported Paid Employee', reason, original_work_date: '2026-10-03',
        held_total_hours: 8.08, held_regular_hours: 8.08, held_overtime_hours: 0,
      }] });
      const dialog = screen.getByRole('dialog');
      expect(dialog.textContent).not.toMatch(/unpaid|owed|repayment/i);
      expect(screen.getByText('1 held entry · 8.08 held hours at cutoff.')).toBeTruthy();
      expect(screen.getByText('8.08 held hours at cutoff')).toBeTruthy();
      expect(screen.getByText(reason.replaceAll('_', ' ').replace(/\b\w/g, (letter) => letter.toUpperCase()))).toBeTruthy();
      expect(within(screen.getByRole('region', { name: 'Hours included in this review' })).getByText('14.00')).toBeTruthy();
      apiMocks.apply.mockResolvedValue({ import: { ...data, status: 'applied' }, results: { applied: [{}], skipped: [], errors: [] } });
      await userEvent.click(screen.getByRole('button', { name: 'Add time tracking Hours to Payroll' }));
      expect(apiMocks.apply).toHaveBeenCalledOnce();
      const submitted = apiMocks.apply.mock.calls[0][1];
      expect(submitted.mappings).toHaveLength(1);
      expect(submitted.mappings.map((mapping: { source_user_id: string }) => mapping.source_user_id)).toEqual(['user-7']);
      expect(JSON.stringify(submitted)).not.toContain('reported-paid');
    },
  );

  it('uses the pay period client instead of a mismatched active company, with a readable fallback', async () => {
    apiMocks.company.activeCompany = { id: 9, name: 'Wrong Client' };
    apiMocks.company.companies = [{ id: 3, name: 'Mosa Restaurant' }];
    await review();
    expect(screen.getByText('Mosa Restaurant')).toBeTruthy();
    expect(screen.queryByText('Wrong Client')).toBeNull();
    cleanup();
    apiMocks.company.companies = [];
    await review();
    expect(screen.getByText('Client #3')).toBeTruthy();
    expect(screen.queryByText('Wrong Client')).toBeNull();
  });

  it('keeps audit disclosure and mapping controls in the dialog keyboard loop', async () => {
    await review();
    const disclosure = screen.getByText('Batch audit details');
    const employeeSelect = screen.getByRole('combobox', { name: /^Payroll employee/ });
    const close = screen.getByRole('button', { name: 'Close' });
    expect(document.activeElement).toBe(close);
    await userEvent.tab();
    expect(document.activeElement).toBe(employeeSelect);
    await userEvent.tab();
    expect(document.activeElement).toBe(screen.getByRole('combobox', { name: 'Payroll earning type' }));
    await userEvent.tab();
    expect(document.activeElement).toBe(disclosure);
    await userEvent.tab();
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Back' }));
    await userEvent.tab();
    await userEvent.tab();
    expect(document.activeElement).toBe(close);
  });

  it('preserves finalized mappings and the apply payload', async () => {
    const { data, onImportComplete } = await review();
    apiMocks.apply.mockResolvedValue({ import: { ...data, status: 'applied' }, results: { applied: [{}], skipped: [], errors: [] } });
    await userEvent.click(screen.getByRole('button', { name: 'Add time tracking Hours to Payroll' }));
    expect(apiMocks.apply).toHaveBeenCalledWith(17, {
      import_id: 99, acknowledge_negative_adjustments: false, negative_adjustment_note: '',
      mappings: [{ source_user_id: 'user-7', employee_id: 7, include: true, wage_rate_mappings: [{ source_category_id: 'regular', source_category_key: 'regular', source_category_name: 'Regular', source_kind: null, employee_wage_rate_id: 22 }] }],
    });
    expect(onImportComplete).toHaveBeenCalledOnce();
  });

  it('continues to block missing employee and earning mappings', async () => {
    await review({ rows: [{ ...row, employee_id: null }] });
    const apply = screen.getByRole('button', { name: 'Add time tracking Hours to Payroll' });
    expect((apply as HTMLButtonElement).disabled).toBe(true);
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /^Payroll employee/ }), '7');
    expect((apply as HTMLButtonElement).disabled).toBe(false);
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Payroll earning type' }), '');
    expect((apply as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText('Earning type mapping required')).toBeTruthy();
  });

  it('continues to require confirmation and a meaningful note for negative adjustments', async () => {
    await review({ negative_adjustment_count: 1 });
    const apply = screen.getByRole('button', { name: 'Add time tracking Hours to Payroll' }) as HTMLButtonElement;
    expect(apply.disabled).toBe(true);
    await userEvent.click(screen.getByRole('checkbox', { name: 'I reviewed the negative corrections and their replacement lines.' }));
    expect(apply.disabled).toBe(true);
    await userEvent.type(screen.getByRole('textbox', { name: 'Review note' }), 'Verified replacement lines');
    expect(apply.disabled).toBe(false);
  });

  it('keeps historical reconciliation read-only and requires the audit note', async () => {
    const { data } = await review({}, { ...payPeriod, status: 'committed' });
    const link = screen.getByRole('button', { name: 'Verify & Link time tracking Record' }) as HTMLButtonElement;
    expect(link.disabled).toBe(true);
    expect(screen.getByText('Link the committed payroll to this cutoff. Pay will stay unchanged.')).toBeTruthy();
    expect(screen.queryByText('$350.00')).toBeNull();
    expect(screen.queryByRole('combobox', { name: 'Payroll earning type' })).toBeNull();
    await userEvent.type(screen.getByRole('textbox', { name: 'Audit note' }), 'Compared committed hours');
    expect(link.disabled).toBe(false);
    apiMocks.reconcile.mockResolvedValue({ data: { import: { ...data, status: 'applied' }, results: { reconciled: [{}], rounding_exceptions: [], errors: [] } } });
    await userEvent.click(link);
    expect(apiMocks.reconcile).toHaveBeenCalledWith(17, { import_id: 99, reconciliation_note: 'Compared committed hours', mappings: [{ source_user_id: 'user-7', employee_id: 7 }] });
    expect(apiMocks.apply).not.toHaveBeenCalled();
  });

  it('preserves legacy row skipping and updates the included hours summary', async () => {
    await review({ validation_version: 'time_summary_v1' });
    expect(screen.queryByText('Batch audit details')).toBeNull();
    const summary = screen.getByRole('region', { name: 'Hours included in this review' });
    expect(within(summary).getByText('14.00')).toBeTruthy();
    await userEvent.click(screen.getByRole('checkbox', { name: 'Include' }));
    expect(within(summary).queryByText('14.00')).toBeNull();
    expect(screen.getByRole('button', { name: 'Apply Import' }).hasAttribute('disabled')).toBe(true);
  });
});


it('requires explicit accounting review and acknowledgment before resolving a negative source line', async () => {
  const user = userEvent.setup();
  const line = { source_user_id: '42', source_time_entry_id: '101', line_key: '7:2500', regular_hours: -1, overtime_hours: 0, total_hours: -1 };
  apiMocks.preview.mockResolvedValue({ import: { id: 99, status: 'previewed', correction_lines: [line], processed_payload: { rows: [], validation_version: 'payroll_batch_v2', negative_adjustment_count: 1 } } });
  apiMocks.correctionPreview.mockResolvedValue({ correction: { ...line, preview_token: 'signed-proof', source_change: line, employee_name: 'Pilot One', original_pay_period_id: 10, original_payroll_item_id: 11, original_check_number: '30000', pay_date: '2026-11-15', original: { gross_pay: 100, net_pay: 92.35 }, corrected: { gross_pay: 75, net_pay: 69.26 }, deltas: { gross_pay: -25, net_pay: -23.09, social_security_tax: -1.55, medicare_tax: -0.36, withholding_tax: 0 }, accounting_only: true } });
  apiMocks.correctionConfirm.mockResolvedValue({ disposition_id: 1, import: { id: 99, status: 'previewed', correction_lines: [line], correction_dispositions: [{ ...line, id: 1, corrective_pay_period_id: 100, corrective_payroll_item_id: 101, accounting_only: true }], processed_payload: { rows: [], validation_version: 'payroll_batch_v2', negative_adjustment_count: 0 } } });
  render(<TimeTrackingImportModal open onClose={() => {}} payPeriod={payPeriod} employees={[]} onImportComplete={() => {}} autoPreview />);
  await user.click(await screen.findByRole('button', { name: 'Review correction' }));
  expect(await screen.findByText(/original check 30000/)).toBeTruthy();
  const confirm = screen.getByRole('button', { name: 'Confirm accounting correction' });
  expect(confirm.hasAttribute('disabled')).toBe(true);
  await user.type(screen.getByRole('textbox', { name: 'Reason' }), 'Approved source correction');
  expect(confirm.hasAttribute('disabled')).toBe(true);
  await user.click(screen.getByRole('checkbox', { name: /I reviewed the signed adjustment/ }));
  await user.click(confirm);
  await waitFor(() => expect(apiMocks.correctionConfirm).toHaveBeenCalledWith(17, { import_id: 99, ...{ source_user_id: line.source_user_id, source_time_entry_id: line.source_time_entry_id, line_key: line.line_key }, preview_token: 'signed-proof', reason: 'Approved source correction', acknowledge_accounting_only: true }));
  expect(await screen.findByText(/Accounting correction committed in supplemental #100/)).toBeTruthy();
});
