import { describe, expect, it } from 'vitest';
import { isPublicPath } from './public-routes';

describe('isPublicPath', () => {
  it('lets the legal pages render without waiting for sign-in', () => {
    expect(isPublicPath('/privacy')).toBe(true);
    expect(isPublicPath('/terms')).toBe(true);
    expect(isPublicPath('/privacy/')).toBe(true);
  });

  it('keeps the existing public pages and nothing else', () => {
    expect(['/', '/login', '/invite'].every(isPublicPath)).toBe(true);
    expect(isPublicPath('/app')).toBe(false);
    expect(isPublicPath('/privacy/extra')).toBe(false);
  });
});
