import { describe, expect, it } from 'vitest';
import { getCompanySwitchRedirect } from './company-switching';

describe('getCompanySwitchRedirect', (): void => {
  it('moves a pay-run record back to the selected company queue', (): void => {
    expect(getCompanySwitchRedirect('/companies/7/pay-runs/88/checks', 12)).toEqual({
      notice: 'Switched clients. Showing pay periods for the selected client.',
      to: '/companies/12/pay-runs',
    });
  });

  it('moves an employee record back to the selected company list', (): void => {
    expect(getCompanySwitchRedirect('/companies/7/employees/55/pay-history', 12)).toEqual({
      notice: 'Switched clients. Showing employees for the selected client.',
      to: '/companies/12/employees',
    });
  });

  it('moves a legacy pay-run record to the selected company queue', (): void => {
    expect(getCompanySwitchRedirect('/pay-periods/88', 12)).toEqual({
      notice: 'Switched clients. Showing pay periods for the selected client.',
      to: '/companies/12/pay-runs',
    });
  });

  it('moves a legacy employee record to the selected company list', (): void => {
    expect(getCompanySwitchRedirect('/employees/55', 12)).toEqual({
      notice: 'Switched clients. Showing employees for the selected client.',
      to: '/companies/12/employees',
    });
  });

  it('falls back to legacy lists when no selected company id is available', (): void => {
    expect(getCompanySwitchRedirect('/companies/7/pay-runs/88/checks')).toMatchObject({
      to: '/pay-periods',
    });
    expect(getCompanySwitchRedirect('/companies/7/employees/55/pay-history')).toMatchObject({
      to: '/employees',
    });
  });

  it('leaves canonical and legacy employee creation forms in place', (): void => {
    expect(getCompanySwitchRedirect('/companies/7/employees/new', 12)).toBeNull();
    expect(getCompanySwitchRedirect('/employees/new', 12)).toBeNull();
  });

  it('preserves queue filters while switching companies', (): void => {
    expect(getCompanySwitchRedirect('/companies/7/pay-runs', 12, '?status=draft&sort=pay_date&direction=asc')).toEqual({
      notice: 'Switched clients. Showing pay periods for the selected client.',
      to: '/companies/12/pay-runs?status=draft&sort=pay_date&direction=asc',
    });
  });

  it('leaves company-independent pages in place', (): void => {
    expect(getCompanySwitchRedirect('/reports', 12)).toBeNull();
  });
});
