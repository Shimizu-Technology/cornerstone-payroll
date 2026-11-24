import { clientSubdomainHost } from '@/lib/tenant-subdomain';

export const API_BASE_URL: string = import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1';
export const CLERK_PUBLISHABLE_KEY: string | undefined = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY || undefined;

// Read once at startup: in development `?tenantHost=` simulates a client
// subdomain, and the router drops the query string on the first navigation.
export const TENANT_HOST: string | null = typeof window === 'undefined'
  ? null : clientSubdomainHost(window.location, import.meta.env.DEV);

/** The client slug ("mosas" on mosas.shimizu-technology.com), or null on any other host. */
export const TENANT_SLUG: string | null = TENANT_HOST ? TENANT_HOST.split('.')[0] : null;

/** Today's date (YYYY-MM-DD) on this device, for former-access dates. */
export function today(): string {
  return new Date().toLocaleDateString('en-CA');
}

export interface TermsConfig {
  /** Recorded with each sign-up and claim (§8a). */
  version: string;
  termsUrl: string;
  privacyUrl: string;
}

function documentUrl(value: string | undefined): string | null {
  if (!value) return null;
  if (value.startsWith('/') && !value.startsWith('//')) return value;
  try {
    return new URL(value).protocol === 'https:' ? value : null;
  } catch {
    return null;
  }
}

function termsFrom(env: Record<string, string | undefined>): TermsConfig | null {
  const version = env.VITE_EMPLOYEE_TERMS_VERSION?.trim();
  const termsUrl = documentUrl(env.VITE_EMPLOYEE_TERMS_URL?.trim());
  const privacyUrl = documentUrl(env.VITE_EMPLOYEE_PRIVACY_URL?.trim());
  return version && termsUrl && privacyUrl ? { version, termsUrl, privacyUrl } : null;
}

/**
 * Counsel's Employee App Terms and Privacy Notice (G1). Until all three
 * settings exist, the clickwrap checkbox and the links stay hidden, and
 * sign-up records no terms version.
 */
export const TERMS: TermsConfig | null = termsFrom(import.meta.env);

export { termsFrom };
