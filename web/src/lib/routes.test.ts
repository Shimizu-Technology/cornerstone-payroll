import { describe, expect, it } from 'vitest';
import {
  employeeEditPath,
  employeePath,
  employeesPath,
  newEmployeePath,
  payrollItemPath,
  payRunPath,
  payRunsPath,
  safeInternalReturnPath,
} from './routes';

describe('canonical payroll routes', () => {
  it('builds company-scoped list and record routes', () => {
    expect(employeesPath(12, '?status=active')).toBe('/companies/12/employees?status=active');
    expect(newEmployeePath(12)).toBe('/companies/12/employees/new');
    expect(employeePath(12, 44, 'pay-history')).toBe('/companies/12/employees/44/pay-history');
    expect(employeeEditPath(12, 44)).toBe('/companies/12/employees/44/edit');
    expect(payRunsPath(12, '?status=draft')).toBe('/companies/12/pay-runs?status=draft');
    expect(payRunPath(12, 91, 'checks')).toBe('/companies/12/pay-runs/91/checks');
    expect(payrollItemPath(12, 91, 305)).toBe('/companies/12/pay-runs/91/payroll-items/305');
  });

  it('encodes an explicit return destination without losing its query', () => {
    expect(payRunPath(12, 91, 'overview', {
      returnTo: '/companies/12/pay-runs?status=draft&year=2026',
    })).toBe('/companies/12/pay-runs/91/overview?return_to=%2Fcompanies%2F12%2Fpay-runs%3Fstatus%3Ddraft%26year%3D2026');
  });
});

describe('safeInternalReturnPath', () => {
  const fallback = '/companies/12/pay-runs';

  it('accepts internal paths and preserves search and hash context', () => {
    expect(safeInternalReturnPath('/companies/12/pay-runs?status=draft#queue', fallback))
      .toBe('/companies/12/pay-runs?status=draft#queue');
  });

  it.each([
    ['https://example.com/payroll'],
    ['//example.com/payroll'],
    ['/\\example.com/payroll'],
    ['pay-periods'],
    [null],
  ])('rejects unsafe or invalid return destinations: %s', (value) => {
    expect(safeInternalReturnPath(value, fallback)).toBe(fallback);
  });
});
