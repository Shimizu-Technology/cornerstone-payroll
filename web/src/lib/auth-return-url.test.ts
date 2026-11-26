// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest';
import {
  clearStoredAuthReturnPath,
  loginRedirectPath,
  readStoredAuthReturnPath,
  rememberAuthReturnPath,
  resolveAuthReturnPath,
  sanitizeAuthReturnPath,
} from './auth-return-url';

describe('auth-return-url same-site guard', () => {
  beforeEach(() => {
    window.sessionStorage.clear();
  });

  it('accepts valid same-site relative paths including query strings and hashes', () => {
    expect(sanitizeAuthReturnPath('/companies/42/pay-runs/99/overview')).toBe('/companies/42/pay-runs/99/overview');
    expect(sanitizeAuthReturnPath('/companies/42/pay-runs/99/work?tab=review#banner')).toBe(
      '/companies/42/pay-runs/99/work?tab=review#banner',
    );
    expect(resolveAuthReturnPath('/companies/7/pay-runs/12/overview')).toBe('/companies/7/pay-runs/12/overview');
  });

  it.each([
    ['null', null],
    ['empty string', ''],
    ['plain host without leading slash', 'evil.com/companies/1'],
    ['absolute https URL', 'https://evil.com/companies/1/pay-runs/2'],
    ['absolute http URL', 'http://evil.com/companies/1'],
    ['protocol-relative URL', '//evil.com/companies/1'],
    ['triple slash', '///evil.com'],
    ['backslash open redirect', '/\\evil.com'],
    ['mixed backslash', '/companies/1\\evil'],
    ['javascript scheme', 'javascript:alert(1)'],
    ['data URI', 'data:text/html,<script>alert(1)</script>'],
    ['percent-encoded double slash', '/%2fevil.com'],
    ['percent-encoded uppercase double slash', '/%2F%2Fevil.com'],
    ['percent-encoded backslash', '/%5cevil.com'],
    ['malformed percent encoding', '/%E0%A4%A'],
    ['CRLF injection', '/companies/1\r\nLocation: https://evil.com'],
    ['tab control char', '/companies/1\t/pay-runs'],
    ['NUL byte', '/companies/1\u0000/pay-runs'],
    ['login redirect loop', '/login'],
    ['login with query', '/login?return_to=/app'],
    ['uppercase login loop', '/LOGIN/something'],
    ['dot-segment login loop', '/companies/../login'],
    ['invite path', '/invite?token=abc'],
    ['callback path', '/callback'],
    ['oversized URL', `/companies/1/${'a'.repeat(2100)}`],
  ])('rejects hostile or disallowed return URL: %s', (_label, candidate) => {
    expect(sanitizeAuthReturnPath(candidate)).toBeNull();
    expect(resolveAuthReturnPath(candidate)).toBe('/app');
  });

  it('builds a clean /login redirect URL preserving only safe non-default paths', () => {
    expect(loginRedirectPath({ pathname: '/companies/12/pay-runs/55/overview', search: '?v=2', hash: '#review' })).toBe(
      '/login?return_to=%2Fcompanies%2F12%2Fpay-runs%2F55%2Foverview%3Fv%3D2%23review',
    );
    expect(loginRedirectPath({ pathname: '/app', search: '', hash: '' })).toBe('/login');
    expect(loginRedirectPath({ pathname: '/login', search: '?return_to=/app', hash: '' })).toBe('/login');
  });

  it('stores and re-sanitizes return paths in sessionStorage', () => {
    rememberAuthReturnPath('/companies/12/pay-runs/55/overview');
    expect(readStoredAuthReturnPath()).toBe('/companies/12/pay-runs/55/overview');

    window.sessionStorage.setItem('cornerstone_auth_return_to', '//evil.com/phish');
    expect(readStoredAuthReturnPath()).toBeNull();

    rememberAuthReturnPath('https://evil.com');
    expect(readStoredAuthReturnPath()).toBeNull();

    rememberAuthReturnPath('/companies/12/pay-runs/55/work');
    clearStoredAuthReturnPath();
    expect(readStoredAuthReturnPath()).toBeNull();
  });
});
