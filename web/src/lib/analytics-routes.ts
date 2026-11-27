import { matchRoutes, type RouteObject } from 'react-router';

export type RouteSurface = 'staff' | 'employee';

export const UNKNOWN_ROUTE_TEMPLATE = '/unknown';

/**
 * Staff surface route patterns matching `web/src/App.tsx` (excluding the `*` catch-all).
 * Kept pure (no page/component imports) so the employee bundle never pulls in staff code.
 */
export const STAFF_ROUTE_OBJECTS: RouteObject[] = [
  // Public routes
  { path: '/' },
  { path: '/login' },
  { path: '/invite' },
  { path: '/privacy' },
  { path: '/terms' },
  { path: '/callback' },

  // Protected top-level routes
  { path: '/app' },
  { path: '/app/client-inbox' },
  { path: '/app/sign-in-as' },
  { path: '/support-access' },
  { path: '/messages' },
  { path: '/payroll-files' },
  { path: '/payroll-files/:ref' },
  { path: '/app/notifications' },
  { path: '/app/account-security' },
  { path: '/app/aire-account-connection' },
  { path: '/app/time-account-connection' },
  { path: '/app/aire-history-approval' },
  { path: '/employees' },
  { path: '/employees/contact-details' },
  { path: '/contact-details' },
  { path: '/employees/new' },
  { path: '/employees/:id' },
  { path: '/departments' },
  { path: '/pay-periods' },
  { path: '/pay-periods/:id' },

  // Company-scoped routes
  {
    path: '/companies/:companyId',
    children: [
      { path: 'operating-profile' },
      { path: 'employee-app' },
      { path: 'employee-app/rollout' },
      { path: 'employee-app/switch' },
      { path: 'messages' },
      { path: 'documents' },
      { path: 'change-requests' },
      { path: 'payroll-files' },
      { path: 'client-documents' },
      { path: 'client-messages' },
      { path: 'payroll-submissions' },
      { path: 'payroll-submissions/:ref' },
      { path: 'contact-changes-to-confirm' },
      { path: 'client-change-requests' },
      { path: 'employees' },
      { path: 'employees/contact-details' },
      { path: 'employees/new' },
      { path: 'employees/:id/edit' },
      { path: 'employees/:id' },
      { path: 'employees/:id/:tab' },
      { path: 'pay-runs' },
      { path: 'pay-runs/imported/:id' },
      { path: 'pay-runs/:id/payroll-items/:payrollItemId' },
      { path: 'pay-runs/:id' },
      { path: 'pay-runs/:id/:tab' },
      { path: 'prior-provider-history' },
      { path: 'payroll-go-live' },
      { path: 'payroll-fields' },
      { path: 'year-end' },
    ],
  },

  { path: '/historical-payroll' },
  { path: '/checks-payments' },
  { path: '/pay-periods/:id/form-500' },
  { path: '/payroll/run' },
  { path: '/reports' },
  { path: '/reports/client-profitability' },
  { path: '/year-end' },
  { path: '/documents' },
  { path: '/change-requests' },
  { path: '/employee-loans' },
  { path: '/payroll-fields' },
  { path: '/tools/timecard-ocr' },
  { path: '/tools/transmittals' },
  { path: '/tools/invoices' },
  { path: '/tools/finance' },
  { path: '/tools/finance/agent-access' },
  { path: '/tools/expenses' },
  { path: '/tools/invoices/assistant' },
  { path: '/tools/invoices/billing-profiles/:profileId/style' },
  { path: '/settings/users' },
  { path: '/settings/organizations' },
  { path: '/settings/tax-config' },
  { path: '/settings/audit-logs' },
  { path: '/settings/client-documents' },
  { path: '/settings/client-messages' },
  { path: '/settings/payroll-submissions' },
  { path: '/settings/payroll-submissions/:ref' },
  { path: '/settings/client-change-requests' },
  { path: '/check-settings' },
  { path: '/payroll-reminders' },
  { path: '/time-tracking-sources' },
  { path: '/standing-changes' },
  { path: '/pay-schedule-settings' },
  { path: '/settings/clients' },
];

/**
 * Employee surface route patterns matching `web/src/EmployeeApp.tsx` (excluding the `*` catch-all).
 */
export const EMPLOYEE_ROUTE_OBJECTS: RouteObject[] = [
  { path: '/' },
  { path: '/sign-in' },
  { path: '/activate' },
  { path: '/sign-up' },
  { path: '/sign-up/done' },
  { path: '/claim' },
  { path: '/add-access' },
  { path: '/reactivate' },
  { path: '/pay' },
  { path: '/pay/all' },
  { path: '/pay/:statementId' },
  { path: '/taxes' },
  { path: '/my-info' },
  { path: '/help' },
  { path: '/go-paperless' },
];

/**
 * Resolves a raw pathname (or path+query+hash) to its matched React Router route template
 * (for example `/companies/:companyId/employees/:id` or `/pay/:statementId`).
 * Unmatched paths always return `/unknown` so arbitrary segments or short mixed-character IDs
 * can never leak into analytics.
 */
export function resolveRouteTemplate(rawPath: string, surface: RouteSurface = 'staff'): string {
  const withoutQueryOrHash = rawPath.split(/[?#]/, 1)[0]?.trim() ?? '';
  if (!withoutQueryOrHash.startsWith('/')) {
    return UNKNOWN_ROUTE_TEMPLATE;
  }

  const normalized = withoutQueryOrHash.replace(/\/{2,}/g, '/');
  const routes = surface === 'employee' ? EMPLOYEE_ROUTE_OBJECTS : STAFF_ROUTE_OBJECTS;
  const matches = matchRoutes(routes, { pathname: normalized });
  if (!matches || matches.length === 0) {
    return UNKNOWN_ROUTE_TEMPLATE;
  }

  const leaf = matches[matches.length - 1];
  // Do not match a parent layout route (such as `/companies/:companyId`) with no leaf route.
  if (leaf.route.children && leaf.route.children.length > 0) {
    return UNKNOWN_ROUTE_TEMPLATE;
  }

  const parts: string[] = [];
  for (const match of matches) {
    const pattern = match.route.path;
    if (!pattern || pattern === '/') continue;
    const trimmed = pattern.replace(/^\/+|\/+$/g, '');
    if (trimmed) {
      parts.push(trimmed);
    }
  }

  return parts.length > 0 ? `/${parts.join('/')}` : '/';
}
