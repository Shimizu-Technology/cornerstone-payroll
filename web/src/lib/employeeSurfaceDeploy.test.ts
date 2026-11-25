/** @vitest-environment node */
import { afterEach, describe, expect, it, vi } from 'vitest';
import { build } from 'vite';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  apiOrigin,
  clerkFrontendOrigin,
  contentSecurityPolicy,
  finalizeEmployeeDist,
  main,
  posthogOrigins,
  renderHeaders,
} from '../../scripts/finalize-surface-dist.mjs';

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const deployDir = path.join(webDir, 'deploy', 'employee');
const read = (...parts: string[]): string => readFileSync(path.join(webDir, ...parts), 'utf8');
const publishableKey = (host: string, prefix = 'pk_live_'): string => `${prefix}${Buffer.from(`${host}$`).toString('base64')}`;
const env = {
  VITE_API_URL: 'https://employee-api.example.test/api/v1',
  VITE_CLERK_PUBLISHABLE_KEY: publishableKey('clerk.shimizu-technology.com'),
};
const tempDirs: string[] = [];
const tempDir = (): string => {
  const dir = mkdtempSync(path.join(tmpdir(), 'employee-dist-'));
  tempDirs.push(dir);
  return dir;
};

afterEach(() => {
  vi.unstubAllEnvs();
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe('employee site deploy files', () => {
  it('reads the origins the browser must be allowed to reach', () => {
    expect(apiOrigin('https://employee-api.example.test/api/v1')).toBe('https://employee-api.example.test');
    expect(clerkFrontendOrigin(env.VITE_CLERK_PUBLISHABLE_KEY)).toBe('https://clerk.shimizu-technology.com');
    expect(clerkFrontendOrigin(publishableKey('Quiet-Cat-1.clerk.accounts.dev', 'pk_test_'))).toBe('https://quiet-cat-1.clerk.accounts.dev');
  });

  it('refuses a development key for a production build but allows it elsewhere', () => {
    const devKey = publishableKey('quiet-cat-1.clerk.accounts.dev', 'pk_test_');
    expect(() => clerkFrontendOrigin(devKey, { production: true })).toThrow(/pk_live_/);
    expect(clerkFrontendOrigin(devKey, { production: false })).toBe('https://quiet-cat-1.clerk.accounts.dev');
    expect(clerkFrontendOrigin(env.VITE_CLERK_PUBLISHABLE_KEY, { production: true })).toBe('https://clerk.shimizu-technology.com');

    const dist = tempDir();
    writeFileSync(path.join(dist, 'index.html'), '<html></html>');
    expect(() => finalizeEmployeeDist({ distDir: dist, deployDir, env: { ...env, VITE_DEPLOYMENT_ENV: 'production', VITE_CLERK_PUBLISHABLE_KEY: devKey } }))
      .toThrow(/pk_live_/);
  });

  // Hosts the API's ClerkTokenVerifier::HOSTNAME_PATTERN rejects must not reach the CSP either.
  it.each([
    'clerk.shimizu-technology.com/path', 'clerk.shimizu-technology.com:8443', 'localhost', '-bad.example.com', 'bad-.example.com',
    'a b.example.com', 'clerk..example.com', 'clerk.example.com;script-src *', '*.example.com', `${'a'.repeat(64)}.example.com`,
  ])('refuses decoded Clerk host %j', (host) => {
    expect(() => clerkFrontendOrigin(publishableKey(host))).toThrow(/VITE_CLERK_PUBLISHABLE_KEY/);
  });

  it('refuses a decoded host with extra text after the trailing $', () => {
    expect(() => clerkFrontendOrigin(`pk_live_${Buffer.from('clerk.example.com$extra').toString('base64')}`)).toThrow(/VITE_CLERK_PUBLISHABLE_KEY/);
    expect(() => clerkFrontendOrigin(`pk_live_${Buffer.from('clerk.example.com$$').toString('base64')}`)).toThrow(/VITE_CLERK_PUBLISHABLE_KEY/);
  });

  it.each([undefined, '', 'http://employee-api.example.test', '/api/v1', 'https://user:pw@employee-api.example.test'])(
    'refuses API URL %j',
    (value) => expect(() => apiOrigin(value)).toThrow(/VITE_API_URL/),
  );

  it.each([undefined, '', 'pk_live_', 'sk_live_abc', 'pk_live_!!!', `pk_live_${Buffer.from('no-dollar').toString('base64')}`])(
    'refuses Clerk key %j',
    (value) => expect(() => clerkFrontendOrigin(value)).toThrow(/VITE_CLERK_PUBLISHABLE_KEY/),
  );

  it('builds a strict policy with only the API and Clerk origins', () => {
    const csp = contentSecurityPolicy({ apiOrigin: 'https://employee-api.example.test', clerkOrigin: 'https://clerk.shimizu-technology.com' });
    const directive = (name: string) => csp.split('; ').find((part) => part.startsWith(`${name} `)) ?? '';

    expect(directive('script-src')).toBe(
      "script-src 'self' https://clerk.shimizu-technology.com https://challenges.cloudflare.com https://*.protect.clerk.com",
    );
    expect(directive('connect-src')).toContain('https://employee-api.example.test');
    expect(directive('connect-src')).toContain('https://clerk.shimizu-technology.com');
    expect(directive('frame-ancestors')).toBe("frame-ancestors 'none'");
    expect(directive('object-src')).toBe("object-src 'none'");
    expect(csp).not.toMatch(/unsafe-eval|script-src[^;]*unsafe-inline/);
    expect(csp).not.toContain('posthog.com');
  });

  it('adds exact PostHog origins to script-src and connect-src only when PostHog is enabled', () => {
    expect(posthogOrigins({})).toBeNull();
    expect(posthogOrigins({ VITE_PUBLIC_POSTHOG_ENABLED: 'false', VITE_PUBLIC_POSTHOG_KEY: 'phc_test' })).toBeNull();
    expect(posthogOrigins({ VITE_PUBLIC_POSTHOG_ENABLED: 'true', VITE_PUBLIC_POSTHOG_KEY: 'YOUR_POSTHOG_KEY' })).toBeNull();
    expect(
      posthogOrigins({
        VITE_DEPLOYMENT_ENV: 'staging',
        VITE_PUBLIC_POSTHOG_ENABLED: 'true',
        VITE_PUBLIC_POSTHOG_KEY: 'phc_test',
      }),
    ).toBeNull();

    const us = posthogOrigins({ VITE_PUBLIC_POSTHOG_ENABLED: 'true', VITE_PUBLIC_POSTHOG_KEY: 'phc_test' });
    expect(us).toEqual({
      apiOrigin: 'https://us.i.posthog.com',
      assetsOrigin: 'https://us-assets.i.posthog.com',
    });

    expect(
      posthogOrigins({
        VITE_PUBLIC_POSTHOG_ENABLED: 'true',
        VITE_PUBLIC_POSTHOG_KEY: 'phc_test',
        VITE_PUBLIC_POSTHOG_HOST: 'https://eu.i.posthog.com',
      }),
    ).toEqual({
      apiOrigin: 'https://eu.i.posthog.com',
      assetsOrigin: 'https://eu-assets.i.posthog.com',
    });

    expect(
      posthogOrigins({
        VITE_PUBLIC_POSTHOG_ENABLED: 'true',
        VITE_PUBLIC_POSTHOG_KEY: 'phc_test',
        VITE_PUBLIC_POSTHOG_HOST: 'https://analytics.shimizu-technology.com/ingest',
      }),
    ).toEqual({
      apiOrigin: 'https://analytics.shimizu-technology.com',
      assetsOrigin: 'https://analytics.shimizu-technology.com',
    });

    for (const badHost of ['http://us.i.posthog.com', 'not-a-url', 'https://user:pw@us.i.posthog.com']) {
      expect(() =>
        posthogOrigins({
          VITE_PUBLIC_POSTHOG_ENABLED: 'true',
          VITE_PUBLIC_POSTHOG_KEY: 'phc_test',
          VITE_PUBLIC_POSTHOG_HOST: badHost,
        }),
      ).toThrow(/VITE_PUBLIC_POSTHOG_HOST/);
    }

    const csp = contentSecurityPolicy({
      apiOrigin: 'https://employee-api.example.test',
      clerkOrigin: 'https://clerk.shimizu-technology.com',
      posthog: us,
    });
    const directive = (name: string): string[] =>
      (csp.split('; ').find((part) => part.startsWith(`${name} `)) ?? '').split(' ').slice(1);

    expect(directive('script-src')).toContain('https://us-assets.i.posthog.com');
    expect(directive('script-src')).not.toContain('https://us.i.posthog.com');
    expect(directive('connect-src')).toContain('https://us.i.posthog.com');
    expect(directive('connect-src')).toContain('https://us-assets.i.posthog.com');
    expect(csp).not.toMatch(/unsafe-eval|script-src[^;]*unsafe-inline|https?:\/\/\*\.posthog\.com/);
  });

  // https://clerk.com/docs/guides/secure/best-practices/csp-headers
  it('allows the hosts Clerk documents for bot and fraud protection, and nothing broader', () => {
    const csp = contentSecurityPolicy({ apiOrigin: 'https://employee-api.example.test', clerkOrigin: 'https://clerk.shimizu-technology.com' });
    const directive = (name: string): string[] => (csp.split('; ').find((part) => part.startsWith(`${name} `)) ?? '').split(' ').slice(1);

    expect(directive('script-src')).toEqual(expect.arrayContaining(['https://challenges.cloudflare.com', 'https://*.protect.clerk.com']));
    expect(directive('frame-src')).toEqual(expect.arrayContaining(['https://challenges.cloudflare.com', 'https://*.protect.clerk.com']));
    expect(directive('connect-src')).toContain('https://*.protect.clerk.com:*');
    expect(directive('img-src')).toContain('https://img.clerk.com');
    expect(directive('worker-src')).toEqual(["'self'", 'blob:']);
    expect(directive('form-action')).toEqual(["'self'"]);

    // A bare `*` or any wildcard outside Clerk's own documented hosts would widen the policy.
    const documentedWildcards = ['https://*.protect.clerk.com', 'https://*.protect.clerk.com:*', 'https://*.clerk-telemetry.com'];
    const wildcards = csp.split(/[\s;]+/).filter((source) => source.includes('*'));
    expect(wildcards.length).toBeGreaterThan(0);
    for (const source of wildcards) expect(documentedWildcards).toContain(source);
    expect(csp).not.toMatch(/(^|[\s;])\*($|[\s;])|https?:\/\/\*(?!\.protect\.clerk\.com|\.clerk-telemetry\.com)/);
  });

  it('keeps the headers template to one block that sets no-store and the security headers', () => {
    const template = read('deploy', 'employee', '_headers.template');
    const rules = template.split('\n').filter((line) => line.startsWith('/'));
    expect(rules).toEqual(['/*']);
    const rendered = renderHeaders(template, { apiOrigin: 'https://employee-api.example.test', clerkOrigin: 'https://clerk.shimizu-technology.com' });
    for (const header of ['Content-Security-Policy', 'Strict-Transport-Security', 'X-Content-Type-Options: nosniff', 'X-Frame-Options: DENY',
      'Referrer-Policy: no-referrer', 'X-Robots-Tag: noindex, nofollow', 'Cache-Control: no-store']) {
      expect(rendered).toContain(header);
    }
    expect(rendered).not.toContain('{{');
  });

  it('serves only the app shell for unknown paths', () => {
    const rules = read('deploy', 'employee', '_redirects').split('\n').filter((line) => line.trim() && !line.startsWith('#'));
    expect(rules).toEqual(['/*    /index.html   200']);
  });

  it('writes headers and redirects and drops staff-only files from the output', () => {
    const dist = tempDir();
    for (const file of ['index.html', 'sw.js', 'offline.html', 'sitemap.xml', 'robots.txt', 'manifest.json']) writeFileSync(path.join(dist, file), 'staff');

    finalizeEmployeeDist({
      distDir: dist,
      deployDir,
      env: { ...env, VITE_PUBLIC_POSTHOG_ENABLED: 'true', VITE_PUBLIC_POSTHOG_KEY: 'phc_test' },
    });

    const headers = readFileSync(path.join(dist, '_headers'), 'utf8');
    expect(headers).toContain('https://employee-api.example.test');
    expect(headers).toContain('https://us.i.posthog.com');
    expect(headers).toContain('https://us-assets.i.posthog.com');
    expect(readFileSync(path.join(dist, '_redirects'), 'utf8')).toContain('/index.html   200');
    expect(readFileSync(path.join(dist, 'robots.txt'), 'utf8')).toContain('Disallow: /');
    for (const file of ['sw.js', 'offline.html', 'sitemap.xml']) expect(existsSync(path.join(dist, file))).toBe(false);
  });

  it('fails the employee build instead of shipping without its origins', () => {
    const dist = tempDir();
    writeFileSync(path.join(dist, 'index.html'), '<html></html>');
    expect(() => finalizeEmployeeDist({ distDir: dist, deployDir, env: { ...env, VITE_API_URL: undefined } })).toThrow(/VITE_API_URL/);
    expect(() => finalizeEmployeeDist({ distDir: tempDir(), deployDir, env })).toThrow(/No build output/);
  });

  it('does nothing for the staff surface', () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => undefined);
    expect(() => main({ VITE_APP_SURFACE: 'staff' })).not.toThrow();
    expect(() => main({})).not.toThrow();
    expect(log).toHaveBeenCalledTimes(2);
    log.mockRestore();
  });

  it('assembles a real employee build with its headers, redirects and no staff service worker', async () => {
    vi.stubEnv('VITE_APP_SURFACE', 'employee');
    vi.stubEnv('DEPLOYMENT_ENV', 'production');
    vi.stubEnv('VITE_DEPLOYMENT_ENV', 'production');
    const outDir = tempDir();
    await build({ logLevel: 'silent', build: { outDir, emptyOutDir: true } });
    expect(existsSync(path.join(outDir, 'sw.js'))).toBe(true);

    finalizeEmployeeDist({ distDir: outDir, deployDir, env });

    expect(existsSync(path.join(outDir, 'index.html'))).toBe(true);
    expect(existsSync(path.join(outDir, 'sw.js'))).toBe(false);
    expect(readFileSync(path.join(outDir, '_headers'), 'utf8')).toContain('Cache-Control: no-store');
    expect(existsSync(path.join(outDir, '_redirects'))).toBe(true);
  }, 60_000);
});

describe('shared Netlify configuration', () => {
  it('keeps one build for both sites and runs the finalize step after it', () => {
    const toml = read('netlify.toml');
    expect(toml).toContain('command = "npm run build"');
    expect(toml).toContain('publish = "dist"');
    expect(toml).toContain('ignore = "bash ./scripts/netlify-ignore-build.sh"');
    expect(toml).not.toMatch(/\[\[headers\]\]|\[\[redirects\]\]/);

    const scripts = JSON.parse(read('package.json')).scripts as Record<string, string>;
    expect(scripts.postbuild).toBe('node scripts/finalize-surface-dist.mjs');
  });

  it('leaves the Payroll site rules alone', () => {
    expect(read('public', '_redirects')).toContain('/*    /index.html   200');
    expect(existsSync(path.join(webDir, 'public', '_headers'))).toBe(false);
  });
});
