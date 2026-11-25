// @vitest-environment jsdom
import { act, cleanup, render, screen } from '@testing-library/react';
import { StrictMode, type ReactNode } from 'react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import EmployeeApp from './EmployeeApp';

const { tenant, clerk, listeners, mounted } = vi.hoisted(() => ({
  tenant: { host: 'example-employer.shimizu-technology.com' as string | null },
  clerk: { status: 'loading' as 'loading' | 'ready' | 'error' | 'degraded' },
  listeners: new Set<() => void>(),
  mounted: vi.fn(),
}));

vi.mock('./employee/config', async (importOriginal) => ({
  ...await importOriginal<typeof import('./employee/config')>(),
  get TENANT_HOST() { return tenant.host; },
  CLERK_PUBLISHABLE_KEY: 'pk_test_synthetic',
}));

vi.mock('@clerk/react', () => ({
  ClerkProvider: ({ children }: { children: ReactNode }) => {
    mounted();
    return children;
  },
  useClerk: () => ({
    get status() { return clerk.status; },
    on: (_event: string, listener: () => void) => listeners.add(listener),
    off: (_event: string, listener: () => void) => listeners.delete(listener),
  }),
  useAuth: () => ({
    isLoaded: clerk.status === 'ready' || clerk.status === 'degraded',
    isSignedIn: false,
  }),
  useReverification: () => vi.fn(),
}));

const enabledBrand = () => Response.json({ name: 'Example Employer' });
const never = () => new Promise<Response>(() => undefined);

function changeClerkStatus(status: typeof clerk.status) {
  act(() => {
    clerk.status = status;
    listeners.forEach(listener => listener());
  });
}

beforeEach(() => {
  tenant.host = 'example-employer.shimizu-technology.com';
  clerk.status = 'loading';
  mounted.mockClear();
});

afterEach(() => {
  cleanup();
  listeners.clear();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

it('resolves branding before mounting Clerk and shows the branded welcome when Clerk loads', async () => {
  let respond!: () => void;
  const pending = new Promise<void>(resolve => { respond = resolve; });
  vi.stubGlobal('fetch', vi.fn(async () => {
    await pending;
    return enabledBrand();
  }));
  render(<StrictMode><EmployeeApp /></StrictMode>);

  expect(screen.getByRole('status').textContent).toBe('Loading');
  expect(mounted).not.toHaveBeenCalled();

  await act(async () => respond());
  expect(mounted).toHaveBeenCalled();
  expect(screen.getByRole('status').textContent).toBe('Loading');

  changeClerkStatus('ready');
  expect(screen.getByRole('heading', { name: 'Your pay, on your phone' })).toBeTruthy();
  expect(screen.getByText('See your pay stubs and tax forms from Example Employer any time.')).toBeTruthy();
});

it.each([
  ['404', async () => new Response(null, { status: 404 })],
  ['network or CORS error', async () => { throw new TypeError('Failed to fetch'); }],
  ['explicitly disabled subdomain', async () => Response.json({ name: 'Example Employer', subdomain_enabled: false })],
])('shows employer guidance without mounting Clerk after a branding %s', async (_label, fetchBranding) => {
  vi.stubGlobal('fetch', vi.fn(fetchBranding));
  render(<EmployeeApp />);

  expect(await screen.findByRole('heading', { name: "This employee app isn't available yet" })).toBeTruthy();
  expect(screen.getByText('If you were expecting access, contact your employer.')).toBeTruthy();
  expect(mounted).not.toHaveBeenCalled();
});

it('times out a hung branding request without mounting Clerk, even if the response eventually arrives', async () => {
  vi.useFakeTimers();
  let respond!: (response: Response) => void;
  const fetch = vi.fn<typeof globalThis.fetch>(() => new Promise(resolve => { respond = resolve; }));
  vi.stubGlobal('fetch', fetch);
  render(<EmployeeApp />);

  await act(async () => vi.advanceTimersByTimeAsync(6_000));
  expect(fetch.mock.calls[0][1]?.signal?.aborted).toBe(true);
  expect(screen.getByRole('heading', { name: "This employee app isn't available yet" })).toBeTruthy();

  await act(async () => respond(enabledBrand()));
  expect(mounted).not.toHaveBeenCalled();
});

it('uses the neutral brand without checking tenant branding on the shared host', () => {
  tenant.host = null;
  clerk.status = 'ready';
  const fetch = vi.fn(never);
  vi.stubGlobal('fetch', fetch);
  render(<EmployeeApp />);

  expect(fetch).not.toHaveBeenCalled();
  expect(screen.getByRole('heading', { name: 'Your pay, on your phone' })).toBeTruthy();
  expect(screen.getByText('See your pay stubs and tax forms any time.')).toBeTruthy();
});

it.each(['error', 'degraded'] as const)('shows a retry as soon as Clerk reports %s', async (status) => {
  vi.stubGlobal('fetch', vi.fn(async () => enabledBrand()));
  render(<EmployeeApp />);
  await act(async () => {});

  changeClerkStatus(status);
  expect(screen.getByRole('heading', { name: "We couldn't load sign-in" })).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();
  expect(screen.queryByRole('status')).toBeNull();
});

it('replaces a hung Clerk spinner with a retry after 15 seconds', async () => {
  vi.useFakeTimers();
  vi.stubGlobal('fetch', vi.fn(async () => enabledBrand()));
  render(<EmployeeApp />);
  await act(async () => {});

  await act(async () => vi.advanceTimersByTimeAsync(14_999));
  expect(screen.getByRole('status').textContent).toBe('Loading');

  await act(async () => vi.advanceTimersByTimeAsync(1));
  expect(screen.getByRole('heading', { name: "We couldn't load sign-in" })).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();
  expect(screen.queryByRole('status')).toBeNull();
});
