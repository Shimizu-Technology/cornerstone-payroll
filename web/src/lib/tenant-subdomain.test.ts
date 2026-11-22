import { describe, expect, it } from 'vitest';
import { clientSubdomainHost } from './tenant-subdomain';

describe('clientSubdomainHost', () => {
  it('routes a one-label client host to the public shell', () => {
    expect(clientSubdomainHost({ hostname: 'mosas.shimizu-technology.com', search: '' }))
      .toBe('mosas.shimizu-technology.com');
  });

  it.each([
    'payroll.shimizu-technology.com',
    'shimizu-technology.com',
    'evil-shimizu-technology.com',
    'mosas.shimizu-technology.com.evil.com',
    'extra.mosas.shimizu-technology.com',
    'cornerstone-payroll.netlify.app',
    'localhost',
  ])('keeps %s on the existing app path', (hostname) => {
    expect(clientSubdomainHost({ hostname, search: '' })).toBeNull();
  });

  it('simulates a tenant through the query string only in local development', () => {
    const search = '?tenantHost=demo.shimizu-technology.com';
    expect(clientSubdomainHost({ hostname: 'localhost', search }, true)).toBe('demo.shimizu-technology.com');
    expect(clientSubdomainHost({ hostname: 'localhost', search })).toBeNull();
    expect(clientSubdomainHost({ hostname: 'payroll.shimizu-technology.com', search }, true)).toBeNull();
  });
});
