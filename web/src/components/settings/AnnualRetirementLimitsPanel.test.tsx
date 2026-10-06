// @vitest-environment jsdom
import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AnnualRetirementLimit } from '@/types';
import { AnnualRetirementLimitsPanel } from './AnnualRetirementLimitsPanel';

const mocks = vi.hoisted(() => ({
  list: vi.fn(), create: vi.fn(), update: vi.fn(), superAdmin: true,
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ isSuperAdmin: mocks.superAdmin }) }));
vi.mock('@/services/api', () => ({
  annualRetirementLimitsApi: mocks,
  ApiError: class ApiError extends Error { fieldErrors = {}; },
}));

const limit: AnnualRetirementLimit = {
  id: 4, tax_year: 2026, elective_deferral_limit: 24500,
  catch_up_limit: 8000, enhanced_catch_up_limit: 11250,
  roth_catch_up_wage_threshold: 150000, annual_additions_limit: 72000,
  compensation_limit: 360000, source_name: 'IRS 2026 announcement',
  source_url: 'https://www.irs.gov/newsroom/2026-retirement-limits',
};

describe('AnnualRetirementLimitsPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.superAdmin = true;
    mocks.list.mockResolvedValue({ data: [limit] });
  });
  afterEach(cleanup);

  it('shows the three age-based ceilings and separates additional plan limits for read-only staff', async () => {
    mocks.superAdmin = false;
    render(<AnnualRetirementLimitsPanel />);
    expect(await screen.findByText('$24,500')).toBeTruthy();
    expect(screen.getByText('$32,500')).toBeTruthy();
    expect(screen.getByText('$35,750')).toBeTruthy();
    expect(screen.getByText('$72,000')).toBeTruthy();
    expect(screen.getByText('$360,000')).toBeTruthy();
    expect(screen.getByText('Covered 2025 employer wages must exceed this amount.')).toBeTruthy();
    expect(screen.getByRole('link', { name: /IRS 2026 announcement/ }).getAttribute('href')).toBe(limit.source_url);
    expect(screen.queryByRole('button', { name: 'Add retirement year' })).toBeNull();
    expect(screen.queryByRole('button', { name: /Edit 2026/ })).toBeNull();
  });

  it('starts a new year with six blank amounts and saves verified values and provenance', async () => {
    const user = userEvent.setup();
    mocks.create.mockImplementation(async (payload) => ({ data: { ...payload, id: 5 } }));
    render(<AnnualRetirementLimitsPanel />);
    await screen.findByText('$35,750');
    await user.click(screen.getByRole('button', { name: 'Add retirement year' }));
    const form = screen.getByRole('form', { name: 'Add verified retirement year' });
    expect(document.activeElement).toBe(screen.getByRole('heading', { name: 'Add verified retirement year' }));
    const inputs = within(form).getAllByRole('textbox') as HTMLInputElement[];
    for (const input of inputs.slice(1, 7)) expect(input.value).toBe('');
    const year = screen.getByLabelText('Tax year');
    await user.clear(year);
    await user.type(year, '2027');
    const amounts: [string, string][] = [
      ['Regular employee deferral limit', '25000'], ['Age 50+ catch-up allowance', '8000'],
      ['Age 60–63 catch-up allowance', '12000'], ['Prior-year wage threshold for Roth catch-up', '160000'],
      ['Combined annual additions limit', '75000'], ['Employer contribution compensation limit', '370000'],
    ];
    for (const [label, value] of amounts) await user.type(screen.getByLabelText(label), value);
    await user.type(screen.getByLabelText('Source name'), 'Verified publication');
    await user.type(screen.getByLabelText('Source URL'), 'https://www.irs.gov/test-fixture');
    await user.type(screen.getByLabelText('Reason for change'), 'Verified against source');
    await user.click(screen.getByRole('button', { name: 'Save retirement limits' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledWith({
      tax_year: 2027, elective_deferral_limit: 25000, catch_up_limit: 8000,
      enhanced_catch_up_limit: 12000, roth_catch_up_wage_threshold: 160000,
      annual_additions_limit: 75000, compensation_limit: 370000,
      source_name: 'Verified publication', source_url: 'https://www.irs.gov/test-fixture', reason: 'Verified against source',
    }));
    expect(await screen.findByText(/2027 retirement limits saved/)).toBeTruthy();
    expect(screen.getByText('$37,000')).toBeTruthy();
  });

  it('keeps edit values after a failed save and supports retry with an audited reason', async () => {
    const user = userEvent.setup();
    mocks.update.mockRejectedValueOnce(new Error('The source could not be verified.'))
      .mockResolvedValueOnce({ data: { ...limit, catch_up_limit: 8500 } });
    render(<AnnualRetirementLimitsPanel />);
    await screen.findByText('$35,750');
    await user.click(screen.getByRole('button', { name: 'Edit 2026 retirement limits' }));
    expect((screen.getByLabelText('Tax year') as HTMLInputElement).disabled).toBe(true);
    const catchUp = screen.getByLabelText('Age 50+ catch-up allowance');
    await user.clear(catchUp);
    await user.type(catchUp, '8500');
    await user.type(screen.getByLabelText('Reason for change'), 'Correct source transcription');
    await user.click(screen.getByRole('button', { name: 'Save retirement limits' }));
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'The source could not be verified.');
    expect((catchUp as HTMLInputElement).value).toBe('8500');
    await user.click(screen.getByRole('button', { name: 'Save retirement limits' }));
    await screen.findByText(/2026 retirement limits saved/);
    expect(mocks.update).toHaveBeenLastCalledWith(4, expect.objectContaining({ catch_up_limit: 8500, reason: 'Correct source transcription' }));
    expect(screen.getByText('$33,000')).toBeTruthy();
  });

  it('recovers a failed initial load without showing a false empty state', async () => {
    const user = userEvent.setup();
    mocks.list.mockRejectedValueOnce(new Error('Retirement limits are unavailable.'))
      .mockResolvedValueOnce({ data: [limit] });
    render(<AnnualRetirementLimitsPanel />);
    await screen.findByRole('alert');
    expect(screen.queryByText(/No retirement years/)).toBeNull();
    await user.click(screen.getByRole('button', { name: 'Retry retirement limits' }));
    expect(await screen.findByText('$35,750')).toBeTruthy();
  });

  it('does not render unsafe stored source URLs as links', async () => {
    mocks.list.mockResolvedValue({ data: [{ ...limit, source_url: 'javascript:alert(1)' }] });
    render(<AnnualRetirementLimitsPanel />);
    await screen.findByText('$35,750');
    expect(screen.queryByRole('link')).toBeNull();
  });

  it('rejects an unsafe source URL before sending an edited annual limit', async () => {
    const user = userEvent.setup();
    render(<AnnualRetirementLimitsPanel />);
    await screen.findByText('$35,750');
    await user.click(screen.getByRole('button', { name: 'Edit 2026 retirement limits' }));
    const source = screen.getByLabelText('Source URL');
    await user.clear(source);
    await user.type(source, 'javascript:alert(1)');
    await user.type(screen.getByLabelText('Reason for change'), 'Verify published limits');
    await user.click(screen.getByRole('button', { name: 'Save retirement limits' }));
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Enter the source name, a complete http or https source URL, and the reason for this change.');
    expect(mocks.update).not.toHaveBeenCalled();
  });
});
