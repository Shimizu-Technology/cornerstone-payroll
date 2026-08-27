export type EmployeeWorkspaceTab = 'overview' | 'pay-setup' | 'pay-history' | 'activity';
export type PayRunWorkspaceTab = 'overview' | 'work' | 'checks' | 'activity';

interface ReturnContext {
  returnTo?: string;
}

// Leave room for percent-encoding and the destination route under common 2 KB URL limits.
const MAX_RETURN_PATH_LENGTH = 1024;

function normalizeQuery(query: string): string {
  if (!query || query === '?') return '';
  return query.startsWith('?') ? query : `?${query}`;
}

function withReturnContext(path: string, context: ReturnContext = {}): string {
  if (!context.returnTo || context.returnTo.length > MAX_RETURN_PATH_LENGTH) return path;

  const params = new URLSearchParams({ return_to: context.returnTo });
  return `${path}?${params.toString()}`;
}

export function companyPath(companyId: number): string {
  return `/companies/${companyId}`;
}

export function employeesPath(companyId: number, query = ''): string {
  return `${companyPath(companyId)}/employees${normalizeQuery(query)}`;
}

export function newEmployeePath(companyId: number, context: ReturnContext = {}): string {
  return withReturnContext(`${employeesPath(companyId)}/new`, context);
}

export function employeePath(
  companyId: number,
  employeeId: number,
  tab: EmployeeWorkspaceTab = 'overview',
  context: ReturnContext = {},
): string {
  return withReturnContext(`${employeesPath(companyId)}/${employeeId}/${tab}`, context);
}

export function employeeEditPath(companyId: number, employeeId: number, context: ReturnContext = {}): string {
  return withReturnContext(`${employeesPath(companyId)}/${employeeId}/edit`, context);
}

export function payRunsPath(companyId: number, query = ''): string {
  return `${companyPath(companyId)}/pay-runs${normalizeQuery(query)}`;
}

export function payRunPath(
  companyId: number,
  payRunId: number,
  tab: PayRunWorkspaceTab = 'overview',
  context: ReturnContext = {},
): string {
  return withReturnContext(`${payRunsPath(companyId)}/${payRunId}/${tab}`, context);
}

export function payrollItemPath(
  companyId: number,
  payRunId: number,
  payrollItemId: number,
  context: ReturnContext = {},
): string {
  return withReturnContext(
    `${payRunsPath(companyId)}/${payRunId}/payroll-items/${payrollItemId}`,
    context,
  );
}

export function safeInternalReturnPath(value: string | null, fallback: string): string {
  if (
    !value
    || value.length > MAX_RETURN_PATH_LENGTH
    || !value.startsWith('/')
    || value.startsWith('//')
    || value.includes('\\')
  ) return fallback;

  try {
    const internalOrigin = 'https://cornerstone-payroll.local';
    const parsed = new URL(value, internalOrigin);
    if (parsed.origin !== internalOrigin) return fallback;
    return `${parsed.pathname}${parsed.search}${parsed.hash}`;
  } catch {
    return fallback;
  }
}

export function currentAppPath(pathname: string, search = ''): string {
  return `${pathname}${search}`;
}
