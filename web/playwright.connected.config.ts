import { defineConfig, devices } from '@playwright/test';

if (!process.env.E2E_CONNECTED_FIXTURE_PATH || !process.env.E2E_AIRE_FIXTURE_PATH) {
  throw new Error('Connected browser QA requires the disposable two-application certification fixtures.');
}
const apiPort = process.env.E2E_API_PORT || '44338';
const webPort = process.env.E2E_WEB_PORT || '44339';
export default defineConfig({
  testDir: './e2e', testMatch: /connected-manual-payroll\.spec\.ts/,
  workers: 1, retries: 0, timeout: 120_000, forbidOnly: true,
  reporter: 'list', outputDir: './test-results/connected-manual',
  use: { ...devices['Desktop Chrome'], baseURL: `http://localhost:${webPort}`,
    timezoneId: 'Pacific/Guam', trace: 'retain-on-failure', screenshot: 'only-on-failure' },
  webServer: {
    command: `npm run dev -- --host 127.0.0.1 --port ${webPort} --strictPort`,
    url: `http://localhost:${webPort}`, reuseExistingServer: false,
    env: { ...process.env, VITE_API_URL: `http://localhost:${apiPort}/api/v1`,
      VITE_AUTH_ENABLED: 'false', VITE_CLERK_PUBLISHABLE_KEY: '' },
  },
});
