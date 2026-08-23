import { defineConfig, devices } from '@playwright/test';
import { resolve } from 'node:path';

const externalBaseUrl = process.env.E2E_BASE_URL;
const releaseLane = process.env.E2E_RELEASE_LANE === 'true';
const fixturePath = process.env.E2E_FIXTURE_PATH || resolve(process.cwd(), '.e2e-fixtures/release.json');
const apiPort = process.env.E2E_API_PORT || '4317';
const webPort = process.env.E2E_WEB_PORT || (releaseLane ? '4318' : '4173');
const localBaseUrl = `http://127.0.0.1:${webPort}`;
const localApiUrl = `http://127.0.0.1:${apiPort}`;

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
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
    {
      name: 'gate0-release',
      use: { ...devices['Desktop Chrome'] },
      testMatch: /gate0-payroll-release\.spec\.ts/,
      retries: 0,
    },
  ],
  webServer: externalBaseUrl
    ? undefined
    : [
        ...(releaseLane
          ? [{
              command: `cd ../api && bundle exec rails server --environment test --binding 127.0.0.1 --port ${apiPort}`,
              url: `${localApiUrl}/up`,
              reuseExistingServer: false,
              timeout: 120_000,
              env: {
                ...process.env,
                RAILS_ENV: 'test',
                AUTH_ENABLED: 'false',
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
      ],
});
