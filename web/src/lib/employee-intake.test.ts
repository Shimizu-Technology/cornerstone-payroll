import { describe, expect, it } from 'vitest';
import { intakeAllowsBlank } from './employee-intake';
import type { Employee } from '@/types';

describe('Deferred employee intake fields', () => {
  it('permits only configured intake fields during new entry', () => {
    expect(intakeAllowsBlank(null, 'ssn', true)).toBe(true);
    expect(intakeAllowsBlank(null, 'pay_rate', true)).toBe(false);
    expect(intakeAllowsBlank(null, 'ssn', false)).toBe(false);
  });
  it('preserves only outstanding approved gaps after strict entry is restored', () => {
    const employee = { intake_readiness: { missing_fields: ['city'], exception: {} } } as Employee;
    expect(intakeAllowsBlank(employee, 'city', false)).toBe(true);
    expect(intakeAllowsBlank(employee, 'zip', true)).toBe(false);
  });
});
