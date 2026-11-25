import posthog, { type CaptureResult, type PostHog, type PostHogConfig } from 'posthog-js';
import { isStaging } from '@/lib/staging';
import { clientSubdomainHost } from '@/lib/tenant-subdomain';
import { supportToken } from '@/support/grant';

export const DEFAULT_POSTHOG_HOST = 'https://us.i.posthog.com';
export const DEFAULT_POSTHOG_ID_SALT = 'cornerstone-payroll:posthog-v1';

export type AnalyticsSurface = 'staff' | 'employee';

export interface AnalyticsEnv {
  VITE_PUBLIC_POSTHOG_ENABLED?: string;
  VITE_PUBLIC_POSTHOG_KEY?: string;
  VITE_PUBLIC_POSTHOG_HOST?: string;
  VITE_PUBLIC_POSTHOG_ID_SALT?: string;
  VITE_APP_SURFACE?: string;
  VITE_DEPLOYMENT_ENV?: string;
  DEV?: boolean;
}

export interface AnalyticsGateOptions {
  env?: AnalyticsEnv;
  isStagingEnv?: boolean;
  hasSupportToken?: boolean;
  navigatorObj?: Partial<Navigator & { msDoNotTrack?: string; globalPrivacyControl?: boolean }> | null;
  windowObj?: Partial<Window & { doNotTrack?: string }> | null;
}

const SENSITIVE_KEY_TOKENS = new Set([
  'ssn',
  'taxid',
  'bank',
  'routing',
  'account',
  'accounts',
  'password',
  'passwd',
  'token',
  'tokens',
  'email',
  'emails',
  'phone',
  'phones',
  'dob',
  'birth',
  'birthdate',
  'birthday',
  'salary',
  'salaries',
  'wage',
  'wages',
  'rate',
  'rates',
  'amount',
  'amounts',
]);

const SENSITIVE_TOKEN_PREFIX_PATTERN =
  /^(?:ssn|taxid|bank|routing|account|password|passwd|token|email|phone|dob|birth|salary|wage|rate|amount)\d*$/;

const EMPLOYEE_IDENTIFIER_KEYS = new Set([
  'company_id',
  'companyid',
  'company_name',
  'companyname',
  'employer',
  'employer_id',
  'employerid',
  'employer_name',
  'employername',
  'employee_id',
  'employeeid',
  'employee_name',
  'employeename',
  'link_id',
  'linkid',
  'statement_id',
  'statementid',
  'pay_period_id',
  'payperiodid',
  'payroll_item_id',
  'payrollitemid',
  'tenant_slug',
  'tenantslug',
  'title',
]);

const URL_PROPERTY_KEYS = new Set([
  '$current_url',
  '$referrer',
  '$initial_referrer',
  '$initial_current_url',
  '$external_click_url',
]);

const PATHNAME_PROPERTY_KEYS = new Set([
  '$pathname',
  '$initial_pathname',
  '$prev_pageview_pathname',
]);

const HOST_PROPERTY_KEYS = new Set([
  '$host',
  '$referring_domain',
  '$initial_referring_domain',
]);

const AUTOCAPTURE_IGNORE_SELECTORS = [
  'input',
  'textarea',
  'select',
  '[data-ph-no-capture]',
  '.ph-no-capture',
  '.ph-no-autocapture',
  '[data-ph-no-autocapture]',
];

const RAGECLICK_IGNORE_SELECTORS = [
  'input',
  'textarea',
  'select',
  '[data-ph-no-capture]',
  '.ph-no-capture',
  '.ph-no-rageclick',
];

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HEX_ID_PATTERN = /^[0-9a-f]{16,}$/i;
const NUMERIC_ID_PATTERN = /^\d+$/;
const PREFIXED_ID_PATTERN = /^[a-z]{2,10}_[A-Za-z0-9_-]{8,}$/i;
const JWT_LIKE_PATTERN = /^[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]+)?$/;
const LOWERCASE_SLUG_PATTERN = /^[a-z]+(?:-[a-z]+)*$/;

// FIPS 180-4 SHA-256 constants (first 32 bits of the fractional parts of the cube roots of the first 64 primes).
const SHA256_K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

function sha256Hex(input: string): string {
  const bytes = new TextEncoder().encode(input);
  const bitLen = bytes.length * 8;
  const paddedLen = Math.ceil((bytes.length + 9) / 64) * 64;
  const padded = new Uint8Array(paddedLen);
  padded.set(bytes);
  padded[bytes.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(paddedLen - 8, Math.floor(bitLen / 0x100000000), false);
  view.setUint32(paddedLen - 4, bitLen >>> 0, false);

  let h0 = 0x6a09e667;
  let h1 = 0xbb67ae85;
  let h2 = 0x3c6ef372;
  let h3 = 0xa54ff53a;
  let h4 = 0x510e527f;
  let h5 = 0x9b05688c;
  let h6 = 0x1f83d9ab;
  let h7 = 0x5be0cd19;

  const w = new Uint32Array(64);
  for (let offset = 0; offset < paddedLen; offset += 64) {
    for (let i = 0; i < 16; i += 1) {
      w[i] = view.getUint32(offset + i * 4, false);
    }
    for (let i = 16; i < 64; i += 1) {
      const s0 = ((w[i - 15] >>> 7) | (w[i - 15] << 25)) ^ ((w[i - 15] >>> 18) | (w[i - 15] << 14)) ^ (w[i - 15] >>> 3);
      const s1 = ((w[i - 2] >>> 17) | (w[i - 2] << 15)) ^ ((w[i - 2] >>> 19) | (w[i - 2] << 13)) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;
    let f = h5;
    let g = h6;
    let h = h7;

    for (let i = 0; i < 64; i += 1) {
      const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + S1 + ch + SHA256_K[i] + w[i]) >>> 0;
      const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (S0 + maj) >>> 0;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }

    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
    h5 = (h5 + f) >>> 0;
    h6 = (h6 + g) >>> 0;
    h7 = (h7 + h) >>> 0;
  }

  return [h0, h1, h2, h3, h4, h5, h6, h7]
    .map((word) => word.toString(16).padStart(8, '0'))
    .join('');
}

/**
 * Stable, non-reversible pseudonymous identifier derived from the internal user ID
 * plus a build-time salt (VITE_PUBLIC_POSTHOG_ID_SALT). Prevents PostHog events from
 * exposing raw database IDs, account counts, emails, or names.
 */
export function pseudonymousUserId(
  userId: string | number,
  salt: string = import.meta.env.VITE_PUBLIC_POSTHOG_ID_SALT || DEFAULT_POSTHOG_ID_SALT,
): string {
  const effectiveSalt = salt.trim() || DEFAULT_POSTHOG_ID_SALT;
  const digest = sha256Hex(`${effectiveSalt}:${String(userId)}`);
  return `usr_${digest.slice(0, 32)}`;
}

export function currentSurface(env: AnalyticsEnv = import.meta.env): AnalyticsSurface {
  return env.VITE_APP_SURFACE === 'employee' ? 'employee' : 'staff';
}

function isDntValueEnabled(value: unknown): boolean {
  return value === '1' || value === 1 || value === true || value === 'yes';
}

/**
 * Checks browser Do Not Track and Global Privacy Control signals.
 * PostHog's built-in `respect_dnt` checks DNT; checking GPC here as well
 * ensures both signals disable analytics before initialization or capture.
 */
export function hasPrivacyOptOutSignal(
  navigatorObj: AnalyticsGateOptions['navigatorObj'] = typeof navigator !== 'undefined'
    ? (navigator as Navigator & { msDoNotTrack?: string; globalPrivacyControl?: boolean })
    : null,
  windowObj: AnalyticsGateOptions['windowObj'] = typeof window !== 'undefined'
    ? (window as Window & { doNotTrack?: string })
    : null,
): boolean {
  if (navigatorObj?.globalPrivacyControl === true) return true;
  return (
    isDntValueEnabled(navigatorObj?.doNotTrack) ||
    isDntValueEnabled(navigatorObj?.msDoNotTrack) ||
    isDntValueEnabled(windowObj?.doNotTrack)
  );
}

export function shouldEnableAnalytics(options: AnalyticsGateOptions = {}): boolean {
  const env = options.env ?? import.meta.env;
  const staging = options.isStagingEnv ?? (env.VITE_DEPLOYMENT_ENV === 'staging' || isStaging);
  const inSupport = options.hasSupportToken ?? Boolean(supportToken);
  const explicitlyEnabled = env.VITE_PUBLIC_POSTHOG_ENABLED === 'true';
  const key = env.VITE_PUBLIC_POSTHOG_KEY?.trim();

  if (staging || inSupport || !explicitlyEnabled || !key || key === 'YOUR_POSTHOG_KEY') {
    return false;
  }

  return !hasPrivacyOptOutSignal(options.navigatorObj, options.windowObj);
}

function splitKeyTokens(key: string): string[] {
  return key
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
}

export function isSensitivePropertyKey(key: string): boolean {
  const tokens = splitKeyTokens(key);
  if (tokens.length === 0) return false;
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (SENSITIVE_KEY_TOKENS.has(token) || SENSITIVE_TOKEN_PREFIX_PATTERN.test(token)) {
      return true;
    }
    if (token === 'tax' && tokens[i + 1] === 'id') {
      return true;
    }
  }
  return false;
}

function isEmployeeIdentifierKey(key: string): boolean {
  const normalized = key
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .toLowerCase();
  return EMPLOYEE_IDENTIFIER_KEYS.has(normalized);
}

function decodeSegmentSafely(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    return segment;
  }
}

function isIdentifierLikeSegment(segment: string): boolean {
  const decoded = decodeSegmentSafely(segment);
  if (!decoded) return false;
  if (decoded.includes('@')) return true;
  if (NUMERIC_ID_PATTERN.test(decoded)) return true;
  if (UUID_PATTERN.test(decoded)) return true;
  if (HEX_ID_PATTERN.test(decoded)) return true;
  if (PREFIXED_ID_PATTERN.test(decoded)) return true;
  if (JWT_LIKE_PATTERN.test(decoded)) return true;
  // Mask long opaque/token-like segments while keeping readable kebab-case route names.
  if (decoded.length >= 16 && !LOWERCASE_SLUG_PATTERN.test(decoded)) {
    return true;
  }
  if (decoded.length >= 24 && !decoded.includes('-')) {
    return true;
  }
  return false;
}

export function scrubPathname(
  rawPath: string,
  options: { surface?: AnalyticsSurface } = {},
): string {
  const withoutQueryOrHash = rawPath.split(/[?#]/, 1)[0] ?? '';
  if (!withoutQueryOrHash) return '/';
  const leadingSlash = withoutQueryOrHash.startsWith('/');
  const segments = withoutQueryOrHash.split('/');
  const scrubbed = segments.map((segment, index) => {
    if (!segment) return '';
    // On the employee surface, any `/pay/:statementId` (anything except `/pay/all`)
    // is a pay statement identifier and must always be masked.
    if (
      options.surface === 'employee' &&
      index >= 2 &&
      segments[index - 1]?.toLowerCase() === 'pay' &&
      segment.toLowerCase() !== 'all'
    ) {
      return ':id';
    }
    return isIdentifierLikeSegment(segment) ? ':id' : segment;
  });
  const joined = scrubbed.join('/');
  return leadingSlash ? joined || '/' : joined;
}

function redactHost(hostname: string, surface?: AnalyticsSurface): string {
  if (surface !== 'employee') return hostname;
  const tenant = clientSubdomainHost({ hostname, search: '' }, false);
  return tenant ? 'tenant.shimizu-technology.com' : hostname;
}

export function scrubUrl(
  rawUrl: string,
  options: { surface?: AnalyticsSurface } = {},
): string {
  const trimmed = rawUrl.trim();
  if (!trimmed || trimmed === '$direct') return trimmed;

  if (trimmed.startsWith('/')) {
    return scrubPathname(trimmed, options);
  }

  try {
    const parsed = new URL(trimmed);
    const host = redactHost(parsed.hostname, options.surface);
    const port = parsed.port ? `:${parsed.port}` : '';
    const pathname = scrubPathname(parsed.pathname, options);
    return `${parsed.protocol}//${host}${port}${pathname}`;
  } catch {
    return scrubPathname(trimmed, options);
  }
}

function scrubElementsChain(chain: string, options: { surface?: AnalyticsSurface }): string {
  return chain.replace(/attr__href="([^"]*)"/g, (_match, href: string) => {
    return `attr__href="${scrubUrl(href, options)}"`;
  });
}

function scrubValue(
  value: unknown,
  options: { projectKey?: string; surface?: AnalyticsSurface },
  isTopLevelProperties: boolean,
): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => scrubValue(item, options, false));
  }
  if (value && typeof value === 'object') {
    const input = value as Record<string, unknown>;
    const output: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(input)) {
      // Preserve PostHog's own top-level ingestion project token so events are not rejected with 401.
      const isPostHogProjectToken =
        isTopLevelProperties &&
        key === 'token' &&
        typeof entry === 'string' &&
        Boolean(options.projectKey) &&
        entry === options.projectKey;

      if (!isPostHogProjectToken && isSensitivePropertyKey(key)) {
        continue;
      }

      if (options.surface === 'employee' && isEmployeeIdentifierKey(key)) {
        continue;
      }

      if (URL_PROPERTY_KEYS.has(key) && typeof entry === 'string') {
        output[key] = scrubUrl(entry, options);
        continue;
      }

      if (PATHNAME_PROPERTY_KEYS.has(key) && typeof entry === 'string') {
        output[key] = scrubPathname(entry, options);
        continue;
      }

      if (HOST_PROPERTY_KEYS.has(key) && typeof entry === 'string') {
        output[key] = entry === '$direct' ? entry : redactHost(entry, options.surface);
        continue;
      }

      if (key === 'attr__href' && typeof entry === 'string') {
        output[key] = scrubUrl(entry, options);
        continue;
      }

      if (key === '$elements_chain' && typeof entry === 'string') {
        output[key] = scrubElementsChain(entry, options);
        continue;
      }

      output[key] = scrubValue(entry, options, false);
    }
    return output;
  }
  return value;
}

export function createBeforeSend(options: {
  projectKey?: string;
  surface?: AnalyticsSurface;
} = {}): (event: CaptureResult | null) => CaptureResult | null {
  return (event) => {
    if (!event) return null;
    const next: CaptureResult = {
      ...event,
      properties: scrubValue(event.properties ?? {}, options, true) as CaptureResult['properties'],
    };
    if (event.$set) {
      next.$set = scrubValue(event.$set, options, false) as CaptureResult['$set'];
    }
    if (event.$set_once) {
      next.$set_once = scrubValue(event.$set_once, options, false) as CaptureResult['$set_once'];
    }
    return next;
  };
}

export function buildPostHogConfig(options: {
  env?: AnalyticsEnv;
  surface?: AnalyticsSurface;
} = {}): Partial<PostHogConfig> {
  const env = options.env ?? import.meta.env;
  const surface = options.surface ?? currentSurface(env);
  const projectKey = env.VITE_PUBLIC_POSTHOG_KEY?.trim();
  const apiHost = env.VITE_PUBLIC_POSTHOG_HOST?.trim() || DEFAULT_POSTHOG_HOST;
  const isDev = env.DEV ?? import.meta.env.DEV;

  return {
    api_host: apiHost,
    person_profiles: 'identified_only',
    capture_pageview: false,
    capture_pageleave: true,
    disable_session_recording: true,
    disable_surveys: true,
    autocapture: {
      css_selector_ignorelist: AUTOCAPTURE_IGNORE_SELECTORS,
    },
    rageclick: {
      css_selector_ignorelist: RAGECLICK_IGNORE_SELECTORS,
    },
    mask_all_text: true,
    mask_all_element_attributes: true,
    ip: false,
    persistence: 'localStorage+cookie',
    respect_dnt: true,
    save_campaign_params: false,
    before_send: createBeforeSend({ projectKey, surface }),
    loaded: (ph) => {
      if (isDev || hasPrivacyOptOutSignal()) {
        ph.opt_out_capturing();
      }
    },
  };
}

export const isPostHogEnabled = shouldEnableAnalytics();

let initialized = false;

export function initAnalytics(options: AnalyticsGateOptions & {
  surface?: AnalyticsSurface;
  client?: Pick<PostHog, 'init'>;
} = {}): boolean {
  const env = options.env ?? import.meta.env;
  const targetClient = options.client ?? posthog;
  const isCustomCall = Boolean(options.client || options.env);

  if (!isCustomCall && initialized) {
    return true;
  }

  if (typeof window === 'undefined' || !shouldEnableAnalytics(options)) {
    return false;
  }

  const key = env.VITE_PUBLIC_POSTHOG_KEY?.trim();
  if (!key) return false;

  targetClient.init(key, buildPostHogConfig({ env, surface: options.surface }));
  if (!isCustomCall) {
    initialized = true;
  }
  return true;
}

export function identifyUser(
  client: Pick<PostHog, 'identify'> | null | undefined,
  params: { userId: string | number; role: string; surface: AnalyticsSurface },
  salt?: string,
): void {
  // Never identify employees or send employer/employee/pay identifiers from the employee surface.
  if (!client || params.surface !== 'staff') return;
  client.identify(pseudonymousUserId(params.userId, salt), {
    role: params.role,
    surface: params.surface,
  });
}

export function resetAnalytics(client: Pick<PostHog, 'reset'> | null | undefined = posthog): void {
  if (!isPostHogEnabled || !client) return;
  if (typeof client.reset === 'function') {
    client.reset();
  }
}

export function capturePageView(
  client: Pick<PostHog, 'capture'> | null | undefined,
  pathname: string,
  surface: AnalyticsSurface,
): void {
  if (!client || typeof window === 'undefined') return;
  const scrubbedPath = scrubPathname(pathname, { surface });
  const scrubbedCurrentUrl = scrubUrl(`${window.location.origin}${pathname}`, { surface });
  client.capture('$pageview', {
    $current_url: scrubbedCurrentUrl,
    $pathname: scrubbedPath,
    surface,
  });
}

function capture(event: string, properties?: Record<string, unknown>): void {
  if (isPostHogEnabled && !import.meta.env.DEV) {
    posthog.capture(event, properties);
  }
}

export const analytics = {
  payrollCalculated: (payPeriodId: number, employeeCount: number) =>
    capture('payroll_calculated', { pay_period_id: payPeriodId, employee_count: employeeCount }),

  payrollApproved: (payPeriodId: number) =>
    capture('payroll_approved', { pay_period_id: payPeriodId }),

  payrollCommitted: (payPeriodId: number) =>
    capture('payroll_committed', { pay_period_id: payPeriodId }),

  checksDownloaded: (payPeriodId: number, count: number) =>
    capture('checks_downloaded', { pay_period_id: payPeriodId, check_count: count }),

  checksPrinted: (payPeriodId: number, count: number) =>
    capture('checks_printed', { pay_period_id: payPeriodId, check_count: count }),

  reportGenerated: (reportType: string, payPeriodId?: number) =>
    capture('report_generated', { report_type: reportType, pay_period_id: payPeriodId }),

  employeeCreated: () => capture('employee_created'),

  timecardUploaded: (fileType: string) =>
    capture('timecard_uploaded', { file_type: fileType }),

  timecardOcrApplied: (payPeriodId: number, entryCount: number) =>
    capture('timecard_ocr_applied', { pay_period_id: payPeriodId, entry_count: entryCount }),

  companySwitch: (companyId: number) =>
    capture('company_switched', { company_id: companyId }),
};
