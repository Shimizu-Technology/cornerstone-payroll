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

  it('emits the employee entry without importing staff or tenant branding modules', async () => {
    vi.stubEnv('VITE_APP_SURFACE', 'employee');
    vi.stubEnv('DEPLOYMENT_ENV', 'production');
    vi.stubEnv('VITE_DEPLOYMENT_ENV', 'production');

    const modules: string[] = [];
    await build({
      logLevel: 'silent',
      build: { write: false },
      plugins: [{
        name: 'collect-surface-modules',
        generateBundle(_options, bundle) {
          for (const entry of Object.values(bundle)) {
            if (entry.type === 'chunk') modules.push(...Object.keys(entry.modules));
          }
        },
      }],
    });

    expect(modules).toContainEqual(expect.stringMatching(/\/src\/EmployeeApp\.tsx$/));
    expect(modules).not.toContainEqual(expect.stringMatching(/\/src\/(?:main\.tsx|App\.tsx|pages\/|services\/api\.ts)/));
  }, 30_000);
});
