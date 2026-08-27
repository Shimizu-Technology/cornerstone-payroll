export type EmployeeWorkspaceTab = 'overview' | 'pay-setup' | 'pay-history' | 'activity';
export type PayRunWorkspaceTab = 'overview' | 'work' | 'checks' | 'activity';

interface ReturnContext {
  returnTo?: string;
}

function withReturnContext(path: string, context: ReturnContext = {}) {
  if (!context.returnTo) return path;

  const params = new URLSearchParams({ return_to: context.returnTo });
  return `${path}?${params.toString()}`;
}

export function companyPath(companyId: number) {
  return `/companies/${companyId}`;
}

export function employeesPath(companyId: number, query = '') {
  return `${companyPath(companyId)}/employees${query}`;
}

export function newEmployeePath(companyId: number, context: ReturnContext = {}) {
  return withReturnContext(`${employeesPath(companyId)}/new`, context);
}

export function employeePath(
  companyId: number,
  employeeId: number,
  tab: EmployeeWorkspaceTab = 'overview',
  context: ReturnContext = {},
) {
  return withReturnContext(`${employeesPath(companyId)}/${employeeId}/${tab}`, context);
}

export function employeeEditPath(companyId: number, employeeId: number, context: ReturnContext = {}) {
  return withReturnContext(`${employeesPath(companyId)}/${employeeId}/edit`, context);
}

export function payRunsPath(companyId: number, query = '') {
  return `${companyPath(companyId)}/pay-runs${query}`;
}

export function payRunPath(
  companyId: number,
  payRunId: number,
  tab: PayRunWorkspaceTab = 'overview',
  context: ReturnContext = {},
) {
  return withReturnContext(`${payRunsPath(companyId)}/${payRunId}/${tab}`, context);
}

export function payrollItemPath(
  companyId: number,
  payRunId: number,
  payrollItemId: number,
  context: ReturnContext = {},
) {
  return withReturnContext(
    `${payRunsPath(companyId)}/${payRunId}/payroll-items/${payrollItemId}`,
    context,
  );
}

export function safeInternalReturnPath(value: string | null, fallback: string) {
  if (!value || !value.startsWith('/') || value.startsWith('//') || value.includes('\\')) return fallback;

  try {
    const internalOrigin = 'https://cornerstone-payroll.local';
    const parsed = new URL(value, internalOrigin);
    if (parsed.origin !== internalOrigin) return fallback;
    return `${parsed.pathname}${parsed.search}${parsed.hash}`;
  } catch {
    return fallback;
  }
}

export function currentAppPath(pathname: string, search = '') {
  return `${pathname}${search}`;
}
