/** @vitest-environment node */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { build, type Rollup } from 'vite';

afterEach(() => vi.unstubAllEnvs());

describe('contact details client bundle boundary', () => {
  it('excludes the staff shared-inbox report panel and its API wrapper from the EmployeeContactDetails module graph and production chunks', async () => {
    vi.stubEnv('VITE_APP_SURFACE', 'staff');
    vi.stubEnv('DEPLOYMENT_ENV', 'production');
    vi.stubEnv('VITE_DEPLOYMENT_ENV', 'production');

    // 1. Standalone Rollup graph starting at EmployeeContactDetails.tsx:
    // proves nothing in the client grid transitively imports staff report code.
    const gridModules: string[] = [];
    const gridCode: string[] = [];
    await build({
      logLevel: 'silent',
      build: {
        write: false,
        rollupOptions: {
          input: path.resolve(__dirname, './EmployeeContactDetails.tsx'),
        },
      },
      plugins: [{
        name: 'collect-client-grid-graph',
        generateBundle(_options, bundle) {
          for (const entry of Object.values(bundle)) {
            if (entry.type === 'chunk') {
              gridModules.push(...Object.keys(entry.modules));
              gridCode.push(entry.code);
            }
          }
        },
      }],
    });

    expect(gridModules).toContainEqual(expect.stringMatching(/\/src\/pages\/employees\/EmployeeContactDetails\.tsx$/));
    expect(gridModules).not.toContainEqual(expect.stringMatching(/SharedInboxReportPanel/));
    expect(gridModules).not.toContainEqual(expect.stringMatching(/staffContactHygieneApi/));
    expect(gridModules).not.toContainEqual(expect.stringMatching(/StaffEmployeeContactDetails/));
    expect(gridCode.join('\n')).not.toContain('employee_contact_hygiene');

    // 2. Full app build: confirms EmployeeContactDetails and SharedInboxReportPanel
    // land in separate chunks, and the client grid chunk does not reference the staff report chunk.
    const chunks = new Map<string, Rollup.OutputChunk>();
    await build({
      logLevel: 'silent',
      build: { write: false },
      plugins: [{
        name: 'collect-full-app-chunks',
        generateBundle(_options, bundle) {
          for (const [fileName, entry] of Object.entries(bundle)) {
            if (entry.type === 'chunk') chunks.set(fileName, entry);
          }
        },
      }],
    });

    const clientGridChunk = Array.from(chunks.values()).find((chunk) =>
      Object.keys(chunk.modules).some((id) => id.endsWith('/src/pages/employees/EmployeeContactDetails.tsx')),
    );
    const staffReportChunk = Array.from(chunks.values()).find((chunk) =>
      Object.keys(chunk.modules).some((id) => id.endsWith('/src/components/employees/SharedInboxReportPanel.tsx')),
    );

    expect(clientGridChunk).toBeDefined();
    expect(staffReportChunk).toBeDefined();
    expect(clientGridChunk!.fileName).not.toBe(staffReportChunk!.fileName);
    expect(clientGridChunk!.imports).not.toContain(staffReportChunk!.fileName);
    expect(clientGridChunk!.dynamicImports).not.toContain(staffReportChunk!.fileName);
    expect(clientGridChunk!.code).not.toContain('employee_contact_hygiene');

    // 3. Shared api.ts does not ship staff contact hygiene wrappers.
    const apiSource = readFileSync(path.resolve(__dirname, '../../services/api.ts'), 'utf8');
    expect(apiSource).not.toContain('employee_contact_hygiene');
  }, 60_000);
});
