import { describe, expect, it } from 'vitest';
import { canEditPayrollCheckNumber } from './checkNumberEditability';

const check = (reconciliationStatus: 'unprepared' | 'prepared' | 'issued' | 'cleared' | 'replacement_required' | 'voided') => ({
  check_number: '3071',
  reconciliation_status: reconciliationStatus,
  voided: reconciliationStatus === 'voided',
});

describe('canEditPayrollCheckNumber', () => {
  it('allows corrections before and after physical preparation', () => {
    expect(canEditPayrollCheckNumber(check('unprepared'))).toBe(true);
    expect(canEditPayrollCheckNumber(check('prepared'))).toBe(true);
  });

  it('locks numbers once issuance or reconciliation begins', () => {
    expect(canEditPayrollCheckNumber(check('issued'))).toBe(false);
    expect(canEditPayrollCheckNumber(check('cleared'))).toBe(false);
    expect(canEditPayrollCheckNumber(check('replacement_required'))).toBe(false);
    expect(canEditPayrollCheckNumber(check('voided'))).toBe(false);
  });
});
