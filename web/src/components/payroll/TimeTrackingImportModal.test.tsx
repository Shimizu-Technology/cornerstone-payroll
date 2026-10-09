// @vitest-environment jsdom

import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react';
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
  correctionDelivery: vi.fn(),
  correctionRetry: vi.fn(),
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
  payPeriodsApi: { previewTimeTrackingCorrection: apiMocks.correctionPreview, confirmTimeTrackingCorrection: apiMocks.correctionConfirm, timeTrackingCorrectionDelivery: apiMocks.correctionDelivery, retryTimeTrackingCorrectionDelivery: apiMocks.correctionRetry, previewTimeTrackingImport: apiMocks.preview, applyTimeTrackingImport: apiMocks.apply, reconcileTimeTrackingImport: apiMocks.reconcile },
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
  vi.resetAllMocks();
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
  expect(await screen.findByText(/Recorded in Payroll supplemental #100/)).toBeTruthy();
});


describe('correction request scopes', () => {
  const lineA = { source_user_id: '42', source_time_entry_id: '101', line_key: '7:2500', regular_hours: -1, overtime_hours: 0, total_hours: -1 };
  const lineB = { ...lineA, source_user_id: '84', source_time_entry_id: '202', line_key: '8:2500' };
  const detail = (name: string, line = lineA) => ({ ...line, preview_token: `proof-${name}`, source_change: line,
    employee_name: name, original_pay_period_id: 10, original_payroll_item_id: 11, original_check_number: '30000',
    pay_date: '2026-11-15', original: { gross_pay: 100, net_pay: 92.35 }, corrected: { gross_pay: 75, net_pay: 69.26 },
    deltas: { gross_pay: -25, net_pay: -23.09, social_security_tax: -1.55, medicare_tax: -0.36, withholding_tax: 0 }, accounting_only: true });
  const importFor = (id: number, line = lineA, sourceId = source.id) => ({ id, status: 'previewed', time_tracking_source_id: sourceId,
    correction_lines: [line], processed_payload: { rows: [], validation_version: 'payroll_batch_v2', negative_adjustment_count: 1 } });
  const committed = (id: number, line = lineA) => ({ disposition_id: id,
    import: { ...importFor(id, line), correction_dispositions: [{ ...line, id, corrective_pay_period_id: id,
      corrective_payroll_item_id: id + 1, accounting_only: true }], processed_payload: { rows: [], validation_version: 'payroll_batch_v2', negative_adjustment_count: 0 } } });
  function deferred<T>() {
    let resolve!: (value: T) => void;
    let reject!: (reason: Error) => void;
    const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
    return { promise, resolve, reject };
  }
  const acknowledge = async (user: ReturnType<typeof userEvent.setup>) => {
    await user.type(screen.getByRole('textbox', { name: 'Reason' }), 'Reviewed exact source accounting correction');
    await user.click(screen.getByRole('checkbox', { name: /I reviewed the signed adjustment/ }));
  };

  it.each(['period', 'company', 'source', 'close'])('ignores a late correction preview after %s changes without replacing the current person or clearing current busy state', async (change) => {
    const user = userEvent.setup();
    const old = deferred<{ correction: ReturnType<typeof detail> }>();
    const current = deferred<{ correction: ReturnType<typeof detail> }>();
    const onCorrectionRecorded = vi.fn();
    apiMocks.preview.mockResolvedValue({ import: importFor(99) });
    apiMocks.correctionPreview.mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise);
    const props = { open: true, onClose: vi.fn(), payPeriod, employees: [], onImportComplete: vi.fn(), onCorrectionRecorded, autoPreview: true };
    const view = render(<TimeTrackingImportModal {...props} />);
    await user.click(await screen.findByRole('button', { name: 'Review correction' }));
    let nextProps = props;
    let sourceB = source;
    if (change === 'period') nextProps = { ...props, payPeriod: { ...payPeriod, id: 18 } };
    if (change === 'company') {
      apiMocks.company.activeCompany = { id: 4, name: 'Current client B' };
      sourceB = { ...source, id: 22, company_id: 4 };
      nextProps = { ...props, payPeriod: { ...payPeriod, id: 18, company_id: 4 } };
    }
    if (change === 'source') sourceB = { ...source, id: 22 };
    apiMocks.listSources.mockResolvedValue({ time_tracking_sources: [sourceB] });
    apiMocks.preview.mockResolvedValue({ import: importFor(199, lineB, sourceB.id) });
    if (change === 'close') view.rerender(<TimeTrackingImportModal {...props} open={false} />);
    view.rerender(<TimeTrackingImportModal {...nextProps} initialSourceId={sourceB.id} />);
    await waitFor(() => expect(apiMocks.preview).toHaveBeenCalledTimes(2));
    await user.click(await screen.findByRole('button', { name: 'Review correction' }));
    await act(async () => old.resolve({ correction: detail('Old person A') }));
    expect(screen.queryByText(/Old person A/)).toBeNull();
    expect((screen.getByRole('button', { name: 'Review correction' }) as HTMLButtonElement).disabled).toBe(true);
    await act(async () => current.resolve({ correction: detail('Current person B', lineB) }));
    expect(await screen.findByText(/Current person B/)).toBeTruthy();
    expect(screen.queryByText(/Old person A/)).toBeNull();
    expect(onCorrectionRecorded).not.toHaveBeenCalled();
  });

  it.each(['period', 'company', 'close'])('ignores a late confirm after %s changes and reports only the current accounting posting', async (change) => {
    const user = userEvent.setup();
    const old = deferred<ReturnType<typeof committed>>();
    const current = deferred<ReturnType<typeof committed>>();
    const onCorrectionRecorded = vi.fn();
    const onImportComplete = vi.fn();
    apiMocks.preview.mockResolvedValue({ import: importFor(99) });
    apiMocks.correctionPreview.mockResolvedValue({ correction: detail('Old person A') });
    apiMocks.correctionConfirm.mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise);
    const props = { open: true, onClose: vi.fn(), payPeriod, employees: [], onImportComplete, onCorrectionRecorded, autoPreview: true };
    const view = render(<TimeTrackingImportModal {...props} />);
    await user.click(await screen.findByRole('button', { name: 'Review correction' }));
    await screen.findByText(/Old person A/);
    await acknowledge(user);
    await user.click(screen.getByRole('button', { name: 'Confirm accounting correction' }));
    let nextProps = { ...props, payPeriod: { ...payPeriod, id: change === 'close' ? 17 : 18 } };
    let sourceB = source;
    if (change === 'company') {
      apiMocks.company.activeCompany = { id: 4, name: 'Current client B' };
      sourceB = { ...source, id: 22, company_id: 4 };
      nextProps = { ...props, payPeriod: { ...payPeriod, id: 18, company_id: 4 } };
    }
    apiMocks.listSources.mockResolvedValue({ time_tracking_sources: [sourceB] });
    apiMocks.preview.mockResolvedValue({ import: importFor(199, lineB, sourceB.id) });
    apiMocks.correctionPreview.mockResolvedValue({ correction: detail('Current person B', lineB) });
    if (change === 'close') view.rerender(<TimeTrackingImportModal {...props} open={false} />);
    view.rerender(<TimeTrackingImportModal {...nextProps} />);
    await waitFor(() => expect(apiMocks.preview).toHaveBeenCalledTimes(2));
    await user.click(await screen.findByRole('button', { name: 'Review correction' }));
    await screen.findByText(/Current person B/);
    await acknowledge(user);
    await user.click(screen.getByRole('button', { name: 'Confirm accounting correction' }));
    await act(async () => old.resolve(committed(100)));
    expect(screen.queryByText(/supplemental #100/)).toBeNull();
    expect((screen.getByRole('button', { name: 'Confirm accounting correction' }) as HTMLButtonElement).disabled).toBe(true);
    expect(onCorrectionRecorded).not.toHaveBeenCalled();
    await act(async () => current.resolve(committed(200, lineB)));
    expect(await screen.findByText(/supplemental #200/)).toBeTruthy();
    expect(screen.queryByText(/supplemental #100/)).toBeNull();
    expect(onCorrectionRecorded).toHaveBeenCalledOnce();
    expect(onImportComplete).not.toHaveBeenCalled();
  });

  it('drops stale preview errors after closing instead of surfacing them in the reopened review', async () => {
    const user = userEvent.setup();
    const old = deferred<{ correction: ReturnType<typeof detail> }>();
    apiMocks.preview.mockResolvedValue({ import: importFor(99) });
    apiMocks.correctionPreview.mockReturnValue(old.promise);
    const props = { open: true, onClose: vi.fn(), payPeriod, employees: [], onImportComplete: vi.fn(), autoPreview: true };
    const view = render(<TimeTrackingImportModal {...props} />);
    await user.click(await screen.findByRole('button', { name: 'Review correction' }));
    view.rerender(<TimeTrackingImportModal {...props} open={false} />);
    view.rerender(<TimeTrackingImportModal {...props} />);
    await waitFor(() => expect(apiMocks.preview).toHaveBeenCalledTimes(2));
    await act(async () => old.reject(new Error('Old tenant A correction failed')));
    expect(screen.queryByText('Old tenant A correction failed')).toBeNull();
    expect((screen.getByRole('button', { name: 'Review correction' }) as HTMLButtonElement).disabled).toBe(false);
  });
});


describe('accounting posting and source delivery are separate', () => {
  const line = { source_user_id: '42', source_time_entry_id: '101', line_key: '7:2500', regular_hours: -1, overtime_hours: 0, total_hours: -1 };
  const receipt = (status: 'pending' | 'error' | 'confirmed') => ({ id: 1, event_id: 'same-immutable-event', status,
    queued_at: '2026-10-31T00:00:00Z', confirmed_at: status === 'confirmed' ? '2026-10-31T00:01:00Z' : null,
    error: status === 'error' ? 'Exact source acknowledgment could not be verified' : null, can_retry: status === 'error' });
  const disposition = (status: 'pending' | 'error' | 'confirmed', id = 1) => ({ ...line, id,
    corrective_pay_period_id: 100 + id, corrective_payroll_item_id: 200 + id, accounting_only: true, source_receipt: receipt(status) });
  const importData = (status: 'pending' | 'error' | 'confirmed', id = 99, dispositionId = 1) => ({ id, status: 'previewed', time_tracking_source_id: source.id,
    correction_lines: [line], correction_dispositions: [disposition(status, dispositionId)],
    processed_payload: { rows: [], validation_version: 'payroll_batch_v2', negative_adjustment_count: 0 } });

  it('shows proof drift as needs review rather than resolving an old confirmed receipt', async () => {
    apiMocks.preview.mockResolvedValue({ import: { ...importData('confirmed'), correction_dispositions: [{ ...disposition('confirmed'),
      verification_status: 'needs_review', verification_error: 'Source installation changed', source_receipt: { ...receipt('confirmed'), can_retry: false } }] } });
    render(<TimeTrackingImportModal open payPeriod={payPeriod} employees={[]} onClose={vi.fn()} onImportComplete={vi.fn()} autoPreview />);
    await screen.findByText('Source installation changed');
    expect(screen.queryByText(/Source confirmation verified/)).toBeNull();
    expect(screen.queryByRole('button', { name: 'Retry source confirmation' })).toBeNull();
    expect(apiMocks.correctionConfirm).not.toHaveBeenCalled();
  });

  it('shows an already posted accounting correction pending/error/verified, and retries only its receipt', async () => {
    const user = userEvent.setup();
    const onCorrectionRecorded = vi.fn();
    const onImportComplete = vi.fn();
    apiMocks.preview.mockResolvedValue({ import: { ...importData('pending'), correction_dispositions: [], processed_payload: { rows: [], validation_version: 'payroll_batch_v2', negative_adjustment_count: 1 } } });
    apiMocks.correctionPreview.mockResolvedValue({ correction: { ...line, source_change: line, preview_token: 'verified-original-proof',
      employee_name: 'Pilot One', original_pay_period_id: 10, original_payroll_item_id: 11, original_check_number: '30000', pay_date: '2026-10-31',
      original: { gross_pay: 100, net_pay: 92.35 }, corrected: { gross_pay: 75, net_pay: 69.26 },
      deltas: { gross_pay: -25, net_pay: -23.09, social_security_tax: -1.55, medicare_tax: -0.36, withholding_tax: 0 }, accounting_only: true } });
    apiMocks.correctionConfirm.mockResolvedValue({ disposition_id: 1, import: importData('pending') });
    render(<TimeTrackingImportModal open onClose={vi.fn()} payPeriod={payPeriod} employees={[]} onImportComplete={onImportComplete} onCorrectionRecorded={onCorrectionRecorded} autoPreview />);
    await user.click(await screen.findByRole('button', { name: 'Review correction' }));
    await user.type(screen.getByRole('textbox', { name: 'Reason' }), 'Reviewed original source correction');
    await user.click(screen.getByRole('checkbox', { name: /I reviewed the signed adjustment/ }));
    await user.click(screen.getByRole('button', { name: 'Confirm accounting correction' }));
    expect(await screen.findByText(/Recorded in Payroll supplemental #101/)).toBeTruthy();
    expect(screen.getByText(/Source confirmation pending/)).toBeTruthy();
    expect(screen.queryByText(/Source confirmation verified/)).toBeNull();
    expect(screen.getByText(/No new payment or recovery recorded/)).toBeTruthy();
    apiMocks.correctionDelivery.mockResolvedValueOnce({ disposition: disposition('error') });
    await user.click(screen.getByRole('button', { name: 'Refresh source confirmation' }));
    expect(await screen.findByText('Source confirmation needs attention.')).toBeTruthy();
    expect(screen.getByText('Exact source acknowledgment could not be verified')).toBeTruthy();
    apiMocks.correctionRetry.mockResolvedValue({ disposition: disposition('pending') });
    await user.click(screen.getByRole('button', { name: 'Retry source confirmation' }));
    expect(await screen.findByText(/Source confirmation pending/)).toBeTruthy();
    apiMocks.correctionDelivery.mockResolvedValue({ disposition: disposition('confirmed') });
    await user.click(screen.getByRole('button', { name: 'Refresh source confirmation' }));
    expect(await screen.findByText(/Source confirmation verified/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Retry source confirmation' })).toBeNull();
    expect(apiMocks.correctionConfirm).toHaveBeenCalledOnce();
    expect(apiMocks.correctionRetry).toHaveBeenCalledWith(17, { import_id: 99, disposition_id: 1 });
    expect(apiMocks.apply).not.toHaveBeenCalled();
    expect(onImportComplete).not.toHaveBeenCalled();
    expect(onCorrectionRecorded).toHaveBeenCalledTimes(4);
  });

  it('preserves ordinary employee mappings when only source delivery metadata refreshes', async () => {
    const user = userEvent.setup();
    const second = { ...employee, id: 8, first_name: 'Other' };
    apiMocks.preview.mockResolvedValue({ import: { ...importData('error'), processed_payload: { rows: [{ ...row, categories: [] }], ready: true, validation_version: 'payroll_batch_v2', negative_adjustment_count: 0 } } });
    render(<TimeTrackingImportModal open onClose={vi.fn()} payPeriod={payPeriod} employees={[employee, second]} onImportComplete={vi.fn()} autoPreview />);
    const selection = await screen.findByRole('combobox', { name: /^Payroll employee/ });
    await user.selectOptions(selection, '8');
    apiMocks.correctionDelivery.mockResolvedValue({ disposition: disposition('confirmed') });
    await user.click(screen.getByRole('button', { name: 'Refresh source confirmation' }));
    await screen.findByText(/Source confirmation verified/);
    expect((selection as HTMLSelectElement).value).toBe('8');
    apiMocks.apply.mockResolvedValue({ results: { applied: [], skipped: [], errors: [] }, import: { ...importData('confirmed'), status: 'applied' } });
    await user.click(screen.getByRole('button', { name: 'Add time tracking Hours to Payroll' }));
    await waitFor(() => expect(apiMocks.apply).toHaveBeenCalled());
    expect(apiMocks.apply.mock.calls[0][1].mappings[0].employee_id).toBe(8);
    expect(apiMocks.correctionConfirm).not.toHaveBeenCalled();
  });

  it.each(['scope', 'close'])('ignores late delivery refresh after %s changes, including callbacks', async (change) => {
    const user = userEvent.setup();
    let resolve!: (value: { disposition: ReturnType<typeof disposition> }) => void;
    const pending = new Promise<{ disposition: ReturnType<typeof disposition> }>(yes => { resolve = yes; });
    apiMocks.preview.mockResolvedValue({ import: importData('pending') });
    apiMocks.correctionDelivery.mockReturnValue(pending);
    const onCorrectionRecorded = vi.fn();
    const props = { open: true, onClose: vi.fn(), payPeriod, employees: [], onImportComplete: vi.fn(), onCorrectionRecorded, autoPreview: true };
    const view = render(<TimeTrackingImportModal {...props} />);
    await user.click(await screen.findByRole('button', { name: 'Refresh source confirmation' }));
    apiMocks.preview.mockResolvedValue({ import: importData('pending', 199, 2) });
    if (change === 'close') view.rerender(<TimeTrackingImportModal {...props} open={false} />);
    view.rerender(<TimeTrackingImportModal {...props} payPeriod={change === 'scope' ? { ...payPeriod, id: 18 } : payPeriod} />);
    await waitFor(() => expect(apiMocks.preview).toHaveBeenCalledTimes(2));
    await screen.findByText(/Recorded in Payroll supplemental #102/);
    await act(async () => resolve({ disposition: disposition('confirmed') }));
    expect(screen.queryByText(/Source confirmation verified/)).toBeNull();
    expect(screen.queryByText(/supplemental #101/)).toBeNull();
    expect(onCorrectionRecorded).not.toHaveBeenCalled();
    expect(apiMocks.correctionConfirm).not.toHaveBeenCalled();
  });
});
