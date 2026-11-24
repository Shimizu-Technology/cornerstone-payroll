import { describe, expect, it } from 'vitest';
import { withoutFullSsn } from './employee-contact';
import type { Employee } from '@/types';

describe('withoutFullSsn', () => {
  it('drops the full SSN and keeps the last four and contact fields', () => {
    const employee = { id: 1, ssn: '123-45-6789', ssn_last_four: '6789', email: 'ana@example.com' } as Employee;

    const stored = withoutFullSsn(employee);

    expect(stored).not.toHaveProperty('ssn');
    expect(stored).toMatchObject({ id: 1, ssn_last_four: '6789', email: 'ana@example.com' });
    expect(employee.ssn).toBe('123-45-6789');
  });
});
