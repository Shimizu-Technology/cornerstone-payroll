import { describe, expect, it } from 'vitest';
import { apiErrorMessage } from './api-error-message';
import { errorRecovery } from './error-recovery';

describe('actionable API errors', () => {
  it('retains validation details with readable field labels and deduplicates messages', () => {
    expect(apiErrorMessage({ error: 'Validation failed', errors: ['Validation failed'], details: { prior_year_fica_wages: ['must be verified'], plan_source_reference: ['is required'] } }, 422))
      .toBe('Validation failed; Prior-year Social Security wages: must be verified; Plan document or administrator reference: is required');
  });
  it('handles string arrays, object errors and field errors without object stringification', () => {
    expect(apiErrorMessage({ errors: [{ error: 'Record changed' }, { message: 'Choose a pay date' }, null] }, 422)).toBe('Record changed; Choose a pay date');
    expect(apiErrorMessage({ errors: { pay_date: ['must be after the period'] } }, 422)).toBe('pay date: must be after the period');
    expect(apiErrorMessage('proxy returned HTML', 503)).toContain('Check whether your changes were saved');
  });
  it('offers recovery for expired sessions and concurrent edits while preserving server context', () => {
    expect(apiErrorMessage({ error: 'Token expired' }, 401)).toBe('Token expired Sign in again, then retry.');
    expect(apiErrorMessage({ error: 'Payroll revision changed' }, 409)).toContain('Reload the record');
  });
  it('gives specific payroll next steps without treating unknown wages as zero', () => {
    expect(errorRecovery('Verify prior-year employer wages before catch-up payroll')).toContain('Do not enter zero');
    expect(errorRecovery('Review the applied historical 401(k) classification')).toContain('Yearly retirement checks');
    expect(errorRecovery('Resolve required new-hire documents')).toContain('Manage documents');
    expect(errorRecovery('Choose the first pay date.')).toBeNull();
  });
});
