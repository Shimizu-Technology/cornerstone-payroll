// Hosted builds always use this domain. Only a local production copy
// (VITE_DEPLOYMENT_ENV=local) serves tenants under its own *.localhost domain.
export const DEFAULT_TENANT_ROOT_DOMAIN = 'shimizu-technology.com';
const localRootDomain = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+localhost$/;

type TenantEnv = { VITE_DEPLOYMENT_ENV?: string; VITE_TENANT_ROOT_DOMAIN?: string; [key: string]: unknown };

export function tenantRootDomain(env: TenantEnv = import.meta.env): string {
  const local = env.VITE_TENANT_ROOT_DOMAIN?.toLowerCase();
  return env.VITE_DEPLOYMENT_ENV === 'local' && local && localRootDomain.test(local) ? local : DEFAULT_TENANT_ROOT_DOMAIN;
}

// Keep aligned with TenantSubdomainRegistry::RESERVED_SLUGS in the API.
const reservedSlugs = new Set([
  'payroll', 'api', 'employee-api', 'clerk', 'clkmail', 'accounts', 'www', 'staging', 'mail',
  'admin', 'app', 'my', 'status', 'docs', 'support', 'tax', 'aire', 'aire-api', 'plane', 'shimizu',
]);

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^$|()[\]{}\\]/g, '\\$&');
}

export function clientSubdomainHost(
  location: Pick<Location, 'hostname' | 'search'>,
  development = false,
  rootDomain = tenantRootDomain(),
): string | null {
  const hostname = location.hostname.toLowerCase().replace(/\.$/, '');
  const local = hostname === 'localhost' || hostname === '127.0.0.1';
  const simulatedHost = development && local ? new URLSearchParams(location.search).get('tenantHost') : null;
  const host = simulatedHost?.toLowerCase().replace(/\.$/, '') ?? hostname;
  const clientHostname = new RegExp(`^(?!xn--)([a-z0-9][a-z0-9-]{1,38}[a-z0-9])\\.${escapeRegExp(rootDomain)}$`);
  const slug = clientHostname.exec(host)?.[1];
  return slug && !reservedSlugs.has(slug) ? host : null;
}
