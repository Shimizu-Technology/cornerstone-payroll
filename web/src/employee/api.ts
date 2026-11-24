// Client for /api/v1/employee/*. Every call carries the Clerk session token;
// every call except GET /employee/links also carries X-Employee-Link-Id.
// The API answers every employee failure with a bare 404 so it never reveals
// whether a person or record exists, and this client keeps it that way: a 404
// only ever becomes "unavailable" or "access ended", never a reason.

export type EmployeeApiErrorKind = 'not_found' | 'unauthorized' | 'rate_limited' | 'offline' | 'server';

export class EmployeeApiError extends Error {
  readonly kind: EmployeeApiErrorKind;
  readonly status: number | null;
  readonly retryAfterSeconds: number | null;

  constructor(kind: EmployeeApiErrorKind, status: number | null = null, retryAfterSeconds: number | null = null) {
    super(`Employee API ${kind}${status ? ` (${status})` : ''}`);
    this.name = 'EmployeeApiError';
    this.kind = kind;
    this.status = status;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

/** M4-2 "Finding links": GET /api/v1/employee/links, the signed-in user's eligible links. */
export interface EmployeeLink {
  id: string;
  companyName: string;
  subdomainSlug: string | null;
  status: string;
  formerAccessUntil: string | null;
}

export interface EmployeeApiOptions {
  baseUrl: string;
  getToken: () => Promise<string | null>;
  fetchImpl?: typeof fetch;
  isOnline?: () => boolean;
}

interface RequestOptions {
  linkId?: string;
  method?: 'GET' | 'POST' | 'PATCH' | 'DELETE';
  body?: unknown;
  signal?: AbortSignal;
}

// Same bounds the API checks before it looks anything up (base_controller.rb).
const LINK_ID = /^[1-9]\d{0,18}$/;

export function isLinkId(value: string): boolean {
  return LINK_ID.test(value) && BigInt(value) <= 2n ** 63n - 1n;
}

function retryAfter(header: string | null): number | null {
  if (!header) return null;
  const seconds = Number(header);
  return Number.isFinite(seconds) && seconds >= 0 ? seconds : null;
}

export function errorForStatus(status: number, retryAfterHeader: string | null = null): EmployeeApiError {
  if (status === 401) return new EmployeeApiError('unauthorized', status);
  // 403 is not expected from employee routes; treat it like 404 so nothing leaks.
  if (status === 403 || status === 404) return new EmployeeApiError('not_found', status);
  if (status === 429) return new EmployeeApiError('rate_limited', status, retryAfter(retryAfterHeader));
  return new EmployeeApiError('server', status);
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value : null;
}

/** Accepts `{ links: [...] }` or a bare array, and drops entries without a usable id. */
export function parseLinks(data: unknown): EmployeeLink[] {
  const list = Array.isArray(data) ? data : record(data)?.links;
  if (!Array.isArray(list)) return [];
  return list.flatMap((item) => {
    const entry = record(item);
    const id = entry && (typeof entry.id === 'number' || typeof entry.id === 'string') ? String(entry.id) : '';
    if (!entry || !isLinkId(id)) return [];
    return [{
      id,
      companyName: text(entry.company_name) ?? '',
      subdomainSlug: text(entry.subdomain_slug),
      status: text(entry.status) ?? 'active',
      formerAccessUntil: text(entry.former_access_until),
    }];
  });
}

export function createEmployeeApi({ baseUrl, getToken, fetchImpl = (...args) => fetch(...args), isOnline = () => navigator.onLine }: EmployeeApiOptions) {
  async function request<T>(path: string, { linkId, method = 'GET', body, signal }: RequestOptions = {}): Promise<T | null> {
    if (!path.startsWith('/employee/')) throw new Error('The employee API client only calls /employee/ routes');
    if (linkId !== undefined && !isLinkId(linkId)) throw new EmployeeApiError('not_found');
    if (!isOnline()) throw new EmployeeApiError('offline');

    const token = await getToken();
    if (!token) throw new EmployeeApiError('unauthorized');

    const headers: Record<string, string> = { Accept: 'application/json', Authorization: `Bearer ${token}` };
    if (linkId !== undefined) headers['X-Employee-Link-Id'] = linkId;
    if (body !== undefined) headers['Content-Type'] = 'application/json';

    let response: Response;
    try {
      response = await fetchImpl(`${baseUrl}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal,
        credentials: 'omit',
        // Pay data never goes into the HTTP cache.
        cache: 'no-store',
      });
    } catch (error) {
      if (signal?.aborted) throw error;
      throw new EmployeeApiError(isOnline() ? 'server' : 'offline');
    }

    if (!response.ok) throw errorForStatus(response.status, response.headers.get('Retry-After'));
    if (response.status === 204) return null;
    const contentType = response.headers.get('Content-Type') ?? '';
    return contentType.includes('application/json') ? await response.json() as T : null;
  }

  return {
    request,
    async links(signal?: AbortSignal): Promise<EmployeeLink[]> {
      return parseLinks(await request<unknown>('/employee/links', { signal }));
    },
    async context(linkId: string, signal?: AbortSignal): Promise<void> {
      await request<unknown>('/employee/context', { linkId, signal });
    },
  };
}

export type EmployeeApi = ReturnType<typeof createEmployeeApi>;

/** What the signed-in shell shows when it can't open the employee's pay. */
export type EmployeeProblem = 'unavailable' | 'ended' | 'signed_out' | 'rate_limited' | 'offline' | 'error';

/**
 * A 404 before the shell has opened means the app is off for this employer or
 * the user has no link here: "isn't available". A 404 after it opened means the
 * link stopped working mid-session (revoked or former access ran out): "ended".
 */
export function problemFor(error: unknown, { opened }: { opened: boolean }): EmployeeProblem {
  if (!(error instanceof EmployeeApiError)) return 'error';
  switch (error.kind) {
    case 'not_found': return opened ? 'ended' : 'unavailable';
    case 'unauthorized': return 'signed_out';
    case 'rate_limited': return 'rate_limited';
    case 'offline': return 'offline';
    default: return 'error';
  }
}

/**
 * Picks the link to open. On a client subdomain the API returns only that
 * client's link, so the employer picker waits for a shared host (M4-8 plan
 * change 9). Former links stay usable until their access date passes.
 */
export function chooseLink(links: EmployeeLink[], today: string): EmployeeLink | EmployeeProblem {
  if (links.length === 0) return 'unavailable';
  const usable = links.filter((link) => link.status !== 'former' || !link.formerAccessUntil || link.formerAccessUntil >= today);
  if (usable.length === 0) return 'ended';
  return usable.find((link) => link.status === 'active') ?? usable[0];
}
