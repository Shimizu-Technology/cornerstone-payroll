// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'

vi.mock('posthog-js', () => ({ default: { init: vi.fn() } }))

afterEach(() => {
  cleanup()
  vi.unstubAllEnvs()
  vi.resetModules()
})

it('shows the staging warning and snapshot/code context on every root surface', async () => {
  vi.stubEnv('VITE_DEPLOYMENT_ENV', 'staging')
  vi.stubEnv('VITE_STAGING_SNAPSHOT_AT', '2026-10-24T00:00:00Z')
  vi.stubEnv('VITE_STAGING_CODE_SHA', 'abcdef1234567890')
  document.title = 'Login'
  const { StagingContext } = await import('./StagingContext')
  render(<StagingContext />)
  expect(screen.getByLabelText('Staging environment').textContent).toContain('STAGING – DO NOT ISSUE OR FILE')
  expect(screen.getByText(/Snapshot:/).textContent).toContain('2026-10-24T00:00:00Z')
  expect(screen.getByText(/Snapshot:/).textContent).toContain('abcdef123456')
  expect(document.title).toBe('[STAGING] Login')
  document.title = 'Personal time'
  await waitFor(() => expect(document.title).toBe('[STAGING] Personal time'))
  expect(document.querySelector('link[href="/staging-favicon.svg"]')).not.toBeNull()
})

it('keeps production context and CSV bytes unchanged', async () => {
  vi.stubEnv('VITE_DEPLOYMENT_ENV', 'production')
  const { StagingContext } = await import('./StagingContext')
  const { stagingCsv } = await import('../lib/staging')
  render(<StagingContext />)
  expect(screen.queryByLabelText('Staging environment')).toBeNull()
  expect(stagingCsv('name,hours')).toBe('name,hours')
})

it('labels browser-generated CSVs in staging', async () => {
  vi.stubEnv('VITE_DEPLOYMENT_ENV', 'staging')
  const { stagingCsv } = await import('../lib/staging')
  expect(stagingCsv('name,hours')).toBe('STAGING – DO NOT ISSUE OR FILE\nname,hours')
})

it('disables analytics even when production keys and enable flags were copied', async () => {
  vi.stubEnv('VITE_DEPLOYMENT_ENV', 'staging')
  vi.stubEnv('VITE_PUBLIC_POSTHOG_ENABLED', 'true')
  vi.stubEnv('VITE_PUBLIC_POSTHOG_KEY', 'synthetic-key')
  const posthog = (await import('posthog-js')).default
  const { PostHogProvider } = await import('../providers/PostHogProvider')
  render(<PostHogProvider><span>Test content</span></PostHogProvider>)
  expect(screen.getByText('Test content')).not.toBeNull()
  expect(posthog.init).not.toHaveBeenCalled()
})
