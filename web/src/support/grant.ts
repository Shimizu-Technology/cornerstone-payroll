export const SUPPORT_HEADER = 'X-View-As-Grant';
const STORAGE_KEY = 'payroll-support-view';
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;

// The handoff travels in a fragment, never in a request URL or referrer.
// Tab storage survives Clerk's sign-in redirect and a refresh on this site.
function openGrant(): string | null {
  if (typeof window === 'undefined') return null;
  const hash = new URLSearchParams(window.location.hash.slice(1));
  const handoff = hash.get('support-view');
  if (handoff !== null) {
    window.history.replaceState(window.history.state, '', window.location.pathname + window.location.search);
    if (!TOKEN_PATTERN.test(handoff)) return 'invalid';
    try { window.sessionStorage.setItem(STORAGE_KEY, handoff); } catch { /* This page can still open the grant. */ }
    return handoff;
  }
  try { return window.sessionStorage.getItem(STORAGE_KEY); } catch { return null; }
}

export const supportToken = openGrant();

export function leaveSupportView(destination: string): void {
  try { window.sessionStorage.removeItem(STORAGE_KEY); } catch { /* Storage can be unavailable. */ }
  window.location.replace(destination);
}

export interface SupportGrant {
  name: string;
  company_id: number;
  expires_at: string;
  employee_url: string | null;
  /** The staff site's origin, sent for employee-app views so End can return there. */
  staff_url?: string | null;
  link?: unknown;
}

export function supportRequest(
  base: string, clerkToken: string | null, method: 'GET' | 'DELETE', signal?: AbortSignal,
): Promise<Response> {
  const url = new URL(base.replace(/\/$/, '') + '/auth/view_as', window.location.origin);
  return fetch(url, {
    method, signal, cache: 'no-store', credentials: 'omit', redirect: 'error',
    headers: {
      [SUPPORT_HEADER]: supportToken ?? '',
      ...(clerkToken ? { Authorization: `Bearer ${clerkToken}` } : {}),
    },
  });
}

/** Where End sends staff: the staff site's dashboard when the grant names a valid one, otherwise `fallback`. */
export function supportExitDestination(grant: Pick<SupportGrant, 'staff_url'> | null, fallback: string): string {
  if (!grant?.staff_url) return fallback;
  try {
    const url = new URL('/app', grant.staff_url);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.toString() : fallback;
  } catch {
    return fallback;
  }
}
