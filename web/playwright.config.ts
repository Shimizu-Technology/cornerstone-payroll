import { refreshIssuer, refreshJwk } from './e2e/helpers/refresh-session';
import { defineConfig, devices } from '@playwright/test';
import { resolve } from 'node:path';

const refreshLane = process.env.E2E_REFRESH_LANE === 'true';
const refreshPublicJwk = refreshLane ? refreshJwk() : undefined;
const externalBaseUrl = process.env.E2E_BASE_URL;
const releaseLane = process.env.E2E_RELEASE_LANE === 'true' || process.env.E2E_REFRESH_LANE === 'true' || process.env.E2E_PAY_ITEMS_LANE === 'true';
const fixturePath = process.env.E2E_FIXTURE_PATH || resolve(process.cwd(),
  process.env.E2E_PAY_ITEMS_LANE === 'true' ? '.e2e-fixtures/pay-items.json'
    : process.env.E2E_REFRESH_LANE === 'true' ? '.e2e-fixtures/payroll-refresh.json' : '.e2e-fixtures/release.json');
const apiPort = process.env.E2E_API_PORT || '4317';
const webPort = process.env.E2E_WEB_PORT || (releaseLane ? '4318' : '4173');
const localBaseUrl = `http://127.0.0.1:${webPort}`;
// The employee surface (VITE_APP_SURFACE=employee) runs as its own dev server for public-employee-*.spec.ts.
const employeeWebPort = process.env.E2E_EMPLOYEE_WEB_PORT || '4175';
const localApiUrl = `http://127.0.0.1:${apiPort}`;

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  // The release lane mutates one shared, production-shaped fixture across a
  // deliberate lifecycle sequence. Keep it single-worker locally as well as in
  // CI so the standalone owner scenario cannot race the serial workflow suite.
  workers: releaseLane ? 1 : process.env.CI ? 3 : undefined,
  reporter: process.env.CI ? [['html', { open: 'never' }], ['github']] : 'list',
  use: {
    baseURL: externalBaseUrl || localBaseUrl,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    {
      name: 'public',
      use: { ...devices['Desktop Chrome'] },
      testMatch: /public-.*\.spec\.ts/,
    },
    // The employee app on phones. Chromium (Pixel) runs everywhere; WebKit
    // (iPhone) needs `npx playwright install webkit` and runs in CI.
    {
      name: 'employee-mobile',
      use: { ...devices['Pixel 7'] },
      testMatch: /employee-mobile-.*\.spec\.ts/,
    },
    {
      name: 'employee-mobile-webkit',
      use: { ...devices['iPhone 14'] },
      testMatch: /employee-mobile-.*\.spec\.ts/,
    },
    {
      name: 'gate0-release',
      use: { ...devices['Desktop Chrome'], timezoneId: 'Pacific/Guam' },
      testMatch: /gate0-payroll-release\.spec\.ts/,
      retries: 0,
    },
    {
      name: 'payroll-refresh',
      use: { ...devices['Desktop Chrome'], timezoneId: 'Pacific/Guam' },
      testMatch: /payroll-refresh-release\.spec\.ts/,
      retries: 0,
    },
    {
      name: 'pay-items',
      use: { ...devices['Desktop Chrome'], timezoneId: 'Pacific/Guam' },
      testMatch: /pay-item-workflow-release\.spec\.ts/,
      retries: 0,
    },
  ],
  webServer: externalBaseUrl
    ? undefined
    : [
        ...(releaseLane
          ? [{
              command: `cd ../api && bundle exec ${refreshLane ? 'ruby lib/payroll_refresh_qa_server.rb' : 'rails'} server --environment test --binding 127.0.0.1 --port ${apiPort} --pid tmp/pids/e2e-${apiPort}.pid`,
              url: `${localApiUrl}/up`,
              reuseExistingServer: false,
              timeout: 120_000,
              env: {
                ...process.env,
                RAILS_ENV: 'test',
                AUTH_ENABLED: refreshLane ? 'true' : 'false',
                ...(refreshPublicJwk ? {
                  CLERK_ISSUER: refreshIssuer,
                  CLERK_API_BASE: refreshIssuer,
                  CLERK_AUTHORIZED_PARTIES: localBaseUrl,
                  E2E_REFRESH_PUBLIC_JWK: JSON.stringify(refreshPublicJwk),
                } : {}),
                E2E_TEST_MODE: 'true',
                E2E_FIXTURE_PATH: fixturePath,
                CORS_ORIGINS: localBaseUrl,
              },
            }]
          : []),
        {
          command: `npm run dev -- --host 127.0.0.1 --port ${webPort} --strictPort`,
          url: localBaseUrl,
          reuseExistingServer: !process.env.CI,
          env: {
            ...process.env,
            VITE_API_URL: `${localApiUrl}/api/v1`,
            VITE_AUTH_ENABLED: 'false',
            VITE_CLERK_PUBLISHABLE_KEY: '',
          },
        },
        ...(!releaseLane
          ? [{
              command: `npm run dev -- --host 127.0.0.1 --port ${employeeWebPort} --strictPort`,
              url: `http://127.0.0.1:${employeeWebPort}`,
              reuseExistingServer: !process.env.CI,
              env: {
                ...process.env,
                VITE_APP_SURFACE: 'employee',
                VITE_API_URL: `${localApiUrl}/api/v1`,
                VITE_CLERK_PUBLISHABLE_KEY: '',
              },
            }]
          : []),
      ],
});
