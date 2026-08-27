import { describe, expect, it } from 'vitest';
import {
  correctionRunPath,
  employeeEditPath,
  employeePath,
  employeesPath,
  newEmployeePath,
  payrollItemPath,
  payRunPath,
  payRunsPath,
  safeInternalReturnPath,
} from './routes';

describe('canonical payroll routes', (): void => {
  it('builds company-scoped list and record routes', (): void => {
    expect(employeesPath(12, '?status=active')).toBe('/companies/12/employees?status=active');
    expect(employeesPath(12, 'status=active')).toBe('/companies/12/employees?status=active');
    expect(newEmployeePath(12)).toBe('/companies/12/employees/new');
    expect(employeePath(12, 44, 'pay-history')).toBe('/companies/12/employees/44/pay-history');
    expect(employeeEditPath(12, 44)).toBe('/companies/12/employees/44/edit');
    expect(payRunsPath(12, '?status=draft')).toBe('/companies/12/pay-runs?status=draft');
    expect(payRunsPath(12, 'status=draft')).toBe('/companies/12/pay-runs?status=draft');
    expect(payRunPath(12, 91, 'checks')).toBe('/companies/12/pay-runs/91/checks');
    expect(payrollItemPath(12, 91, 305)).toBe('/companies/12/pay-runs/91/payroll-items/305');
  });

  it('encodes an explicit return destination without losing its query', (): void => {
    expect(payRunPath(12, 91, 'overview', {
      returnTo: '/companies/12/pay-runs?status=draft&year=2026',
    })).toBe('/companies/12/pay-runs/91/overview?return_to=%2Fcompanies%2F12%2Fpay-runs%3Fstatus%3Ddraft%26year%3D2026');
  });

  it('preserves filtered list context across canonical and legacy correction links', (): void => {
    const returnTo = '/companies/12/pay-runs?status=committed&year=2026';

    expect(correctionRunPath(12, 91, { returnTo })).toBe(
      `/companies/12/pay-runs/91/work?return_to=${encodeURIComponent(returnTo)}`,
    );
    expect(correctionRunPath(undefined, 91, { returnTo })).toBe(
      `/pay-periods/91?return_to=${encodeURIComponent(returnTo)}`,
    );
  });

  it('bounds circular record navigation instead of nesting return destinations forever', (): void => {
    let path = '/companies/12/pay-runs?status=draft&year=2026';
    let longestPath = path.length;

    for (let index = 0; index < 20; index += 1) {
      path = payRunPath(12, 91, 'overview', { returnTo: path });
      longestPath = Math.max(longestPath, path.length);
      path = payrollItemPath(12, 91, 305, { returnTo: path });
      longestPath = Math.max(longestPath, path.length);
    }

    expect(longestPath).toBeLessThanOrEqual(2048);
  });

  it('measures the final encoded route when bounding return context', (): void => {
    const reservedCharacters = '?&='.repeat(400);

    expect(newEmployeePath(12, {
      returnTo: `/companies/12/employees?search=${reservedCharacters}`,
    })).toBe('/companies/12/employees/new');
  });
});

describe('safeInternalReturnPath', (): void => {
  const fallback = '/companies/12/pay-runs';

  it('accepts internal paths and preserves search and hash context', (): void => {
    expect(safeInternalReturnPath('/companies/12/pay-runs?status=draft#queue', fallback))
      .toBe('/companies/12/pay-runs?status=draft#queue');
  });

  it.each([
    ['https://example.com/payroll'],
    ['//example.com/payroll'],
    ['/\\example.com/payroll'],
    ['pay-periods'],
    [null],
  ])('rejects unsafe or invalid return destinations: %s', (value): void => {
    expect(safeInternalReturnPath(value, fallback)).toBe(fallback);
  });

  it('rejects an excessively nested return destination', (): void => {
    expect(safeInternalReturnPath(`/companies/12/pay-runs?return_to=${'a'.repeat(2048)}`, fallback))
      .toBe(fallback);
  });
});
