import posthog, { type CaptureResult, type PostHog, type PostHogConfig } from 'posthog-js';
import { isStaging } from '@/lib/staging';
import { clientSubdomainHost } from '@/lib/tenant-subdomain';
import { supportToken } from '@/support/grant';

export const DEFAULT_POSTHOG_HOST = 'https://us.i.posthog.com';

export type AnalyticsSurface = 'staff' | 'employee';

export interface AnalyticsEnv {
  VITE_PUBLIC_POSTHOG_ENABLED?: string;
  VITE_PUBLIC_POSTHOG_KEY?: string;
  VITE_PUBLIC_POSTHOG_HOST?: string;
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

/**
 * Event types dropped unconditionally in before_send so free-text stack traces,
 * performance/URL payloads, person-profile mutations, and survey/heatmap traffic
 * can never leave the browser.
 */
export const DROPPED_EVENT_TYPES = new Set([
  '$exception',
  '$web_vitals',
  '$identify',
  '$set',
  '$groupidentify',
  '$create_alias',
  '$dead_click',
  '$heatmap_data',
  '$snapshot',
  '$performance_event',
  '$feature_flag_called',
  'survey shown',
  'survey sent',
  'survey dismissed',
]);

const AUTOCAPTURE_EVENT_TYPES = new Set(['$autocapture', '$rageclick']);

const STRING_ALLOWLIST_KEYS = new Set([
  '$browser',
  '$os',
  '$device_type',
  '$lib',
  '$lib_version',
  '$insert_id',
  'distinct_id',
  '$session_id',
  '$window_id',
]);

const NUMBER_ALLOWLIST_KEYS = new Set([
  '$screen_height',
  '$screen_width',
  '$time',
]);

const VIEWPORT_KEY_PATTERN = /^\$viewport_[a-z0-9_]+$/;
const SAFE_TAG_NAME_PATTERN = /^[a-z][a-z0-9-]*$/i;
const SAFE_PH_NAME_PATTERN = /^[a-z0-9._ -]{1,80}$/i;

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

export function redactHost(hostname: string, surface?: AnalyticsSurface): string {
  if (surface !== 'employee') return hostname;
  const tenant = clientSubdomainHost({ hostname, search: '' }, false);
  return tenant ? 'tenant.shimizu-technology.com' : hostname;
}

/**
 * Returns origin + scrubbed pathname for HTTP(S) URLs, stripping query strings,
 * fragments (including `#/` routes and `#token=...`), and credentials. Non-HTTP(S)
 * URLs (such as `blob:` PDF downloads) return `undefined` so they are dropped.
 */
export function scrubUrl(
  rawUrl: string,
  options: { surface?: AnalyticsSurface } = {},
): string | undefined {
  const trimmed = rawUrl.trim();
  if (!trimmed) return undefined;

  if (trimmed.startsWith('/')) {
    return scrubPathname(trimmed, options);
  }

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return undefined;
  }

  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return undefined;
  }

  const host = redactHost(parsed.hostname, options.surface);
  const port = parsed.port ? `:${parsed.port}` : '';
  const pathname = scrubPathname(parsed.pathname, options);
  return `${parsed.protocol}//${host}${port}${pathname}`;
}

interface SanitizedElement {
  tag_name: string;
  'attr__data-ph-name'?: string;
}

function sanitizePhName(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  if (!trimmed || trimmed.includes('@') || trimmed.includes('://') || /^blob:/i.test(trimmed)) {
    return undefined;
  }
  return SAFE_PH_NAME_PATTERN.test(trimmed) ? trimmed : undefined;
}

function sanitizeElementsArray(rawElements: unknown): SanitizedElement[] | undefined {
  if (!Array.isArray(rawElements)) return undefined;
  const result: SanitizedElement[] = [];
  for (const item of rawElements) {
    if (!item || typeof item !== 'object') continue;
    const record = item as Record<string, unknown>;
    const rawTag = typeof record.tag_name === 'string' ? record.tag_name.trim() : '';
    if (!SAFE_TAG_NAME_PATTERN.test(rawTag)) continue;
    const nestedAttrs =
      record.attributes && typeof record.attributes === 'object'
        ? (record.attributes as Record<string, unknown>)
        : undefined;
    const phName = sanitizePhName(
      record['attr__data-ph-name'] ??
        record['data-ph-name'] ??
        nestedAttrs?.['attr__data-ph-name'] ??
        nestedAttrs?.['data-ph-name'],
    );
    const cleaned: SanitizedElement = { tag_name: rawTag.toLowerCase() };
    if (phName) {
      cleaned['attr__data-ph-name'] = phName;
    }
    result.push(cleaned);
  }
  return result.length > 0 ? result : undefined;
}

function formatElementsChain(elements: SanitizedElement[]): string {
  return elements
    .map((el) => {
      const phName = el['attr__data-ph-name'];
      return phName ? `${el.tag_name}:attr__data-ph-name="${phName}"` : `${el.tag_name}:`;
    })
    .join(';');
}

function splitElementsChainSegments(chain: string): string[] {
  const segments: string[] = [];
  let current = '';
  let inQuotes = false;
  let escaped = false;
  for (let i = 0; i < chain.length; i += 1) {
    const ch = chain[i];
    if (escaped) {
      current += ch;
      escaped = false;
      continue;
    }
    if (ch === '\\') {
      current += ch;
      escaped = true;
      continue;
    }
    if (ch === '"') {
      inQuotes = !inQuotes;
      current += ch;
      continue;
    }
    if (ch === ';' && !inQuotes) {
      segments.push(current);
      current = '';
      continue;
    }
    current += ch;
  }
  if (current) segments.push(current);
  return segments;
}

function sanitizeElementsChainString(rawChain: unknown): string | undefined {
  if (typeof rawChain !== 'string' || !rawChain.trim()) return undefined;
  const parsed: SanitizedElement[] = [];
  for (const segment of splitElementsChainSegments(rawChain)) {
    const tagMatch = /^([a-z][a-z0-9-]*)(?:[.:]|$)/i.exec(segment.trim());
    if (!tagMatch) continue;
    const tagName = tagMatch[1].toLowerCase();
    const attrMatch = /(?:^|[^a-z0-9_-])attr__data-ph-name="([^"]*)"/.exec(segment);
    const phName = attrMatch ? sanitizePhName(attrMatch[1]) : undefined;
    const cleaned: SanitizedElement = { tag_name: tagName };
    if (phName) {
      cleaned['attr__data-ph-name'] = phName;
    }
    parsed.push(cleaned);
  }
  return parsed.length > 0 ? formatElementsChain(parsed) : undefined;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

/**
 * Strict allowlist `before_send` hook. Rebuilds `properties` from an explicit
 * list of safe keys, scrubs `$pathname`/`$current_url`/`$host`, drops blocked
 * event types (`$exception`, `$web_vitals`, `$identify`, etc.), strips `$set`
 * and `$set_once`, and strips all autocapture attributes/text/hrefs except
 * element tag names and explicit `data-ph-name` labels.
 */
export function createBeforeSend(options: {
  projectKey?: string;
  surface?: AnalyticsSurface;
} = {}): (event: CaptureResult | null) => CaptureResult | null {
  return (event) => {
    if (!event) return null;
    if (DROPPED_EVENT_TYPES.has(event.event)) {
      return null;
    }

    const rawProps = (event.properties ?? {}) as Record<string, unknown>;
    const surface: AnalyticsSurface | undefined =
      options.surface ??
      (rawProps.surface === 'employee' || rawProps.surface === 'staff' ? rawProps.surface : undefined);

    const out: Record<string, unknown> = {};

    // Preserve PostHog's own top-level ingestion project token so posthog-js 1.399.2
    // does not drop the event (`k = ["token"]` ingestion requirement).
    if (
      typeof rawProps.token === 'string' &&
      Boolean(options.projectKey) &&
      rawProps.token === options.projectKey
    ) {
      out.token = rawProps.token;
    }

    if (typeof rawProps.$pathname === 'string') {
      out.$pathname = scrubPathname(rawProps.$pathname, { surface });
    }

    if (typeof rawProps.$current_url === 'string') {
      const scrubbedCurrentUrl = scrubUrl(rawProps.$current_url, { surface });
      if (scrubbedCurrentUrl) {
        out.$current_url = scrubbedCurrentUrl;
      }
    }

    if (typeof rawProps.$host === 'string' && rawProps.$host.trim()) {
      out.$host = redactHost(rawProps.$host.trim(), surface);
    }

    for (const key of STRING_ALLOWLIST_KEYS) {
      const val = rawProps[key];
      if (typeof val === 'string' && val.length > 0) {
        out[key] = val;
      }
    }

    const browserVersion = rawProps.$browser_version;
    if (
      (typeof browserVersion === 'string' && browserVersion.length > 0) ||
      isFiniteNumber(browserVersion)
    ) {
      out.$browser_version = browserVersion;
    }

    for (const key of NUMBER_ALLOWLIST_KEYS) {
      const val = rawProps[key];
      if (isFiniteNumber(val)) {
        out[key] = val;
      }
    }

    for (const [key, val] of Object.entries(rawProps)) {
      if (VIEWPORT_KEY_PATTERN.test(key) && isFiniteNumber(val)) {
        out[key] = val;
      }
    }

    // Preserve personless flag (`false` only) so PostHog never creates person profiles.
    if (rawProps.$process_person_profile === false) {
      out.$process_person_profile = false;
    }

    // Our own super properties: `surface` and (on staff only) `role`.
    if (rawProps.surface === 'staff' || rawProps.surface === 'employee') {
      out.surface = rawProps.surface;
    } else if (options.surface) {
      out.surface = options.surface;
    }

    if (surface !== 'employee' && typeof rawProps.role === 'string' && rawProps.role.trim()) {
      out.role = rawProps.role.trim();
    }

    // Autocapture: keep ONLY element tag names and explicit `data-ph-name` labels.
    // Never keep `href`, `$el_text`, classes, IDs, or any other attributes.
    if (AUTOCAPTURE_EVENT_TYPES.has(event.event)) {
      const sanitizedElements = sanitizeElementsArray(rawProps.$elements);
      if (sanitizedElements) {
        out.$elements = sanitizedElements;
        out.$elements_chain = formatElementsChain(sanitizedElements);
      } else {
        const sanitizedChain = sanitizeElementsChainString(rawProps.$elements_chain);
        if (sanitizedChain) {
          out.$elements_chain = sanitizedChain;
        }
      }
    }

    const next: CaptureResult = {
      uuid: event.uuid,
      event: event.event,
      properties: out,
    };
    if (event.timestamp !== undefined) {
      next.timestamp = event.timestamp;
    }
    return next;
  };
}

let activeSurface: AnalyticsSurface = currentSurface();
let activeRole: string | null = null;

export function registerAnalyticsContext(
  client: Pick<PostHog, 'register' | 'unregister'> | null | undefined,
  params: { surface: AnalyticsSurface; role?: string | null },
): void {
  activeSurface = params.surface;
  activeRole = params.surface === 'staff' && params.role ? params.role : null;

  if (!client) return;
  if (typeof client.register === 'function') {
    if (activeRole) {
      client.register({ surface: activeSurface, role: activeRole });
    } else {
      client.register({ surface: activeSurface });
    }
  }
  if (!activeRole && typeof client.unregister === 'function') {
    client.unregister('role');
  }
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
    person_profiles: 'never',
    capture_pageview: false,
    capture_pageleave: true,
    capture_exceptions: false,
    capture_performance: false,
    capture_dead_clicks: false,
    capture_heatmaps: false,
    enable_heatmaps: false,
    disable_session_recording: true,
    disable_surveys: true,
    disable_surveys_automatic_display: true,
    disable_product_tours: true,
    disable_conversations: true,
    disable_web_experiments: true,
    disable_external_dependency_loading: true,
    disable_capture_url_hashes: true,
    disable_scroll_properties: true,
    opt_in_site_apps: false,
    advanced_disable_flags: true,
    advanced_disable_feature_flags: true,
    advanced_disable_feature_flags_on_first_load: true,
    advanced_disable_toolbar_metrics: true,
    remote_config_refresh_interval_ms: 0,
    save_referrer: false,
    save_campaign_params: false,
    autocapture: {
      css_selector_ignorelist: AUTOCAPTURE_IGNORE_SELECTORS,
    },
    rageclick: {
      css_selector_ignorelist: RAGECLICK_IGNORE_SELECTORS,
    },
    mask_all_text: true,
    mask_all_element_attributes: true,
    mask_personal_data_properties: true,
    custom_personal_data_properties: [
      '__clerk_ticket',
      '__clerk_status',
      '__clerk_created_session',
      '__clerk_db_jwt',
      'token',
      'code',
      'state',
      'email',
      'redirect_url',
      'redirect',
      'invite',
      'ticket',
      'signature',
      'sig',
      'key',
    ],
    ip: false,
    persistence: 'localStorage+cookie',
    respect_dnt: true,
    get_current_url: (defaultUrl: string) =>
      scrubUrl(defaultUrl, { surface }) ??
      (typeof window !== 'undefined' && window.location?.origin ? `${window.location.origin}/` : '/'),
    before_send: createBeforeSend({ projectKey, surface }),
    loaded: (ph) => {
      if (isDev || hasPrivacyOptOutSignal()) {
        ph.opt_out_capturing();
        return;
      }
      registerAnalyticsContext(ph, { surface, role: surface === 'staff' ? activeRole : null });
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

  const surface = options.surface ?? currentSurface(env);
  if (!isCustomCall) {
    activeSurface = surface;
  }

  targetClient.init(key, buildPostHogConfig({ env, surface }));
  if (!isCustomCall) {
    initialized = true;
  }
  return true;
}

export function resetAnalytics(
  client: Partial<Pick<PostHog, 'reset' | 'register' | 'unregister'>> | null | undefined = posthog,
  options: { surface?: AnalyticsSurface; keepRole?: boolean } = {},
): void {
  const isCustomClient = client !== posthog;
  if ((!isCustomClient && !isPostHogEnabled) || !client) return;

  const nextSurface = options.surface ?? activeSurface;
  const nextRole = options.keepRole && nextSurface === 'staff' ? activeRole : null;
  if (!options.keepRole) {
    activeRole = null;
  }

  if (typeof client.reset === 'function') {
    client.reset();
  }
  registerAnalyticsContext(
    client as Pick<PostHog, 'register' | 'unregister'>,
    { surface: nextSurface, role: nextRole },
  );
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
    ...(scrubbedCurrentUrl ? { $current_url: scrubbedCurrentUrl } : {}),
    $pathname: scrubbedPath,
    surface,
  });
}

function capture(event: string): void {
  if (isPostHogEnabled && !import.meta.env.DEV) {
    posthog.capture(event);
  }
}

export const analytics = {
  payrollCalculated: () => capture('payroll_calculated'),

  payrollApproved: () => capture('payroll_approved'),

  payrollCommitted: () => capture('payroll_committed'),

  checksDownloaded: () => capture('checks_downloaded'),

  checksPrinted: () => capture('checks_printed'),

  reportGenerated: () => capture('report_generated'),

  employeeCreated: () => capture('employee_created'),

  timecardUploaded: () => capture('timecard_uploaded'),

  timecardOcrApplied: () => capture('timecard_ocr_applied'),

  companySwitch: () => {
    resetAnalytics(posthog, { keepRole: true });
    capture('company_switched');
  },
};
