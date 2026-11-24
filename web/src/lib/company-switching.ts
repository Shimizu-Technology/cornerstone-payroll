import { matchPath } from 'react-router';
import { employeeContactDetailsPath, employeesPath, newEmployeePath, payRunsPath } from '@/lib/routes';

export interface CompanySwitchRedirect {
  notice: string;
  to: string;
}

export function getCompanySwitchRedirect(pathname: string, nextCompanyId?: number, search = ''): CompanySwitchRedirect | null {
  if (nextCompanyId && matchPath('/companies/:companyId/operating-profile', pathname)) {
    return {
      notice: 'Switched clients. Showing the operating profile for the selected client.',
      to: `/companies/${nextCompanyId}/operating-profile`,
    };
  }

  if (pathname === '/payroll-fields' || matchPath('/companies/:companyId/payroll-fields', pathname)) {
    return {
      notice: 'Switched clients. Showing reusable payroll fields for the selected client.',
      to: nextCompanyId ? `/companies/${nextCompanyId}/payroll-fields` : '/payroll-fields',
    };
  }
  const canonicalPayRunList = matchPath('/companies/:companyId/pay-runs', pathname);
  const legacyPayRunList = pathname === '/pay-periods';
  if (canonicalPayRunList || legacyPayRunList || matchPath('/companies/:companyId/pay-runs/*', pathname) || matchPath('/pay-periods/:id', pathname)) {
    return {
      notice: 'Switched clients. Showing pay periods for the selected client.',
      to: nextCompanyId ? payRunsPath(nextCompanyId, canonicalPayRunList || legacyPayRunList ? search : '') : '/pay-periods',
    };
  }

  const canonicalEmployeeList = matchPath('/companies/:companyId/employees', pathname);
  const canonicalEmployeeContactDetails = matchPath('/companies/:companyId/employees/contact-details', pathname);
  const canonicalEmployeeCreate = matchPath('/companies/:companyId/employees/new', pathname);
  const legacyEmployeeList = pathname === '/employees';
  const legacyContactDetails = pathname === '/contact-details' || pathname === '/employees/contact-details';
  if (canonicalEmployeeContactDetails || legacyContactDetails) {
    return {
      notice: 'Switched clients. Showing employee contact details for the selected client.',
      to: nextCompanyId ? employeeContactDetailsPath(nextCompanyId, search) : '/employees/contact-details',
    };
  }
  if (canonicalEmployeeCreate) {
    return {
      notice: 'Switched clients. Starting a new employee for the selected client.',
      to: nextCompanyId ? newEmployeePath(nextCompanyId) : '/employees/new',
    };
  }

  if (canonicalEmployeeList || legacyEmployeeList || (!canonicalEmployeeCreate && matchPath('/companies/:companyId/employees/*', pathname)) || (pathname !== '/employees/new' && matchPath('/employees/:id', pathname))) {
    return {
      notice: 'Switched clients. Showing employees for the selected client.',
      to: nextCompanyId ? employeesPath(nextCompanyId, canonicalEmployeeList || legacyEmployeeList ? search : '') : '/employees',
    };
  }

  return null;
}
