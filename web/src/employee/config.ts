import { clientSubdomainHost } from '@/lib/tenant-subdomain';

export const API_BASE_URL: string = import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1';
export const CLERK_PUBLISHABLE_KEY: string | undefined = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY || undefined;

// Read once at startup: in development `?tenantHost=` simulates a client
// subdomain, and the router drops the query string on the first navigation.
export const TENANT_HOST: string | null = typeof window === 'undefined'
  ? null : clientSubdomainHost(window.location, import.meta.env.DEV);

/** Today's date (YYYY-MM-DD) on this device, for former-access dates. */
export function today(): string {
  return new Date().toLocaleDateString('en-CA');
}
