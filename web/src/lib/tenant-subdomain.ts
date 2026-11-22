const clientHostname = /^(?!xn--)([a-z0-9][a-z0-9-]{1,38}[a-z0-9])\.shimizu-technology\.com$/;

// Keep aligned with TenantSubdomainRegistry::RESERVED_SLUGS in the API.
const reservedSlugs = new Set([
  'payroll', 'api', 'clerk', 'clkmail', 'accounts', 'www', 'staging', 'mail',
  'admin', 'app', 'my', 'status', 'docs', 'support', 'tax', 'aire', 'aire-api', 'plane', 'shimizu',
]);

export function clientSubdomainHost(location: Pick<Location, 'hostname' | 'search'>, development = false): string | null {
  const hostname = location.hostname.toLowerCase().replace(/\.$/, '');
  const local = hostname === 'localhost' || hostname === '127.0.0.1';
  const simulatedHost = development && local ? new URLSearchParams(location.search).get('tenantHost') : null;
  const host = simulatedHost?.toLowerCase().replace(/\.$/, '') ?? hostname;
  const slug = clientHostname.exec(host)?.[1];
  return slug && !reservedSlugs.has(slug) ? host : null;
}
