/** @vitest-environment node */
import { describe, expect, it, vi } from 'vitest';
import {
  chooseLink, createEmployeeApi, EmployeeApiError, employeeUrl, errorForStatus, parseApiBase, parseLinks, problemFor, StepUpRequiredError, usableLinks,
  type EmployeeApi, type EmployeeLink,
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
    const fetchImpl = vi.fn<typeof fetch>(async () => jsonResponse({
      links: [{ id: 7, company_name: "MoSa's", subdomain_slug: 'mosas', status: 'active', former_access_until: null, latest_pay_date: '2026-11-20' }],
    }));
    const links = await client(fetchImpl).links();

    expect(fetchImpl.mock.calls[0][0]).toBe('https://api.example.test/api/v1/employee/links');
    expect(fetchImpl.mock.calls[0][1]?.headers).not.toHaveProperty('X-Employee-Link-Id');
    expect(links).toEqual([{ id: '7', companyName: "MoSa's", subdomainSlug: 'mosas', demo: false, status: 'active', formerAccessUntil: null, latestPayDate: '2026-11-20' }]);
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

  it('names an email mismatch or a retired code, and keeps every other 403 a not-found', () => {
    expect(errorForStatus(422, null, 'email_mismatch').kind).toBe('email_mismatch');
    expect(errorForStatus(403, null, 'email_mismatch').kind).toBe('email_mismatch');
    expect(errorForStatus(403, null, 'code_retired').kind).toBe('code_retired');
    expect(errorForStatus(403, null, 'something_else').kind).toBe('not_found');
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

  it('treats a fetch TypeError while online as a network error instead of a server problem', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => { throw new TypeError('Failed to fetch'); });
    await expect(client(fetchImpl).links()).rejects.toMatchObject({ kind: 'network' });
  });
});

describe('parseLinks', () => {
  it('reads former_access_until, an instant, as its Guam day', () => {
    const [former] = parseLinks({ links: [{ id: 7, company_name: 'A', status: 'former', former_access_until: '2028-03-01T23:59:59+10:00' }] });
    expect(former.formerAccessUntil).toBe('2028-03-01');
    expect(parseLinks([{ id: 8, former_access_until: '2028-03-01T13:59:59Z' }])[0].formerAccessUntil).toBe('2028-03-01');
    expect(parseLinks([{ id: 9, former_access_until: 'soon' }])[0].formerAccessUntil).toBeNull();
  });

  it('accepts numeric ids only while they are safe integers', () => {
    // 9007199254740993 parses as 9007199254740992, a different link.
    const rounded = JSON.parse('[{"id": 9007199254740993}, {"id": 9007199254740991}]');
    expect(parseLinks(rounded).map((link) => link.id)).toEqual(['9007199254740991']);
  });

  it('keeps large ids exactly when they arrive as decimal strings', () => {
    expect(parseLinks([{ id: '9007199254740993' }]).map((link) => link.id)).toEqual(['9007199254740993']);
    expect(parseLinks([{ id: '9223372036854775807' }]).map((link) => link.id)).toEqual(['9223372036854775807']);
    expect(parseLinks([{ id: 1.5 }, { id: -3 }, { id: 0 }, { id: '007' }])).toEqual([]);
  });

  it('accepts a bare array and drops entries without a usable id', () => {
    expect(parseLinks([{ id: '12', company_name: 'A' }, { id: 'abc' }, { company_name: 'no id' }, null])).toEqual([
      { id: '12', companyName: 'A', subdomainSlug: null, demo: false, status: 'active', formerAccessUntil: null, latestPayDate: null },
    ]);
    expect(parseLinks([{ id: '13', company_name: 'Demo Co', demo: true }])[0]?.demo).toBe(true);
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
    expect(problemFor(new EmployeeApiError('network'), { opened: false })).toBe('network');
    expect(problemFor(new EmployeeApiError('server', 500), { opened: false })).toBe('error');
    expect(problemFor(new Error('boom'), { opened: false })).toBe('error');
  });
});

describe('chooseLink', () => {
  const link = (overrides: Partial<EmployeeLink>): EmployeeLink => ({ id: '1', companyName: 'A', subdomainSlug: null, status: 'active', formerAccessUntil: null, latestPayDate: null, ...overrides });

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

  it('asks which employer on a shared host, and opens the one chosen', () => {
    const former = link({ id: '1', status: 'former', formerAccessUntil: '2027-01-01' });
    const active = link({ id: '2' });
    expect(chooseLink([former, active], '2026-11-24', null)).toBe('choose');
    expect(chooseLink([former, active], '2026-11-24', null, '1')).toBe(former);
    // A choice that's no longer usable asks again.
    expect(chooseLink([former, active], '2027-02-01', null, '1')).toBe(active);
    expect(usableLinks([former, active], '2026-11-24', null)).toEqual([active, former]);
  });

  it('never shows the picker on a client subdomain, and prefers the active link there', () => {
    const former = link({ id: '1', subdomainSlug: 'mosas', status: 'former', formerAccessUntil: '2027-01-01' });
    const active = link({ id: '2', subdomainSlug: 'mosas' });
    expect(chooseLink([former, active], '2026-11-24', 'mosas')).toBe(active);
  });
});

describe('employee API calls (M4-2, M4-4, M4-5, M4-7 contracts)', () => {
  const check = { code: 'ABCDEFGHJK', dateOfBirth: '1990-04-07', ssnLast4: '1234' };
  const account = { email: ' tala@example.com ', useForNotices: true, termsVersion: null };
  const anonymous = (fetchImpl: typeof fetch): EmployeeApi => createEmployeeApi({ baseUrl: 'https://api.example.test/api/v1', getToken: async () => null, fetchImpl, isOnline: () => true });

  it('sends sign-up as one check without a session token, as ActivationsController reads it', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => jsonResponse({ next: 'sign_up', sign_up_url: 'https://accounts.example.test/accept?ticket=x', message: null }));
    await expect(anonymous(fetchImpl).activate(check, account, 'https://mosas.example.test')).resolves.toEqual({ next: 'sign_up', signUpUrl: 'https://accounts.example.test/accept?ticket=x' });
    const [url, init] = fetchImpl.mock.calls[0];
    expect(url).toBe('https://api.example.test/api/v1/employee/activation');
    expect(init?.method).toBe('POST');
    expect(init?.headers).not.toHaveProperty('Authorization');
    expect(JSON.parse(String(init?.body))).toEqual({ code: 'ABCDEFGHJK', date_of_birth: '1990-04-07', ssn_last4: '1234', email: 'tala@example.com', use_for_notices: true });
  });

  it('reads "sign_in" as its own outcome, and every failed check as one generic kind', async () => {
    const signIn = anonymous(async () => jsonResponse({ next: 'sign_in', sign_up_url: null, message: 'We couldn\'t start a new account with that email.' }));
    await expect(signIn.activate(check, account, 'https://mosas.example.test')).resolves.toEqual({ next: 'sign_in' });
    const failed = anonymous(async () => jsonResponse({ error: 'We couldn\'t verify those details.', code: 'activation_failed' }, 422));
    await expect(failed.activate(check, account, 'https://mosas.example.test')).rejects.toMatchObject({ kind: 'invalid' });
    // A paused invite answers the same 422; there's no 423 to tell it apart.
    expect(errorForStatus(423).kind).toBe('server');
  });

  it('only follows an https (or same-site) sign-up URL', async () => {
    const respondWith = (sign_up_url: string) => anonymous(async () => jsonResponse({ next: 'sign_up', sign_up_url, message: null }));
    await expect(respondWith('javascript:alert(1)').activate(check, account, 'https://mosas.example.test')).rejects.toMatchObject({ kind: 'server' });
    await expect(respondWith('http://evil.example.test/').activate(check, account, 'https://mosas.example.test')).rejects.toMatchObject({ kind: 'server' });
    await expect(respondWith('/sign-up?__clerk_ticket=x').activate(check, account, 'https://mosas.example.test')).resolves.toEqual({ next: 'sign_up', signUpUrl: 'https://mosas.example.test/sign-up?__clerk_ticket=x' });
  });

  it('claims and reactivates with step-up, and reads the link back', async () => {
    const link = { id: 9, company_name: 'Coral Kitchen', subdomain_slug: 'coral', status: 'active', former_access_until: null };
    const fetchImpl = vi.fn<typeof fetch>(async () => jsonResponse({ link }, 201));
    const getToken = vi.fn(async () => 'tok');
    const api = createEmployeeApi({ baseUrl: 'https://api.example.test/api/v1', getToken, fetchImpl, isOnline: () => true });
    await expect(api.claimLink({ token: 't'.repeat(32), dateOfBirth: '1990-04-07', ssnLast4: '1234' }, null)).resolves.toMatchObject({ id: '9', companyName: 'Coral Kitchen' });
    await api.reactivate(check, 'v1');
    expect(fetchImpl.mock.calls.map(([url]) => url)).toEqual([
      'https://api.example.test/api/v1/employee/links/claim',
      'https://api.example.test/api/v1/employee/links/reactivate',
    ]);
    expect(fetchImpl.mock.calls[0][1]?.headers).not.toHaveProperty('X-Employee-Link-Id');
    expect(JSON.parse(String(fetchImpl.mock.calls[0][1]?.body))).toEqual({ token: 't'.repeat(32), date_of_birth: '1990-04-07', ssn_last4: '1234' });
    expect(JSON.parse(String(fetchImpl.mock.calls[1][1]?.body))).toEqual({ code: 'ABCDEFGHJK', date_of_birth: '1990-04-07', ssn_last4: '1234', terms_version: 'v1' });
    expect(getToken).toHaveBeenCalledWith({ fresh: true });
    // A failed claim is the API's one 404.
    await expect(client(async () => jsonResponse({ code: 'claim_failed' }, 404)).claimLink(check, null)).rejects.toMatchObject({ kind: 'not_found' });
  });

  it('reads two-step sign-in 403s as their own kinds, never "not found"', async () => {
    await expect(client(async () => jsonResponse({ error: 'Multi-factor authentication is required', code: 'mfa_required' }, 403)).context('42')).rejects.toMatchObject({ kind: 'mfa_required' });
    await expect(client(async () => jsonResponse({ error: 'Set up two-step sign-in', code: 'mfa_enrollment_required' }, 403)).claimLink(check, null)).rejects.toMatchObject({ kind: 'mfa_enrollment_required' });
    expect(problemFor(new EmployeeApiError('mfa_enrollment_required', 403), { opened: true })).toBe('mfa_setup');
    expect(problemFor(new EmployeeApiError('mfa_required', 403), { opened: false })).toBe('mfa_required');
  });

  // first_factor while REQUIRE_MFA is off, second_factor once it's on: the level is the API's, passed through.
  it.each(['first_factor', 'second_factor'])('turns a %s reverification 403 into StepUpRequiredError, with a fresh token', async (level) => {
    const hint = { clerk_error: { type: 'forbidden', reason: 'reverification-error', metadata: { reverification: { level, afterMinutes: 10 } } } };
    const fetchImpl = vi.fn<typeof fetch>(async () => jsonResponse(hint, 403));
    const getToken = vi.fn(async () => 'tok');
    const api = createEmployeeApi({ baseUrl: 'https://api.example.test/api/v1', getToken, fetchImpl, isOnline: () => true });
    const error = await api.updatePhone('42', '671-555-0100').catch((e: unknown) => e);
    expect(error).toBeInstanceOf(StepUpRequiredError);
    expect((error as StepUpRequiredError).hint.metadata?.reverification?.level).toBe(level);
    expect(getToken).toHaveBeenCalledWith({ fresh: true });
    expect(fetchImpl.mock.calls[0][1]?.method).toBe('PATCH');
  });

  it('keeps a plain 403 as "not found" when the link check also fails', async () => {
    const api = client(async () => jsonResponse({}, 403));
    await expect(api.statements('42')).rejects.toMatchObject({ kind: 'not_found' });
  });

  it.each([200, 404])('treats a missing PDF as a resource failure only when the link check succeeds (%i)', async (contextStatus) => {
    const fetchImpl = vi.fn<typeof fetch>(async url => new Response(null, { status: String(url).endsWith('/context') ? contextStatus : 404 }));
    const api = client(fetchImpl);

    await expect(api.statementPdf('42', '901')).rejects.toMatchObject({ kind: contextStatus === 200 ? 'resource_not_found' : 'not_found' });
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    expect(fetchImpl.mock.calls[1]).toEqual([
      'https://api.example.test/api/v1/employee/context',
      expect.objectContaining({ method: 'GET', headers: expect.objectContaining({ 'X-Employee-Link-Id': '42' }) }),
    ]);
  });

  it('asks for statements by year and page, and refuses unsafe ids', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => jsonResponse({ statements: [], years: [2026], next_page: null }));
    const api = client(fetchImpl);
    await api.statements('42', { year: 2026, page: 2 });
    expect(fetchImpl.mock.calls[0][0]).toBe('https://api.example.test/api/v1/employee/statements?page=2&year=2026');
    await expect(api.statement('42', '../admin')).rejects.toMatchObject({ kind: 'resource_not_found' });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it('downloads a PDF as a Blob without caching', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => new Response(new Blob(['%PDF-1.7'], { type: 'application/pdf' }), { headers: { 'Content-Type': 'application/pdf' } }));
    const blob = await client(fetchImpl).statementPdf('42', '901');
    expect(fetchImpl.mock.calls[0][0]).toBe('https://api.example.test/api/v1/employee/statements/901/pdf');
    expect(fetchImpl.mock.calls[0][1]?.cache).toBe('no-store');
    expect((fetchImpl.mock.calls[0][1]?.headers as Record<string, string>).Accept).toBe('application/pdf');
    expect(blob.size).toBeGreaterThan(0);
  });

  it('binds a new sign-up through /auth/me, the one route outside /employee/', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => jsonResponse({ roles: {} }));
    await client(fetchImpl).bindAccount();
    expect(fetchImpl.mock.calls[0][0]).toBe('https://api.example.test/api/v1/auth/me');
  });
});
