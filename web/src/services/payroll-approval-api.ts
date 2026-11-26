import { getApiBaseUrl } from '@/services/api';

export function sendPayrollApprovalRequest(
  token: string,
  companyId: number | null | undefined,
  path: string,
  method: 'POST' | 'PUT',
  body: object,
): Promise<Response> {
  return fetch(`${getApiBaseUrl()}${path}`, {
    method,
    cache: 'no-store',
    redirect: 'error',
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(companyId ? { 'X-Company-Id': String(companyId) } : {}),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
}
