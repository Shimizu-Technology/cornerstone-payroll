const clientHostname = /^([a-z0-9-]+)\.shimizu-technology\.com$/;

export function clientSubdomainHost(location: Pick<Location, 'hostname' | 'search'>, development = false): string | null {
  const { hostname, search } = location;
  const local = hostname === 'localhost' || hostname === '127.0.0.1';
  const simulatedHost = development && local ? new URLSearchParams(search).get('tenantHost') : null;
  const host = simulatedHost ?? hostname;
  return host !== 'payroll.shimizu-technology.com' && clientHostname.test(host) ? host : null;
}
