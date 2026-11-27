// Client for /api/v1/employee/*. Every call carries the Clerk session token
// (except sign-up's activation, made before any session); every call except
// links, claim and reactivate also carries X-Employee-Link-Id.
// The API answers every employee failure with a bare 404 so it never reveals
// whether a person or record exists. Recheck the link before using a scoped
// 404 to close the session. The client still never distinguishes inaccessible
// from missing records. Recognized 403s handle two-step sign-in and step-up.
// Response shapes live in contracts.ts.
import { SUPPORT_HEADER } from '@/support/grant';
import {
  accessDay, addressBody, identityBody, isoDate, parseActivation, parseContext, parseDeliveryConsents, parseHelpContacts, parseJob,
  parseProfile, parseStatementDetail, parseStatementPage, parseTaxForms, parseW2GuAccessProof, verificationIdFrom,
  type ActivationOutcome, type Address, type DeliveryConsentKind, type DeliveryConsentsState, type EmployeeContextInfo,
  type EmployeeJob, type EmployeeProfile, type HelpContact, type IdentityCheck, type StatementDetail, type StatementPage, type TaxForm,
  type W2GuAccessProofChallenge,
} from './contracts';

/**
 * - invalid: a 422 or 400. For sign-up it is the one generic "couldn't match" answer (claim's is a 404).
 * - conflict: 409, for example another change is already being reviewed.
 * - mfa_enrollment_required: 403, this login must set up two-step sign-in first (staff and client logins).
 * - mfa_required: 403, this session didn't finish two-step sign-in.
 */
export type EmployeeApiErrorKind =
  | 'not_found' | 'resource_not_found' | 'unauthorized' | 'rate_limited' | 'offline' | 'network' | 'server' | 'invalid' | 'conflict'
  | 'mfa_enrollment_required' | 'mfa_required'
  | 'email_code_daily_limit' | 'emergency_contact_limit' | 'personal_email_required' | 'address_on_file_changed'
  | 'access_proof_invalid' | 'disclosure_outdated' | 'no_active_consent' | 'consent_active' | 'terms_updated'
  | 'email_mismatch' | 'code_retired';

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

/** Clerk's reverification hint, as RecentVerification#require_recent_verification! sends it. */
export interface ReverificationHint {
  type: string;
  reason: string;
  metadata?: { reverification?: { level?: string; afterMinutes?: number } };
}

/** The API wants a fresh sign-in check before this change. The auth provider prompts and retries. */
export class StepUpRequiredError extends Error {
  readonly hint: ReverificationHint;

  constructor(hint: ReverificationHint) {
    super('Step-up verification required');
    this.name = 'StepUpRequiredError';
    this.hint = hint;
  }
}

/** The person closed the "confirm it's you" prompt. Nothing was changed. */
export class StepUpCancelledError extends Error {
  constructor() {
    super('Step-up verification cancelled');
    this.name = 'StepUpCancelledError';
  }
}

function reverificationHint(body: unknown): ReverificationHint | null {
  const hint = record(record(body)?.clerk_error);
  return hint && hint.reason === 'reverification-error' && typeof hint.type === 'string' ? hint as unknown as ReverificationHint : null;
}

/** M4-2 "Finding links": GET /api/v1/employee/links, the signed-in user's eligible links. */
export interface EmployeeLink {
  id: string;
  companyName: string;
  subdomainSlug: string | null;
  demo?: boolean;
  status: string;
  formerAccessUntil: string | null;
  latestPayDate: string | null;
}

export interface EmployeeApiOptions {
  baseUrl: string;
  /** `fresh` skips Clerk's token cache, so a just-finished reverification counts. */
  getToken: (options?: { fresh?: boolean }) => Promise<string | null>;
  grantToken?: string;
  fetchImpl?: typeof fetch;
  isOnline?: () => boolean;
}

interface RequestOptions {
  linkId?: string;
  method?: 'GET' | 'POST' | 'PATCH' | 'DELETE';
  body?: unknown;
  signal?: AbortSignal;
  /** A change behind step-up: a reverification 403 throws StepUpRequiredError, and the token is fresh. */
  stepUp?: boolean;
  /** Before sign-in (sign-up checks): no Authorization header. */
  anonymous?: boolean;
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

/** Only known codes affect the user-facing error. */
export function errorForStatus(status: number, retryAfterHeader: string | null = null, code: unknown = null): EmployeeApiError {
  if (status === 401) return new EmployeeApiError('unauthorized', status);
  if (status === 403 && code === 'mfa_enrollment_required') return new EmployeeApiError('mfa_enrollment_required', status);
  if (status === 403 && code === 'mfa_required') return new EmployeeApiError('mfa_required', status);
  // Sign-up and claim name these only after the invite check passed
  // (EmployeeLinks::EMAIL_MISMATCH, CODE_RETIRED), so they reveal nothing.
  if ((status === 403 || status === 422) && (code === 'email_mismatch' || code === 'code_retired')) {
    return new EmployeeApiError(code, status);
  }
  // Any other 403 is treated like 404 so nothing leaks.
  if (status === 403 || status === 404) return new EmployeeApiError('not_found', status);
  if (status === 429 && code === 'email_code_daily_limit') return new EmployeeApiError(code, status);
  if (status === 422 && (
    code === 'emergency_contact_limit'
    || code === 'personal_email_required'
    || code === 'access_proof_invalid'
    || code === 'disclosure_outdated'
    || code === 'no_active_consent'
    || code === 'consent_active'
  )) {
    return new EmployeeApiError(code, status);
  }
  if (status === 429) return new EmployeeApiError('rate_limited', status, retryAfter(retryAfterHeader));
  if (status === 409 && code === 'terms_updated') return new EmployeeApiError(code, status);
  if (status === 409) return new EmployeeApiError(code === 'address_on_file_changed' ? code : 'conflict', status);
  if (status === 422 || status === 400) return new EmployeeApiError('invalid', status);
  return new EmployeeApiError('server', status);
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value : null;
}

/**
 * A JSON number above 2^53 has already been rounded by the time it's parsed,
 * so it may name a different link. Numbers count only while they're safe
 * integers; larger ids must arrive as decimal strings.
 */
function linkIdFrom(value: unknown): string {
  if (typeof value === 'number') return Number.isSafeInteger(value) ? String(value) : '';
  return typeof value === 'string' ? value : '';
}

/**
 * GET /employee/links (AccountController#links, served):
 * { links: [{ id, company_name, subdomain_slug, status, former_access_until, latest_pay_date }] }.
 * Also accepts a bare array, and drops entries without a usable id.
 */
export function parseLinks(data: unknown): EmployeeLink[] {
  const list = Array.isArray(data) ? data : record(data)?.links;
  if (!Array.isArray(list)) return [];
  return list.flatMap((item) => {
    const entry = record(item);
    const id = entry ? linkIdFrom(entry.id) : '';
    if (!entry || !isLinkId(id)) return [];
    return [{
      id,
      companyName: text(entry.company_name) ?? '',
      subdomainSlug: text(entry.subdomain_slug),
      demo: entry.demo === true,
      status: text(entry.status) ?? 'active',
      // An instant at the end of the last Guam day; kept as that day.
      formerAccessUntil: accessDay(entry.former_access_until),
      latestPayDate: isoDate(entry.latest_pay_date),
    }];
  });
}

/** The API base, parsed once: its origin and its path without a trailing slash. */
export interface EmployeeApiBase {
  origin: string;
  path: string;
}

export function parseApiBase(baseUrl: string, pageOrigin: string = globalThis.location?.origin ?? 'http://localhost'): EmployeeApiBase {
  const base = new URL(baseUrl, pageOrigin);
  return { origin: base.origin, path: base.pathname.replace(/\/+$/, '') };
}

// `..` and `.` segments (also percent-encoded) and backslashes could walk the
// URL out of /employee/, so they're refused before the URL is built.
const UNSAFE_PATH = /\\|%5c|(?:^|\/)(?:\.|%2e){1,2}(?:\/|$)/i;

/** Resolves an /employee/ path against the API base, or throws if it would leave it. */
export function employeeUrl(base: EmployeeApiBase, path: string): URL {
  const [pathname] = path.split('?');
  if (UNSAFE_PATH.test(pathname)) throw new Error('The employee API client refuses unsafe paths');
  const url = new URL(`${base.path}${path}`, base.origin);
  if (url.origin !== base.origin || !url.pathname.startsWith(`${base.path}/employee/`)) {
    throw new Error('The employee API client only calls /employee/ routes on the API origin');
  }
  return url;
}

/** The one route outside /employee/ this client calls: /auth/me, which binds a new sign-up (M4-2). */
export function authMeUrl(base: EmployeeApiBase): URL {
  return new URL(`${base.path}/auth/me`, base.origin);
}

function statementsQuery(year: number | null, page: number): string {
  const query = new URLSearchParams({ page: String(page) });
  if (year) query.set('year', String(year));
  return query.toString();
}

function pathId(value: string): string {
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(value)) throw new EmployeeApiError('resource_not_found');
  return value;
}

export function createEmployeeApi({ baseUrl, getToken, grantToken, fetchImpl = (...args) => fetch(...args), isOnline = () => navigator.onLine }: EmployeeApiOptions) {
  const base = parseApiBase(baseUrl);
  const contextUrl = employeeUrl(base, '/employee/context');

  function isTokenNetworkError(error: unknown): boolean {
    if (error instanceof TypeError) return true;
    return error instanceof Error && /offline|network|failed to fetch/i.test(`${error.name} ${error.message}`);
  }

  async function sessionToken(fresh = false): Promise<string> {
    let token: string | null;
    try {
      token = await getToken(fresh ? { fresh } : undefined);
    } catch (error) {
      // Clerk rejects (ClerkOfflineError) when the connection drops mid-refresh.
      if (!isOnline()) throw new EmployeeApiError('offline');
      throw new EmployeeApiError(isTokenNetworkError(error) ? 'network' : 'server');
    }
    if (!token) throw new EmployeeApiError('unauthorized');
    return token;
  }

  async function send(url: URL, { linkId, method = 'GET', body, signal, stepUp = false, anonymous = false }: RequestOptions, accept: string): Promise<Response> {
    if (linkId !== undefined && !isLinkId(linkId)) throw new EmployeeApiError('not_found');
    if (!isOnline()) throw new EmployeeApiError('offline');

    const headers: Record<string, string> = { Accept: accept };
    if (!anonymous) headers.Authorization = `Bearer ${await sessionToken(stepUp)}`;
    if (grantToken) headers[SUPPORT_HEADER] = grantToken;
    else if (linkId !== undefined) headers['X-Employee-Link-Id'] = linkId;
    if (body !== undefined) headers['Content-Type'] = 'application/json';

    let response: Response;
    try {
      response = await fetchImpl(url.toString(), {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal,
        credentials: 'omit',
        // Pay data never goes into the HTTP cache, and a redirect never carries the token elsewhere.
        cache: 'no-store',
        redirect: 'error',
      });
    } catch (error) {
      if (signal?.aborted) throw error;
      if (!isOnline()) throw new EmployeeApiError('offline');
      throw new EmployeeApiError(error instanceof TypeError ? 'network' : 'server');
    }

    if (!response.ok) {
      let code: unknown = null;
      if (response.status === 403 || ((stepUp || method !== 'GET') && [409, 422, 429].includes(response.status))) {
        const body: unknown = await response.json().catch(() => null);
        const hint = stepUp && response.status === 403 ? reverificationHint(body) : null;
        if (hint) throw new StepUpRequiredError(hint);
        code = record(body)?.code ?? null;
      }
      const error = errorForStatus(response.status, response.headers.get('Retry-After'), code);
      if (error.kind === 'not_found' && linkId && url.pathname !== contextUrl.pathname && !signal?.aborted) {
        // A missing record and a closed link have the same response. Only the
        // separate context check can confirm that the link itself stopped working.
        await send(contextUrl, { linkId, signal }, 'application/json');
        throw new EmployeeApiError('resource_not_found', response.status);
      }
      throw error;
    }
    return response;
  }

  async function readJson<T>(response: Response): Promise<T | null> {
    if (response.status === 204) return null;
    const contentType = response.headers.get('Content-Type') ?? '';
    return contentType.includes('application/json') ? await response.json() as T : null;
  }

  async function request<T>(path: string, options: RequestOptions = {}): Promise<T | null> {
    return readJson<T>(await send(employeeUrl(base, path), options, 'application/json'));
  }

  /** A PDF, held only in memory as a Blob. */
  async function pdf(path: string, linkId: string): Promise<Blob> {
    const response = await send(employeeUrl(base, path), { linkId }, 'application/pdf');
    return response.blob();
  }

  return {
    request,
    async links(signal?: AbortSignal): Promise<EmployeeLink[]> {
      return parseLinks(await request<unknown>('/employee/links', { signal }));
    },
    async context(linkId: string, signal?: AbortSignal): Promise<EmployeeContextInfo> {
      return parseContext(await request<unknown>('/employee/context', { linkId, signal }));
    },
    async statements(linkId: string, { year = null, page = 1 }: { year?: number | null; page?: number } = {}, signal?: AbortSignal): Promise<StatementPage> {
      return parseStatementPage(await request<unknown>(`/employee/statements?${statementsQuery(year, page)}`, { linkId, signal }));
    },
    async statement(linkId: string, statementId: string, signal?: AbortSignal): Promise<StatementDetail> {
      const detail = parseStatementDetail(await request<unknown>(`/employee/statements/${pathId(statementId)}`, { linkId, signal }));
      if (!detail) throw new EmployeeApiError('server');
      return detail;
    },
    statementPdf(linkId: string, statementId: string): Promise<Blob> {
      return pdf(`/employee/statements/${pathId(statementId)}/pdf`, linkId);
    },
    async taxForms(linkId: string, signal?: AbortSignal): Promise<TaxForm[]> {
      return parseTaxForms(await request<unknown>('/employee/tax_forms', { linkId, signal }));
    },
    taxFormPdf(linkId: string, formId: string): Promise<Blob> {
      return pdf(`/employee/tax_forms/${pathId(formId)}/pdf`, linkId);
    },
    async helpContacts(linkId: string, signal?: AbortSignal): Promise<HelpContact[]> {
      return parseHelpContacts(await request<unknown>('/employee/help', { linkId, signal }));
    },
    /** "My job", or null for a former job. A 404 here (an API without the route yet) shows nothing, not "access ended". */
    async job(linkId: string, signal?: AbortSignal): Promise<EmployeeJob | null> {
      try {
        return parseJob(await request<unknown>('/employee/job', { linkId, signal }));
      } catch (error) {
        if (error instanceof EmployeeApiError && error.kind === 'resource_not_found') return null;
        throw error;
      }
    },
    async profile(linkId: string, signal?: AbortSignal): Promise<EmployeeProfile> {
      return parseProfile(await request<unknown>('/employee/profile', { linkId, signal }));
    },
    async updatePhone(linkId: string, phone: string): Promise<EmployeeProfile> {
      return parseProfile(await request<unknown>('/employee/profile/phone', { linkId, method: 'PATCH', body: { phone }, stepUp: true }));
    },
    /** Emails a code to the new address. Returns the id to confirm it with. */
    async startEmailChange(linkId: string, email: string): Promise<string> {
      const verificationId = verificationIdFrom(await request<unknown>('/employee/profile/email', { linkId, method: 'POST', body: { email }, stepUp: true }));
      if (!verificationId) throw new EmployeeApiError('server');
      return verificationId;
    },
    async confirmEmailChange(linkId: string, verificationId: string, code: string): Promise<EmployeeProfile> {
      return parseProfile(await request<unknown>('/employee/profile/email/confirm', {
        linkId, method: 'POST', body: { verification_id: verificationId, code }, stepUp: true,
      }));
    },
    async saveEmergencyContact(linkId: string, contact: { id?: string; name: string; relationship: string; phone: string }): Promise<EmployeeProfile> {
      const body = { name: contact.name.trim(), relationship: contact.relationship.trim(), phone: contact.phone.trim() };
      const path = contact.id ? `/employee/emergency_contacts/${pathId(contact.id)}` : '/employee/emergency_contacts';
      return parseProfile(await request<unknown>(path, { linkId, method: contact.id ? 'PATCH' : 'POST', body, stepUp: true }));
    },
    async removeEmergencyContact(linkId: string, contactId: string): Promise<EmployeeProfile> {
      return parseProfile(await request<unknown>(`/employee/emergency_contacts/${pathId(contactId)}`, { linkId, method: 'DELETE', stepUp: true }));
    },
    async requestAddressChange(linkId: string, address: Address, requestId?: string): Promise<EmployeeProfile> {
      const path = requestId ? `/employee/address_requests/${pathId(requestId)}` : '/employee/address_requests';
      return parseProfile(await request<unknown>(path, { linkId, method: requestId ? 'PATCH' : 'POST', body: { address: addressBody(address) }, stepUp: true }));
    },
    async cancelAddressRequest(linkId: string, requestId: string): Promise<EmployeeProfile> {
      return parseProfile(await request<unknown>(`/employee/address_requests/${pathId(requestId)}`, { linkId, method: 'DELETE', stepUp: true }));
    },
    async deliveryConsents(linkId: string, signal?: AbortSignal): Promise<DeliveryConsentsState> {
      return parseDeliveryConsents(await request<unknown>('/employee/delivery_consents', { linkId, signal }));
    },
    async startW2GuAccessProof(linkId: string): Promise<W2GuAccessProofChallenge> {
      const challenge = parseW2GuAccessProof(await request<unknown>('/employee/delivery_consents/w2gu_access_proof/pdf', { linkId, method: 'POST' }));
      if (!challenge) throw new EmployeeApiError('server');
      return challenge;
    },
    async giveDeliveryConsent(
      linkId: string,
      payload: {
        kind: DeliveryConsentKind;
        disclosureVersion: string;
        disclosureDigest: string;
        accessProofToken?: string;
        accessProofCode?: string;
      },
    ): Promise<DeliveryConsentsState> {
      const body: Record<string, unknown> = {
        kind: payload.kind,
        acknowledged: true,
        disclosure_version: payload.disclosureVersion,
        disclosure_digest: payload.disclosureDigest,
      };
      if (payload.accessProofToken) body.access_proof_token = payload.accessProofToken;
      if (payload.accessProofCode) body.access_proof_code = payload.accessProofCode.trim();
      return parseDeliveryConsents(await request<unknown>('/employee/delivery_consents', { linkId, method: 'POST', body, stepUp: true }));
    },
    async withdrawDeliveryConsent(linkId: string, kind: DeliveryConsentKind): Promise<DeliveryConsentsState> {
      return parseDeliveryConsents(await request<unknown>('/employee/delivery_consents/withdraw', { linkId, method: 'POST', body: { kind } }));
    },
    /** Records "keep paper" as the answer; delivery doesn't change. */
    async keepPaperDelivery(linkId: string, kind: DeliveryConsentKind): Promise<DeliveryConsentsState> {
      return parseDeliveryConsents(await request<unknown>('/employee/delivery_consents/keep_paper', { linkId, method: 'POST', body: { kind } }));
    },
    /**
     * Sign-up, before any session: the invite check and the email in one call.
     * `sign_up` opens Clerk's sign-up; `sign_in` means this email can't start
     * a new account here (it may already have one).
     */
    async activate(check: IdentityCheck, account: { email: string; useForNotices: boolean; termsVersion: string | null }, pageOrigin: string): Promise<ActivationOutcome> {
      const body = {
        ...identityBody(check),
        email: account.email.trim(),
        use_for_notices: account.useForNotices,
        ...(account.termsVersion ? { terms_version: account.termsVersion } : {}),
      };
      const outcome = parseActivation(await request<unknown>('/employee/activation', { method: 'POST', body, anonymous: true }), pageOrigin);
      if (!outcome) throw new EmployeeApiError('server');
      return outcome;
    },
    /** Adds employee access to the login the person is signed in with. Behind step-up. */
    async claimLink(check: IdentityCheck, termsVersion: string | null): Promise<EmployeeLink | null> {
      const body = { ...identityBody(check), ...(termsVersion ? { terms_version: termsVersion } : {}) };
      return parseLinks([record(await request<unknown>('/employee/links/claim', { method: 'POST', body, stepUp: true }))?.link])[0] ?? null;
    },
    /** A rehired employee's login, turned off when their last job ended, opened again for the new invite. Behind step-up. */
    async reactivate(check: IdentityCheck, termsVersion: string | null): Promise<EmployeeLink | null> {
      const body = { ...identityBody(check), ...(termsVersion ? { terms_version: termsVersion } : {}) };
      return parseLinks([record(await request<unknown>('/employee/links/reactivate', { method: 'POST', body, stepUp: true }))?.link])[0] ?? null;
    },
    /** After Clerk sign-up: /auth/me runs the invitation bind (M4-2 step 3). */
    async bindAccount(): Promise<void> {
      await readJson<unknown>(await send(authMeUrl(base), {}, 'application/json'));
    },
  };
}

export type EmployeeApi = ReturnType<typeof createEmployeeApi>;

/** What the signed-in shell shows when it can't open the employee's pay. */
export type EmployeeProblem = 'unavailable' | 'ended' | 'signed_out' | 'rate_limited' | 'offline' | 'network' | 'error' | 'mfa_setup' | 'mfa_required';

/**
 * A failed link check means "isn't available" during setup and "access ended"
 * after the link has already opened. A resource failure stays on its screen.
 */
export function problemFor(error: unknown, { opened }: { opened: boolean }): EmployeeProblem {
  if (!(error instanceof EmployeeApiError)) return 'error';
  switch (error.kind) {
    case 'not_found': return opened ? 'ended' : 'unavailable';
    case 'unauthorized': return 'signed_out';
    case 'mfa_enrollment_required': return 'mfa_setup';
    case 'mfa_required': return 'mfa_required';
    case 'rate_limited': return 'rate_limited';
    case 'offline': return 'offline';
    case 'network': return 'network';
    default: return 'error';
  }
}

/**
 * The links this person can open here. On a client subdomain (`tenantSlug`)
 * only that client's links count, even if the API returns others, and with
 * none the app is "unavailable" there: it never opens another company's pay
 * under this company's branding. Former links stay usable until their access
 * date passes.
 */
export function usableLinks(links: EmployeeLink[], today: string, tenantSlug: string | null): EmployeeLink[] | EmployeeProblem {
  const here = tenantSlug ? links.filter((link) => link.subdomainSlug === tenantSlug) : links;
  if (here.length === 0) return 'unavailable';
  const usable = here.filter((link) => link.status !== 'former' || !link.formerAccessUntil || link.formerAccessUntil >= today);
  if (usable.length === 0) return 'ended';
  // Current jobs first, then former ones.
  return [...usable].sort((a, b) => Number(a.status === 'former') - Number(b.status === 'former'));
}

/**
 * Picks the link to open, or 'choose' when the person has more than one
 * employer on a shared host and should pick (the employer picker). A client
 * subdomain never shows the picker: it opens that client's link.
 */
export function chooseLink(links: EmployeeLink[], today: string, tenantSlug: string | null, chosenId: string | null = null): EmployeeLink | EmployeeProblem | 'choose' {
  const usable = usableLinks(links, today, tenantSlug);
  if (typeof usable === 'string') return usable;
  const chosen = chosenId ? usable.find((link) => link.id === chosenId) : undefined;
  if (chosen) return chosen;
  if (!tenantSlug && usable.length > 1) return 'choose';
  return usable[0];
}
