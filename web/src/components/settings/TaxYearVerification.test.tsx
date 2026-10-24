// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { TaxYearVerification } from './TaxYearVerification';
import { TaxYearWarning } from './TaxYearWarning';
import type { TaxConfig } from '@/services/api';

const mocks = vi.hoisted(() => ({ verify: vi.fn(), readiness: vi.fn() }));
vi.mock('@/services/api', () => ({
  taxConfigsApi: { verify: mocks.verify },
  taxYearReadinessApi: { get: mocks.readiness },
}));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
const config: TaxConfig = {
  id: 7, tax_year: 2027, verification_status: 'draft', verified_by: null, verified_at: null,
  source_references: 'FICA only; withholding held', ss_wage_base: 192300, ss_rate: 0.062,
  medicare_rate: 0.0145, additional_medicare_rate: 0.009, additional_medicare_threshold: 200000,
  is_active: false, created_at: '2026-10-24', updated_at: '2026-10-24', filing_statuses: [],
};

describe('tax year operator guidance', () => {
  it('compares the base and labels absent withholding without allowing a blank source note', () => {
    render(<TaxYearVerification config={config} previous={{ ...config, tax_year: 2026, ss_wage_base: 184500 }} onSaved={vi.fn()} />);
    expect(screen.getByText('$192,300.00')).toBeTruthy();
    expect(screen.getByText('$184,500.00')).toBeTruthy();
    expect(screen.getByText('single withholding comparison — absent / held')).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Verify 2027 tax tables' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('retains the source note and displays a server rejection so the admin can recover', async () => {
    mocks.verify.mockRejectedValue(new Error('Complete withholding tables for every filing status before verification'));
    render(<TaxYearVerification config={config} previous={null} onSaved={vi.fn()} />);
    fireEvent.change(screen.getByLabelText('Verification source note (required)'), { target: { value: 'SSA synthetic review source' } });
    fireEvent.click(screen.getByRole('button', { name: 'Verify 2027 tax tables' }));
    await screen.findByRole('alert');
    expect(mocks.verify).toHaveBeenCalledWith(7, 'SSA synthetic review source');
    expect((screen.getByLabelText('Verification source note (required)') as HTMLTextAreaElement).value).toBe('SSA synthetic review source');
  });

  it('warns for a selected January pay date even before the calendar lookahead begins', async () => {
    mocks.readiness.mockResolvedValue({ verified_years: [2026], warnings: [] });
    render(<TaxYearWarning companyId={1} payDate="2027-01-15" />);
    await waitFor(() => expect(screen.getByText(/2027 tax tables have not been verified/)).toBeTruthy());
    expect(screen.getByText(/You can save a draft pay period/)).toBeTruthy();
  });
});
