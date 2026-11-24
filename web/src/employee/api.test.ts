/** @vitest-environment node */
import { describe, expect, it, vi } from 'vitest';
import {
  chooseLink, createEmployeeApi, EmployeeApiError, employeeUrl, errorForStatus, parseApiBase, parseLinks, problemFor, type EmployeeApi, type EmployeeLink,
} from './api';

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });
}

function client(fetchImpl: typeof fetch, { token = 'tok_123', online = true }: { token?: string | null; online?: boolean } = {}): EmployeeApi {
  return createEmployeeApi({ baseUrl: 'https://api.example.test/api/v1', getToken: async () => token, fetchImpl, isOnline: () => online });
}

describe('employee API client', () => {
  it('sends the Clerk token and the link header, and never caches', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => new Response(null, { status: 204 }));
    await client(fetchImpl).context('42');

    const [url, init] = fetchImpl.mock.calls[0];
    expect(url).toBe('https://api.example.test/api/v1/employee/context');
    expect(init?.headers).toEqual({ Accept: 'application/json', Authorization: 'Bearer tok_123', 'X-Employee-Link-Id': '42' });
    expect(init?.cache).toBe('no-store');
    expect(init?.credentials).toBe('omit');
  });

  it('reads links without a link header', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => jsonResponse({ links: [{ id: 7, company_name: "MoSa's", subdomain_slug: 'mosas', status: 'active', former_access_until: null }] }));
    const links = await client(fetchImpl).links();

    expect(fetchImpl.mock.calls[0][0]).toBe('https://api.example.test/api/v1/employee/links');
    expect(fetchImpl.mock.calls[0][1]?.headers).not.toHaveProperty('X-Employee-Link-Id');
    expect(links).toEqual([{ id: '7', companyName: "MoSa's", subdomainSlug: 'mosas', status: 'active', formerAccessUntil: null }]);
  });

  it('builds URLs from a base with or without a trailing slash', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => new Response(null, { status: 204 }));
    const api = createEmployeeApi({ baseUrl: 'https://api.example.test/api/v1/', getToken: async () => 't', fetchImpl, isOnline: () => true });
    await api.context('42');
    expect(fetchImpl.mock.calls[0][0]).toBe('https://api.example.test/api/v1/employee/context');
    expect(fetchImpl.mock.calls[0][1]?.redirect).toBe('error');
  });

  it.each([
    '/employee/../admin/users',
    '/employee/%2e%2e/admin/users',
    '/employee/./links',
    '/employee\\..\\admin',
    '/admin/users',
    'employee/links',
  ])('refuses to leave /employee/: %s', async (path) => {
    const fetchImpl = vi.fn<typeof fetch>();
    await expect(client(fetchImpl).request(path)).rejects.toThrow(/refuses unsafe paths|only calls \/employee\//);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('refuses a path that resolves to another origin', () => {
    expect(() => employeeUrl(parseApiBase('https://api.example.test'), '//evil.example/employee/links')).toThrow(/API origin/);
    expect(() => employeeUrl(parseApiBase('https://api.example.test/api/v1'), '//evil.example/employee/links')).toThrow(/API origin/);
    expect(employeeUrl(parseApiBase('/api/v1', 'https://mosas.example.test'), '/employee/links').toString())
      .toBe('https://mosas.example.test/api/v1/employee/links');
  });

  it('treats a token failure while offline as offline, and otherwise as a server problem', async () => {
    let online = true;
    const offlineToken = createEmployeeApi({
      baseUrl: '', fetchImpl: vi.fn<typeof fetch>(), isOnline: () => online,
      getToken: async () => { online = false; throw new Error('ClerkOfflineError'); },
    });
    await expect(offlineToken.links()).rejects.toMatchObject({ kind: 'offline' });

    const brokenToken = createEmployeeApi({ baseUrl: '', fetchImpl: vi.fn<typeof fetch>(), isOnline: () => true, getToken: async () => { throw new Error('boom'); } });
    await expect(brokenToken.links()).rejects.toMatchObject({ kind: 'server' });
  });

  it('refuses to send a malformed link id', async () => {
    const fetchImpl = vi.fn<typeof fetch>();
    await expect(client(fetchImpl).context('0')).rejects.toMatchObject({ kind: 'not_found' });
    await expect(client(fetchImpl).context('9223372036854775808')).rejects.toMatchObject({ kind: 'not_found' });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('treats a missing session token as signed out without calling the API', async () => {
    const fetchImpl = vi.fn<typeof fetch>();
    await expect(client(fetchImpl, { token: null }).links()).rejects.toMatchObject({ kind: 'unauthorized' });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it.each([
    [401, 'unauthorized'],
    [403, 'not_found'],
    [404, 'not_found'],
    [429, 'rate_limited'],
    [500, 'server'],
    [503, 'server'],
  ] as const)('maps HTTP %i to %s', async (status, kind) => {
    const fetchImpl = vi.fn<typeof fetch>(async () => new Response(null, { status }));
    await expect(client(fetchImpl).links()).rejects.toMatchObject({ kind, status });
  });

  it('keeps Retry-After on a 429', () => {
    expect(errorForStatus(429, '30').retryAfterSeconds).toBe(30);
    expect(errorForStatus(429, 'soon').retryAfterSeconds).toBeNull();
  });

  it('reports offline before and after a failed request', async () => {
    const neverCalled = vi.fn<typeof fetch>();
    await expect(client(neverCalled, { online: false }).links()).rejects.toMatchObject({ kind: 'offline' });
    expect(neverCalled).not.toHaveBeenCalled();

    let online = true;
    const dropped = vi.fn<typeof fetch>(async () => { online = false; throw new TypeError('Failed to fetch'); });
    const api = createEmployeeApi({ baseUrl: '', getToken: async () => 't', fetchImpl: dropped, isOnline: () => online });
    await expect(api.links()).rejects.toMatchObject({ kind: 'offline' });
  });

  it('treats a network failure while online as a server problem', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => { throw new TypeError('Failed to fetch'); });
    await expect(client(fetchImpl).links()).rejects.toMatchObject({ kind: 'server' });
  });
});

describe('parseLinks', () => {
  it('accepts a bare array and drops entries without a usable id', () => {
    expect(parseLinks([{ id: '12', company_name: 'A' }, { id: 'abc' }, { company_name: 'no id' }, null])).toEqual([
      { id: '12', companyName: 'A', subdomainSlug: null, status: 'active', formerAccessUntil: null },
    ]);
  });

  it('returns no links for an unexpected body', () => {
    expect(parseLinks(null)).toEqual([]);
    expect(parseLinks({ links: 'nope' })).toEqual([]);
  });
});

describe('problemFor', () => {
  it('turns a 404 into "unavailable" before the app opened and "ended" after', () => {
    const notFound = new EmployeeApiError('not_found', 404);
    expect(problemFor(notFound, { opened: false })).toBe('unavailable');
    expect(problemFor(notFound, { opened: true })).toBe('ended');
  });

  it('maps the other failures', () => {
    expect(problemFor(new EmployeeApiError('unauthorized', 401), { opened: true })).toBe('signed_out');
    expect(problemFor(new EmployeeApiError('rate_limited', 429), { opened: false })).toBe('rate_limited');
    expect(problemFor(new EmployeeApiError('offline'), { opened: false })).toBe('offline');
    expect(problemFor(new EmployeeApiError('server', 500), { opened: false })).toBe('error');
    expect(problemFor(new Error('boom'), { opened: false })).toBe('error');
  });
});

describe('chooseLink', () => {
  const link = (overrides: Partial<EmployeeLink>): EmployeeLink => ({ id: '1', companyName: 'A', subdomainSlug: null, status: 'active', formerAccessUntil: null, ...overrides });

  it('shows "unavailable" when there are no links', () => {
    expect(chooseLink([], '2026-11-24', null)).toBe('unavailable');
  });

  it('keeps former employees in until their access date, then shows "ended"', () => {
    const former = link({ status: 'former', formerAccessUntil: '2026-11-24' });
    expect(chooseLink([former], '2026-11-24', null)).toBe(former);
    expect(chooseLink([former], '2026-11-25', null)).toBe('ended');
  });

  it('on a client subdomain, opens only that client\'s link', () => {
    const mosas = link({ id: '1', subdomainSlug: 'mosas' });
    const other = link({ id: '2', subdomainSlug: 'pelican' });
    expect(chooseLink([other, mosas], '2026-11-24', 'mosas')).toBe(mosas);
    // Never falls back to another company's link under this company's branding.
    expect(chooseLink([other], '2026-11-24', 'mosas')).toBe('unavailable');
    expect(chooseLink([link({ subdomainSlug: null })], '2026-11-24', 'mosas')).toBe('unavailable');
  });

  it('prefers an active link', () => {
    const former = link({ id: '1', status: 'former', formerAccessUntil: '2027-01-01' });
    const active = link({ id: '2' });
    expect(chooseLink([former, active], '2026-11-24', null)).toBe(active);
  });
});
