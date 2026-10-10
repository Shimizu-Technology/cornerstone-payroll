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
function setup(originalItem = item) {
  const onIssued = vi.fn();
  const onOpenChange = vi.fn();
  const view = render(<FeedbackProvider><CorrectivePaycheckModal open originalPayPeriod={period} originalItem={originalItem}
    onIssued={onIssued} onOpenChange={onOpenChange} /></FeedbackProvider>);
  return { user: userEvent.setup(), onIssued, onOpenChange, view };
}
beforeEach(() => {
  vi.resetAllMocks();
  api.preview.mockImplementation((_period, request) => Promise.resolve(preview(request.corrected_inputs.hours_worked ?? 80)));
  api.issue.mockResolvedValue({ supplemental_pay_period: { id: 50 }, corrective_payroll_item: { id: 71 } });
});

describe('CorrectivePaycheckModal recorded baseline', () => {
  function mockSignedBaseline() {
    api.preview.mockImplementation((_period, request) => {
      const hours = request.corrected_inputs.hours_worked;
      if (hours === undefined) return Promise.reject(new Error('The corrected absolute hours must be nonnegative'));
      return Promise.resolve({ ...preview(hours), original: snapshot(10, 150), recorded: snapshot(-9, -135),
        corrected: snapshot(hours, hours * 15), deltas: { gross_pay: (hours + 9) * 15, net_pay: (hours + 9) * 12 },
        meta: { ...preview(hours).meta, review_digest: String(hours).padStart(64, 'd'), will_generate_check: true, is_zero_change: false } });
    });
  }

  it('opens a signed recorded balance with original hour targets, then issues only a freshly reviewed edited target', async () => {
    mockSignedBaseline();
    const { user, onIssued } = setup({ ...item, ...snapshot(10, 150) });
    const input = screen.getByLabelText('Regular hours') as HTMLInputElement;
    await waitFor(() => expect(input.value).toBe('10'));
    await waitFor(() => expect(input.disabled).toBe(false));
    await screen.findByText(/Review the desired absolute hours/);
    expect(api.preview).toHaveBeenCalledWith(12, { employee_id: 19, corrected_inputs: { hours_worked: 10, overtime_hours: 0, holiday_hours: 0, pto_hours: 0 } });
    await user.clear(input); await user.type(input, '1');
    await waitFor(() => expect(screen.getByText('Gross pay').parentElement!.textContent).toContain('$15.00'));
    expect(screen.getByText('Gross pay').parentElement!.textContent).toContain('-$135.00');
    await user.type(screen.getByLabelText(/Reason/), 'Review final absolute one hour');
    await user.click(screen.getByRole('button', { name: 'Issue corrective paycheck' }));
    expect(api.issue).toHaveBeenCalledWith(12, expect.objectContaining({ expected_review_digest: 'd'.repeat(63) + '1',
      corrected_inputs: expect.objectContaining({ hours_worked: 1 }) }));
    expect(onIssued).toHaveBeenCalledOnce();
  });

  it('retries and reopens signed history without carrying an earlier edited target or issuing it', async () => {
    mockSignedBaseline();
    api.preview.mockRejectedValueOnce(new Error('Connection unavailable'));
    const originalItem = { ...item, ...snapshot(10, 150) };
    const { user, view, onIssued, onOpenChange } = setup(originalItem);
    await screen.findByText('Connection unavailable');
    await user.click(screen.getByRole('button', { name: 'Refresh correction preview' }));
    const input = screen.getByLabelText('Regular hours') as HTMLInputElement;
    await waitFor(() => expect(input.disabled).toBe(false));
    expect(input.value).toBe('10');
    await user.clear(input); await user.type(input, '1');
    const modal = (open: boolean) => <FeedbackProvider><CorrectivePaycheckModal open={open} originalPayPeriod={period} originalItem={originalItem}
      onIssued={onIssued} onOpenChange={onOpenChange} /></FeedbackProvider>;
    view.rerender(modal(false));
    view.rerender(modal(true));
    await waitFor(() => expect((screen.getByLabelText('Regular hours') as HTMLInputElement).disabled).toBe(false));
    expect((screen.getByLabelText('Regular hours') as HTMLInputElement).value).toBe('10');
    expect(api.issue).not.toHaveBeenCalled();
  });

  it('keeps a nonnegative latest recorded baseline at twenty rather than prefilling the original ten', async () => {
    api.preview.mockResolvedValue({ ...preview(20), original: snapshot(10, 150), recorded: snapshot(20, 300),
      corrected: snapshot(20, 300), deltas: { gross_pay: 0, net_pay: 0 }, meta: { ...preview(20).meta, is_zero_change: true } });
    const { user } = setup({ ...item, ...snapshot(10, 150) });
    await waitFor(() => expect((screen.getByLabelText('Regular hours') as HTMLInputElement).value).toBe('20'));
    await user.type(screen.getByLabelText(/Reason/), 'Review the current twenty hours');
    expect(api.preview).toHaveBeenCalledOnce();
    expect(api.preview).toHaveBeenCalledWith(12, { employee_id: 19, corrected_inputs: {} });
    expect(screen.queryByText(/Review the desired absolute hours/)).toBeNull();
    expect((screen.getByRole('button', { name: 'Issue corrective paycheck' }) as HTMLButtonElement).disabled).toBe(true);
    expect(api.issue).not.toHaveBeenCalled();
  });

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
    expect(api.preview).toHaveBeenCalledOnce();
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


it.each([['Regular hours', '7.333', '7.33', 'hours_worked'], ['Bonus', '1.005', '1.01', 'bonus']] as const)(
  'explains excessive precision for %s and submits only the explicitly reviewed two-decimal value', async (label, invalid, valid, field) => {
    api.preview.mockImplementation((_period, request) => {
      const inputs = request.corrected_inputs;
      return Promise.resolve({ ...preview(inputs.hours_worked ?? 80), corrected: { ...preview(inputs.hours_worked ?? 80).corrected, ...inputs },
        meta: { ...preview().meta, review_digest: 'a'.repeat(64), is_zero_change: Object.keys(inputs).length === 0 } });
    });
    const { user } = setup();
    const input = screen.getByLabelText(label) as HTMLInputElement;
    await waitFor(() => expect(input.disabled).toBe(false));
    await user.clear(input); await user.type(input, invalid);
    await screen.findByText(/Hours and money must use no more than two decimal places/);
    await user.type(screen.getByLabelText(/Reason/), 'Reviewed exact precision');
    expect((screen.getByRole('button', { name: 'Issue corrective paycheck' }) as HTMLButtonElement).disabled).toBe(true);
    expect(api.issue).not.toHaveBeenCalled();
    await user.clear(input); await user.type(input, valid);
    await waitFor(() => expect((screen.getByRole('button', { name: 'Issue corrective paycheck' }) as HTMLButtonElement).disabled).toBe(false));
    expect(screen.queryByText(/Hours and money must use no more than two decimal places/)).toBeNull();
    await user.click(screen.getByRole('button', { name: 'Issue corrective paycheck' }));
    expect(api.issue).toHaveBeenCalledWith(12, expect.objectContaining({ corrected_inputs: expect.objectContaining({ [field]: Number(valid) }) }));
    expect(api.preview.mock.calls.some(([, request]) => request.corrected_inputs[field] === Number(invalid))).toBe(false);
  });
