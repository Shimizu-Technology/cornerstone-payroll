import { matchPath } from 'react-router';

export interface CompanySwitchRedirect {
  notice: string;
  to: string;
}

export function getCompanySwitchRedirect(pathname: string): CompanySwitchRedirect | null {
  if (matchPath('/pay-periods/:id', pathname)) {
    return {
      notice: 'Switched clients. Showing pay periods for the selected client.',
      to: '/pay-periods',
    };
  }

  if (pathname !== '/employees/new' && matchPath('/employees/:id', pathname)) {
    return {
      notice: 'Switched clients. Showing employees for the selected client.',
      to: '/employees',
    };
  }

  return null;
}
