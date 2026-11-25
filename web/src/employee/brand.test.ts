/** @vitest-environment node */
import { describe, expect, it, vi } from 'vitest';
import {
  accentPair, actionColorFor, askManager, brandFrom, brandStyle, contrastRatio, contrastWithWhite, FALLBACK_BRAND_COLOR,
  employerBrand, FALLBACK_BRAND_NAME, fetchTenantBranding, INK, isLightColor, NEUTRAL_ACTION_COLOR, pageTitle, possessive, readableBrandColor,
} from './brand';

describe('brand color contrast', () => {
  it('leaves a color that already passes 4.5:1 alone', () => {
    expect(readableBrandColor('#b3261e')).toEqual({ color: '#b3261e', adjusted: false });
  });

  it.each(['#1898cf', '#f97316', '#ee5e25', '#10b981'])('darkens mid-tone %s until white text passes 4.5:1', (hex) => {
    const { color, adjusted } = actionColorFor(hex);
    expect(adjusted).toBe(true);
    expect(contrastWithWhite(color)).toBeGreaterThanOrEqual(4.5);
    expect(color).not.toBe(NEUTRAL_ACTION_COLOR);
  });

  it('keeps the hue roughly the same when darkening', () => {
    const { color } = actionColorFor('#f97316');
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(color.slice(i, i + 2), 16));
    expect(r).toBeGreaterThan(g);
    expect(g).toBeGreaterThan(b);
  });

  it.each(['#fadf06', '#ffd54f', '#7dd3fc', '#ffffff'])('never puts white text on light %s: buttons go neutral', (hex) => {
    expect(isLightColor(hex)).toBe(true);
    expect(actionColorFor(hex)).toEqual({ color: NEUTRAL_ACTION_COLOR, adjusted: true });
  });

  it('pairs an accent with text that passes 4.5:1, dark text first', () => {
    expect(accentPair('#fadf06')).toEqual({ accent: '#fadf06', ink: INK });
    expect(accentPair('#173f89')).toEqual({ accent: '#173f89', ink: '#ffffff' });
    const mid = accentPair('#e05281');
    expect(mid.ink).toBe(INK);
    expect(contrastRatio(mid.accent, INK)).toBeGreaterThanOrEqual(4.5);
  });
});

describe('brandFrom', () => {
  it('turns a mid-tone logo blue into decoration plus a darker action shade', () => {
    // MoSa's logo blue and yellow (UX audit). White on #1898CF is 3.27:1.
    const brand = brandFrom({ name: "MoSa's", logo_url: 'https://cdn.example.com/logo.png', primary_color: '#1898CF', accent_color: '#FADF06' });
    expect(brand).toMatchObject({
      name: "MoSa's", logoUrl: 'https://cdn.example.com/logo.png', monogram: 'M', isFallback: false,
      decoration: '#1898cf', indicator: '#1898cf', actionAdjusted: true, accent: '#fadf06', accentInk: INK,
    });
    expect(contrastWithWhite(brand.action)).toBeGreaterThanOrEqual(4.5);
  });

  it('uses a light primary only as an accent with dark text', () => {
    const brand = brandFrom({ name: 'Pelican Row Bakery', logo_url: null, primary_color: '#FADF06', accent_color: null });
    expect(brand.action).toBe(NEUTRAL_ACTION_COLOR);
    expect(brand.indicator).toBe(NEUTRAL_ACTION_COLOR);
    expect(brand).toMatchObject({ decoration: '#fadf06', accent: '#fadf06', accentInk: INK });
  });

  it('falls back to a neutral Cornerstone Payroll brand', () => {
    const brand = brandFrom(null);
    expect(brand).toMatchObject({ name: FALLBACK_BRAND_NAME, logoUrl: null, action: FALLBACK_BRAND_COLOR, monogram: 'C', isFallback: true });
    expect(contrastWithWhite(brand.action)).toBeGreaterThanOrEqual(4.5);
    expect(contrastRatio(brand.accent, brand.accentInk)).toBeGreaterThanOrEqual(4.5);
  });

  it('ignores a malformed color or a non-HTTPS logo', () => {
    const brand = brandFrom({ name: 'Pelican Row Bakery', logo_url: 'http://insecure.example.com/logo.png', primary_color: 'red', accent_color: 'blue' });
    expect(brand.action).toBe(FALLBACK_BRAND_COLOR);
    expect(brand.logoUrl).toBeNull();
  });

  it('treats a blank name as no branding at all', () => {
    const brand = brandFrom({ name: '   ', logo_url: 'https://cdn.example.com/logo.png', primary_color: '#b3261e', accent_color: null });
    expect(brand).toMatchObject({ name: FALLBACK_BRAND_NAME, isFallback: true, logoUrl: null, action: FALLBACK_BRAND_COLOR });
  });

  it('exposes every role as a CSS variable', () => {
    expect(Object.keys(brandStyle(brandFrom(null)))).toEqual(['--action', '--action-tint', '--brand', '--indicator', '--accent', '--accent-ink']);
  });
});

describe('copy helpers', () => {
  it.each([
    ["MoSa's", "MoSa's"],
    ['MoSa’s', 'MoSa’s'],
    ['Pelican Row Bakery', "Pelican Row Bakery's"],
    ['Two Brothers', "Two Brothers'"],
    ['  Cornerstone ', "Cornerstone's"],
  ])('possessive(%j) is %j', (name, expected) => {
    expect(possessive(name)).toBe(expected);
  });

  it('names the employer only when branding loaded', () => {
    expect(askManager(brandFrom({ name: "MoSa's", logo_url: null, primary_color: null, accent_color: null }))).toBe("Ask your manager at MoSa's.");
    expect(askManager(brandFrom(null))).toBe('Ask your manager.');
  });

  it('titles pages without a doubled possessive', () => {
    expect(pageTitle('Pay stubs', brandFrom({ name: "MoSa's", logo_url: null, primary_color: null, accent_color: null }))).toBe("Pay stubs · MoSa's employee app");
    expect(pageTitle('Help', brandFrom({ name: 'Pelican Row Bakery', logo_url: null, primary_color: null, accent_color: null }))).toBe("Help · Pelican Row Bakery's employee app");
    expect(pageTitle('Help', brandFrom(null))).toBe('Help · Cornerstone Payroll');
    expect(pageTitle('Help', brandFrom({ name: "MoSa's", app_name: "MoSa's Team", logo_url: null, primary_color: null, accent_color: null }))).toBe("Help · MoSa's Team");
  });
});

describe('fetchTenantBranding', () => {
  const baseUrl = 'https://api.example.test/api/v1';

  it('asks for the host without credentials or caching', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => Response.json({ name: "MoSa's", logo_url: null, primary_color: '#b3261e', accent_color: null }));
    const branding = await fetchTenantBranding('mosas.shimizu-technology.com', { baseUrl, fetchImpl });

    const [url, init] = fetchImpl.mock.calls[0];
    expect(String(url)).toBe('https://api.example.test/api/v1/public/tenant_branding?host=mosas.shimizu-technology.com');
    expect(init).toMatchObject({ credentials: 'omit', cache: 'no-store' });
    expect(branding?.name).toBe("MoSa's");
  });

  it.each([
    ['a 404', async () => new Response(null, { status: 404 })],
    ['a server error', async () => new Response(null, { status: 500 })],
    ['a network failure', async () => { throw new TypeError('Failed to fetch'); }],
    ['a body without a name', async () => Response.json({ logo_url: null })],
    ['a color that isn\'t a string', async () => Response.json({ name: 'Acme', logo_url: null, primary_color: ['#1898cf'], accent_color: null })],
    ['a logo that isn\'t a string', async () => Response.json({ name: 'Acme', logo_url: { href: 'https://x' }, primary_color: null, accent_color: null })],
    ['an array body', async () => Response.json([{ name: 'Acme' }])],
  ])('returns null when branding is unavailable for %s', async (_label, impl) => {
    expect(await fetchTenantBranding('mosas.shimizu-technology.com', { baseUrl, fetchImpl: vi.fn<typeof fetch>(impl) })).toBeNull();
  });
});

describe('employerBrand', () => {
  it('names the chosen employer on the shared host, keeping the neutral colors and no phone', () => {
    const shared = brandFrom(null);
    const chosen = employerBrand(shared, 'Pelican Row Bakery');
    expect(chosen).toMatchObject({ name: 'Pelican Row Bakery', isFallback: false, mainPhone: null, logoUrl: null, action: shared.action });
    expect(chosen.monogram).not.toBe(shared.monogram);
  });

  it('never replaces a client subdomain\'s own branding, or names a blank employer', () => {
    const client = brandFrom({ name: "MoSa's", logo_url: null, primary_color: null, accent_color: null });
    expect(employerBrand(client, 'Coral Kitchen')).toBe(client);
    expect(employerBrand(brandFrom(null), '  ')).toEqual(brandFrom(null));
  });
});
