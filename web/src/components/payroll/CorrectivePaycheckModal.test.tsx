// @vitest-environment jsdom
import { act, cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CorrectivePaycheckModal } from './CorrectivePaycheckModal';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import type { CorrectivePaycheckPreview, CorrectivePaycheckSnapshot, PayPeriod, PayrollItem } from '@/types';

const api = vi.hoisted(() => ({ preview: vi.fn(), issue: vi.fn() }));
vi.mock('@/services/api', () => ({ payPeriodsApi: { correctivePaycheckPreview: api.preview, issueCorrectivePaycheck: api.issue } }));
afterEach(cleanup);
const snapshot = (hours: number, gross: number): CorrectivePaycheckSnapshot => ({
  gross_pay: gross, net_pay: gross * 0.8, hours_worked: hours, overtime_hours: 0, holiday_hours: 0, pto_hours: 0,
  bonus: 0, reported_tips: 0, tips_paid_out: 0, pay_rate: 15, withholding_tax: 0, social_security_tax: 0, medicare_tax: 0,
  employer_social_security_tax: 0, employer_medicare_tax: 0, additional_withholding: 0, retirement_payment: 0,
  roth_retirement_payment: 0, employer_retirement_match: 0, employer_roth_retirement_match: 0, total_additions: 0,
  total_deductions: 0, custom_earnings: [], custom_deductions: [], custom_columns_data: {},
});
const preview = (hours = 80): CorrectivePaycheckPreview => ({
  original: snapshot(60, 900), recorded: snapshot(80, 1200), corrected: snapshot(hours, hours * 15),
  deltas: { gross_pay: (hours - 80) * 15, net_pay: (hours - 80) * 12 },
  meta: { original_pay_period_id: 12, original_payroll_item_id: 31, employee_id: 19, employee_name: 'Casey',
    active_corrective_count: 1, review_digest: String(hours).padStart(64, '0'), will_generate_check: hours > 80, is_zero_change: hours === 80 },
});
const period = { id: 12, company_id: 6, start_date: '2024-01-01', end_date: '2024-01-14', pay_date: '2024-01-19', status: 'committed' } as PayPeriod;
const item = { id: 31, employee_id: 19, employee_name: 'Casey', employment_type: 'hourly', company_id: 6, pay_period_id: 12, ...snapshot(60, 900) } as PayrollItem;
function setup() {
  const onIssued = vi.fn();
  const onOpenChange = vi.fn();
  const view = render(<FeedbackProvider><CorrectivePaycheckModal open originalPayPeriod={period} originalItem={item}
    onIssued={onIssued} onOpenChange={onOpenChange} /></FeedbackProvider>);
  return { user: userEvent.setup(), onIssued, onOpenChange, view };
}
beforeEach(() => {
  vi.resetAllMocks();
  api.preview.mockImplementation((_period, request) => Promise.resolve(preview(request.corrected_inputs.hours_worked ?? 80)));
  api.issue.mockResolvedValue({ supplemental_pay_period: { id: 50 }, corrective_payroll_item: { id: 71 } });
});

describe('CorrectivePaycheckModal recorded baseline', () => {
  it('initializes absolute inputs from active corrections and shows recorded-to-target arrows with the frozen original separate', async () => {
    const { user, onIssued } = setup();
    const input = screen.getByLabelText('Regular hours') as HTMLInputElement;
    await waitFor(() => expect(input.value).toBe('80'));
    await user.clear(input); await user.type(input, '65');
    await screen.findByText(/Frozen original: gross \$900.00/);
    const gross = screen.getByText('Gross pay').parentElement!;
    expect(gross.textContent).toContain('$1,200.00');
    expect(gross.textContent).toContain('$975.00');
    expect(gross.textContent).toContain('-$225.00');
    expect(screen.getByText(/No check will be cut/).textContent).toContain('-$180.00');
    await user.type(screen.getByLabelText(/Reason/), 'Verified target is 65 hours');
    await user.click(screen.getByRole('button', { name: 'Issue corrective paycheck' }));
    expect(api.issue).toHaveBeenCalledWith(12, expect.objectContaining({ employee_id: 19, expected_review_digest: preview(65).meta.review_digest, corrected_inputs: expect.objectContaining({ hours_worked: 65 }) }));
    expect(onIssued).toHaveBeenCalledOnce();
  });

  it('does not offer another correction for the already recorded target', async () => {
    const { user } = setup();
    await waitFor(() => expect((screen.getByLabelText('Regular hours') as HTMLInputElement).value).toBe('80'));
    await user.type(screen.getByLabelText(/Reason/), 'Same recorded target');
    expect((screen.getByRole('button', { name: 'Issue corrective paycheck' }) as HTMLButtonElement).disabled).toBe(true);
    expect(api.issue).not.toHaveBeenCalled();
  });

  it('ignores an older preview and blocks issuing while the current target is still being verified', async () => {
    let resolveOld!: (value: CorrectivePaycheckPreview) => void;
    api.preview.mockImplementation((_period, request) => request.corrected_inputs.hours_worked === 65
      ? new Promise(resolve => { resolveOld = resolve; }) : Promise.resolve(preview(request.corrected_inputs.hours_worked ?? 80)));
    const { user } = setup();
    const input = screen.getByLabelText('Regular hours') as HTMLInputElement;
    await waitFor(() => expect(input.value).toBe('80'));
    await user.type(screen.getByLabelText(/Reason/), 'Verified target after earlier correction');
    await user.clear(input); await user.type(input, '65');
    await waitFor(() => expect(resolveOld).toBeTypeOf('function'));
    expect((screen.getByRole('button', { name: 'Issue corrective paycheck' }) as HTMLButtonElement).disabled).toBe(true);
    await user.clear(input); await user.type(input, '70');
    await screen.findByText(/Frozen original:/);
    await act(async () => resolveOld(preview(65)));
    expect(screen.getByText('Gross pay').parentElement!.textContent).toContain('$1,050.00');
    expect(screen.getByText('Gross pay').parentElement!.textContent).not.toContain('$975.00');
    await user.click(screen.getByRole('button', { name: 'Issue corrective paycheck' }));
    expect(api.issue).toHaveBeenCalledWith(12, expect.objectContaining({ corrected_inputs: expect.objectContaining({ hours_worked: 70 }) }));
  });

  it('fails closed when recorded history cannot be verified', async () => {
    api.preview.mockRejectedValue(new Error('Prior correction input history is missing; review the earlier corrective payroll'));
    setup();
    await screen.findByText(/Prior correction input history is missing/);
    expect((screen.getByLabelText('Regular hours') as HTMLInputElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: 'Issue corrective paycheck' }) as HTMLButtonElement).disabled).toBe(true);
    expect(api.issue).not.toHaveBeenCalled();
  });

  it('requires a fresh reviewed proof after another correction made confirmation stale', async () => {
    api.issue.mockRejectedValueOnce(new Error('The correction preview changed. Refresh and review the current remaining balance'));
    const { user } = setup();
    const input = screen.getByLabelText('Regular hours') as HTMLInputElement;
    await waitFor(() => expect(input.value).toBe('80'));
    await user.clear(input); await user.type(input, '65');
    await screen.findByText(/Frozen original:/);
    await user.type(screen.getByLabelText(/Reason/), 'Verified absolute target');
    await user.click(screen.getByRole('button', { name: 'Issue corrective paycheck' }));
    await screen.findByText(/correction preview changed/);
    expect((screen.getByRole('button', { name: 'Issue corrective paycheck' }) as HTMLButtonElement).disabled).toBe(true);
    const refreshed = { ...preview(65), recorded: snapshot(70, 1050), deltas: { gross_pay: -75, net_pay: -60 },
      meta: { ...preview(65).meta, review_digest: 'c'.repeat(64), active_corrective_count: 2 } };
    api.preview.mockResolvedValue(refreshed);
    await user.click(screen.getByRole('button', { name: 'Refresh correction preview' }));
    await waitFor(() => expect(screen.getByText('Gross pay').parentElement!.textContent).toContain('$1,050.00'));
    await user.click(screen.getByRole('button', { name: 'Issue corrective paycheck' }));
    expect(api.issue).toHaveBeenLastCalledWith(12, expect.objectContaining({ expected_review_digest: 'c'.repeat(64) }));
    expect(api.issue).toHaveBeenCalledTimes(2);
  });

  it('does not issue from a preview without a verified digest', async () => {
    api.preview.mockImplementation((_period, request) => Promise.resolve({ ...preview(request.corrected_inputs.hours_worked ?? 80),
      meta: { ...preview().meta, review_digest: undefined, is_zero_change: false } }));
    const { user } = setup();
    await screen.findByText(/A verified preview is required/);
    await user.type(screen.getByLabelText(/Reason/), 'Target verified without server proof');
    expect((screen.getByRole('button', { name: 'Issue corrective paycheck' }) as HTMLButtonElement).disabled).toBe(true);
    expect(api.issue).not.toHaveBeenCalled();
  });

  it('can retry a failed baseline read without restoring frozen values over prior corrections', async () => {
    api.preview.mockRejectedValueOnce(new Error('Connection unavailable'));
    const { user } = setup();
    await screen.findByText('Connection unavailable');
    await user.click(screen.getByRole('button', { name: 'Refresh correction preview' }));
    await waitFor(() => expect((screen.getByLabelText('Regular hours') as HTMLInputElement).value).toBe('80'));
    expect(api.preview).toHaveBeenLastCalledWith(12, { employee_id: 19, corrected_inputs: {} });
    expect(api.issue).not.toHaveBeenCalled();
  });
});
