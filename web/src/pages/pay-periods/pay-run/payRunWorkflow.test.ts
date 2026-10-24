import { describe, expect, it } from 'vitest';
import type { PayPeriod } from '@/types';
import { payRunSteps } from './payRunWorkflow';

describe('saved payroll steps', () => {
  it.each([['draft', 'hours'], ['calculated', 'results'], ['approved', 'commit'], ['committed', 'results']] as const)('derives %s from saved status', (status, current) => {
    expect(payRunSteps({ status, run_purpose: 'regular' } as PayPeriod).current).toBe(current);
  });
  it.each(['adjustment', 'correction', 'bonus'] as const)('explains selected pay inputs for %s', run_purpose => {
    expect(payRunSteps({ status: 'draft', run_purpose } as PayPeriod).hoursReason).toContain('selected employees');
  });
  it('keeps parallel approval at commit with an explicit prohibition', () => {
    expect(payRunSteps({ status: 'approved', parallel_run: true, run_purpose: 'regular' } as PayPeriod).commitReason).toContain('cannot commit');
  });
  it('makes a committed run a results review with completed commitment', () => {
    expect(payRunSteps({ status: 'committed', run_purpose: 'regular' } as PayPeriod)).toMatchObject({ current: 'results', committed: true });
  });
});
