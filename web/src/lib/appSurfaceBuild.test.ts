/** @vitest-environment node */
import { afterEach, describe, expect, it, vi } from 'vitest';
import { build, type ConfigEnv, type UserConfig } from 'vite';
import viteConfig from '../../vite.config';

const resolveConfig = viteConfig as (input: ConfigEnv) => UserConfig;

afterEach(() => vi.unstubAllEnvs());

describe('application surface build', () => {
  it.each(['', 'payroll', 'Staff', 'employee '])('rejects invalid surface %j', (surface) => {
    vi.stubEnv('VITE_APP_SURFACE', surface);
    expect(() => resolveConfig({ mode: 'test', command: 'serve' })).toThrow(/VITE_APP_SURFACE must be staff or employee/);
  });

  it('accepts App imports with and without the TSX extension', () => {
    vi.stubEnv('VITE_APP_SURFACE', 'employee');
    const aliases = resolveConfig({ mode: 'test', command: 'serve' }).resolve?.alias;
    const employeeAlias = Array.isArray(aliases) && aliases.find(({ find }) => find instanceof RegExp);
    expect(employeeAlias && './App'.match(employeeAlias.find)).toBeTruthy();
    expect(employeeAlias && './App.tsx'.match(employeeAlias.find)).toBeTruthy();
  });

  it('emits the employee entry without staff code, PostHog, a service worker or dev-only code', async () => {
    // Vitest runs with NODE_ENV=test, which would build with import.meta.env.DEV on.
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('VITE_APP_SURFACE', 'employee');
    vi.stubEnv('DEPLOYMENT_ENV', 'production');
    vi.stubEnv('VITE_DEPLOYMENT_ENV', 'production');
    // A synthetic live key (base64 of "clerk.example.com$"), so this is the bundle a
    // real employee site ships, with Clerk in it, and not the no-key fallback.
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_live_Y2xlcmsuZXhhbXBsZS5jb20k');

    const modules: string[] = [];
    const code: string[] = [];
    let html = '';
    let css = '';
    await build({
      logLevel: 'silent',
      build: { write: false },
      plugins: [{
        name: 'collect-surface-modules',
        enforce: 'post',
        generateBundle(_options, bundle) {
          for (const entry of Object.values(bundle)) {
            if (entry.type === 'chunk') {
              // Count only modules that left code in the output, not ones tree-shaken to nothing.
              modules.push(...Object.entries(entry.modules).filter(([, info]) => info.renderedLength > 0).map(([id]) => id));
              code.push(entry.code);
            } else if (entry.fileName === 'index.html') {
              html = String(entry.source);
            } else if (entry.fileName.endsWith('.css')) {
              css += String(entry.source);
            }
          }
        },
      }],
    });

    expect(modules).toContainEqual(expect.stringMatching(/\/src\/EmployeeApp\.tsx$/));
    expect(modules).toContainEqual(expect.stringMatching(/\/src\/employee\/api\.ts$/));
    expect(modules).toContainEqual(expect.stringMatching(/\/src\/employee\/ClerkAuth\.tsx$/));
    expect(modules).toContainEqual(expect.stringMatching(/node_modules\/@clerk\/react\//));
    // Staff entry, pages, API client, contexts, layout and analytics stay out.
    expect(modules).not.toContainEqual(expect.stringMatching(
      /\/src\/(?:main\.tsx|App\.tsx|pages\/|services\/|contexts\/|providers\/|components\/(?:layout|routing|auth)\/)/,
    ));
    expect(modules).not.toContainEqual(expect.stringMatching(/posthog/i));
    expect(modules).not.toContainEqual(expect.stringMatching(/\/src\/employee\/DevPreviewAuth\.tsx$/));

    const bundled = code.join('\n');
    expect(bundled).not.toMatch(/posthog/i);
    expect(bundled).not.toMatch(/serviceWorker/);
    expect(bundled).not.toMatch(/dev-preview|previewViewAs/);

    // Its own Tailwind root: employee styles in, staff-only styles out.
    expect(css).toContain('.emp-shell');
    expect(css).not.toMatch(/reports-tables|invoice-action-panel|cornerstone-sign-in/);

    expect(html).toContain('/assets/');
    expect(html).toContain('viewport-fit=cover');
    expect(html).toContain('<meta name="robots" content="noindex, nofollow" />');
    expect(html).not.toMatch(/manifest|og:image|application\/ld\+json|Guam-Native Payroll Software/);
  }, 30_000);
});
