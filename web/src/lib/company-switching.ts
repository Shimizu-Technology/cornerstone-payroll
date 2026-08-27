import { matchPath } from 'react-router';
import { employeesPath, payRunsPath } from '@/lib/routes';

export interface CompanySwitchRedirect {
  notice: string;
  to: string;
}

export function getCompanySwitchRedirect(pathname: string, nextCompanyId?: number, search = ''): CompanySwitchRedirect | null {
  const canonicalPayRunList = matchPath('/companies/:companyId/pay-runs', pathname);
  const legacyPayRunList = pathname === '/pay-periods';
  if (canonicalPayRunList || legacyPayRunList || matchPath('/companies/:companyId/pay-runs/*', pathname) || matchPath('/pay-periods/:id', pathname)) {
    return {
      notice: 'Switched clients. Showing pay periods for the selected client.',
      to: nextCompanyId ? payRunsPath(nextCompanyId, canonicalPayRunList || legacyPayRunList ? search : '') : '/pay-periods',
    };
  }

  const canonicalEmployeeList = matchPath('/companies/:companyId/employees', pathname);
  const legacyEmployeeList = pathname === '/employees';
  if (canonicalEmployeeList || legacyEmployeeList || matchPath('/companies/:companyId/employees/*', pathname) || (pathname !== '/employees/new' && matchPath('/employees/:id', pathname))) {
    return {
      notice: 'Switched clients. Showing employees for the selected client.',
      to: nextCompanyId ? employeesPath(nextCompanyId, canonicalEmployeeList || legacyEmployeeList ? search : '') : '/employees',
    };
  }

  return null;
}
