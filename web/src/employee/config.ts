import { clientSubdomainHost } from '@/lib/tenant-subdomain';
import { guamDay } from './contracts';

export const API_BASE_URL: string = import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1';
export const CLERK_PUBLISHABLE_KEY: string | undefined = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY || undefined;

// Read once at startup: in development `?tenantHost=` simulates a client
// subdomain, and the router drops the query string on the first navigation.
export const TENANT_HOST: string | null = typeof window === 'undefined'
  ? null : clientSubdomainHost(window.location, import.meta.env.DEV);

/** The client slug ("mosas" on mosas.shimizu-technology.com), or null on any other host. */
export const TENANT_SLUG: string | null = TENANT_HOST ? TENANT_HOST.split('.')[0] : null;

/**
 * Today in Guam (YYYY-MM-DD), for former-access dates and "In 9 days". Every
 * client is on Guam time, so a phone set to another zone (or a CI runner on
 * UTC) counts the same days.
 */
export function today(now: Date = new Date()): string {
  return guamDay(now);
}
