import { matchPath } from 'react-router';
import { employeesPath, payRunsPath } from '@/lib/routes';

export interface CompanySwitchRedirect {
  notice: string;
  to: string;
}

export function getCompanySwitchRedirect(pathname: string, nextCompanyId?: number): CompanySwitchRedirect | null {
  if (matchPath('/companies/:companyId/pay-runs/*', pathname) || matchPath('/pay-periods/:id', pathname)) {
    return {
      notice: 'Switched clients. Showing pay periods for the selected client.',
      to: nextCompanyId ? payRunsPath(nextCompanyId) : '/pay-periods',
    };
  }

  if (matchPath('/companies/:companyId/employees/*', pathname) || (pathname !== '/employees/new' && matchPath('/employees/:id', pathname))) {
    return {
      notice: 'Switched clients. Showing employees for the selected client.',
      to: nextCompanyId ? employeesPath(nextCompanyId) : '/employees',
    };
  }

  return null;
}
