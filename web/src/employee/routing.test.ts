import { describe, expect, it } from 'vitest';
import { redirectTarget } from './routing';

describe('redirectTarget', () => {
  it('keeps same-site paths', () => {
    expect(redirectTarget({ from: '/claim' })).toBe('/claim');
    expect(redirectTarget({ from: '/pay/12?year=2026' })).toBe('/pay/12?year=2026');
  });

  it('refuses paths that would leave the site or loop', () => {
    for (const from of ['//evil.example', '/\\evil.example', 'https://evil.example', '/sign-in', null, 3]) {
      expect(redirectTarget({ from })).toBe('/');
    }
  });

  it('refuses control characters, which URL parsing drops to leave the site', () => {
    for (const from of ['/\t/evil.example', '/\n/evil.example', '/\r/evil.example', '/\u0000/evil.example', '/claim\u007f']) {
      expect(redirectTarget({ from })).toBe('/');
    }
  });
});
