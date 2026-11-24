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
  renderHeaders,
} from '../../scripts/finalize-surface-dist.mjs';

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const deployDir = path.join(webDir, 'deploy', 'employee');
const read = (...parts: string[]) => readFileSync(path.join(webDir, ...parts), 'utf8');
const publishableKey = (host: string, prefix = 'pk_live_') => `${prefix}${Buffer.from(`${host}$`).toString('base64')}`;
const env = {
  VITE_API_URL: 'https://employee-api.example.test/api/v1',
  VITE_CLERK_PUBLISHABLE_KEY: publishableKey('clerk.shimizu-technology.com'),
};
const tempDirs: string[] = [];
const tempDir = () => {
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

    expect(directive('script-src')).toBe("script-src 'self' https://clerk.shimizu-technology.com https://challenges.cloudflare.com");
    expect(directive('connect-src')).toContain('https://employee-api.example.test');
    expect(directive('connect-src')).toContain('https://clerk.shimizu-technology.com');
    expect(directive('frame-ancestors')).toBe("frame-ancestors 'none'");
    expect(directive('object-src')).toBe("object-src 'none'");
    expect(csp).not.toMatch(/unsafe-eval|\*|script-src[^;]*unsafe-inline/);
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

    finalizeEmployeeDist({ distDir: dist, deployDir, env });

    expect(readFileSync(path.join(dist, '_headers'), 'utf8')).toContain('https://employee-api.example.test');
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
