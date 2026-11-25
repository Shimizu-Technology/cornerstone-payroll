import { describe, expect, it } from 'vitest';
import { toContactRecord } from './employee-contact';
import type { Employee } from '@/types';

describe('toContactRecord', () => {
  it('keeps only contact fields, dropping the SSN and payroll data', () => {
    const employee = {
      id: 1, first_name: 'Ana', last_name: 'Reyes', email: 'ana@example.com', phone: '+16715550101',
      contact_revision: 'rev-1', ssn: '123-45-6789', ssn_last_four: '6789', pay_rate: 18, filing_status: 'single',
    } as unknown as Employee;

    const stored = toContactRecord(employee);

    expect(stored).toEqual({ id: 1, first_name: 'Ana', last_name: 'Reyes', email: 'ana@example.com', phone: '+16715550101', contact_revision: 'rev-1' });
    expect(employee.ssn).toBe('123-45-6789');
  });
});
