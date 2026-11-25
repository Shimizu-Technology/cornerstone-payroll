// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { StrictMode, type ReactNode } from 'react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import EmployeeApp from './EmployeeApp';
import { ClerkAuthProvider } from './employee/ClerkAuth';
import { brandFrom } from './employee/brand';

const { tenant, clerk, listeners, mounted } = vi.hoisted(() => ({
  tenant: { host: 'example-employer.shimizu-technology.com' as string | null },
  clerk: {
    status: 'loading' as 'loading' | 'ready' | 'error' | 'degraded',
    isLoaded: false,
    isSignedIn: false,
  },
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
    isLoaded: clerk.isLoaded,
    isSignedIn: clerk.isSignedIn,
  }),
  useReverification: () => vi.fn(),
}));

const enabledBrand = () => Response.json({ name: 'Example Employer' });
const never = () => new Promise<Response>(() => undefined);
const tenantUnavailableTitle = "This employee app isn't available yet";
const connectionErrorTitle = "We couldn't open the app";

function expectFocusedAlert(title: string) {
  const heading = screen.getByRole('heading', { name: title });
  expect(screen.getByRole('alert').contains(heading)).toBe(true);
  expect(document.activeElement).toBe(heading);
  expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();
}

function changeClerkStatus(status: typeof clerk.status) {
  act(() => {
    clerk.status = status;
    if (status === 'ready') clerk.isLoaded = true;
    listeners.forEach(listener => listener());
  });
}

beforeEach(() => {
  tenant.host = 'example-employer.shimizu-technology.com';
  clerk.status = 'loading';
  clerk.isLoaded = false;
  clerk.isSignedIn = false;
  mounted.mockClear();
});

afterEach(() => {
  cleanup();
  listeners.clear();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
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
  ['explicitly disabled subdomain', async () => Response.json({ name: 'Example Employer', subdomain_enabled: false })],
])('shows employer guidance without mounting Clerk after a branding %s', async (_label, fetchBranding) => {
  vi.stubGlobal('fetch', vi.fn(fetchBranding));
  render(<EmployeeApp />);

  await screen.findByRole('heading', { name: tenantUnavailableTitle });
  expectFocusedAlert(tenantUnavailableTitle);
  expect(screen.getByText('If you were expecting access, contact your employer.')).toBeTruthy();
  expect(mounted).not.toHaveBeenCalled();
});

it.each([
  ['503', async () => new Response(null, { status: 503 })],
  ['network or CORS failure', async () => { throw new TypeError('Failed to fetch'); }],
])('shows a connection retry after a branding %s', async (_label, fetchBranding) => {
  vi.stubGlobal('fetch', vi.fn(fetchBranding));
  render(<EmployeeApp />);

  await screen.findByRole('heading', { name: connectionErrorTitle });
  expectFocusedAlert(connectionErrorTitle);
  expect(screen.getByText('Check your connection and try again. If this keeps happening, contact your employer.')).toBeTruthy();
  expect(mounted).not.toHaveBeenCalled();
});

it('does not request branding while offline and checks again on retry', async () => {
  const online = vi.spyOn(window.navigator, 'onLine', 'get').mockReturnValue(false);
  const fetch = vi.fn(async () => enabledBrand());
  vi.stubGlobal('fetch', fetch);
  render(<EmployeeApp />);

  await screen.findByRole('heading', { name: connectionErrorTitle });
  expect(fetch).not.toHaveBeenCalled();
  expect(mounted).not.toHaveBeenCalled();

  online.mockReturnValue(true);
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  await act(async () => {});
  changeClerkStatus('ready');

  expect(fetch).toHaveBeenCalledTimes(1);
  expect(screen.getByText('See your pay stubs and tax forms from Example Employer any time.')).toBeTruthy();
});

it('times out a hung branding request without mounting Clerk, even if the response eventually arrives', async () => {
  vi.useFakeTimers();
  let respond!: (response: Response) => void;
  const fetch = vi.fn<typeof globalThis.fetch>(() => new Promise(resolve => { respond = resolve; }));
  vi.stubGlobal('fetch', fetch);
  render(<EmployeeApp />);

  await act(async () => vi.advanceTimersByTimeAsync(5_999));
  expect(screen.getByRole('status').textContent).toBe('Loading');

  await act(async () => vi.advanceTimersByTimeAsync(1));
  expect(fetch.mock.calls[0][1]?.signal?.aborted).toBe(true);
  expectFocusedAlert(connectionErrorTitle);

  await act(async () => vi.advanceTimersByTimeAsync(1));
  await act(async () => respond(enabledBrand()));
  expectFocusedAlert(connectionErrorTitle);
  expect(mounted).not.toHaveBeenCalled();
});

it('uses the neutral brand without checking tenant branding on the shared host', () => {
  tenant.host = null;
  clerk.status = 'ready';
  clerk.isLoaded = true;
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
  expectFocusedAlert("We couldn't load sign-in");
  expect(screen.queryByRole('status')).toBeNull();
});

it('shows a retry after 15 seconds and recovers when Clerk gets ready at 16 seconds', async () => {
  vi.useFakeTimers();
  vi.stubGlobal('fetch', vi.fn(async () => enabledBrand()));
  render(<EmployeeApp />);
  await act(async () => {});

  await act(async () => vi.advanceTimersByTimeAsync(14_999));
  expect(screen.getByRole('status').textContent).toBe('Loading');

  await act(async () => vi.advanceTimersByTimeAsync(1));
  expectFocusedAlert("We couldn't load sign-in");
  expect(screen.queryByRole('status')).toBeNull();

  await act(async () => vi.advanceTimersByTimeAsync(1_000));
  changeClerkStatus('ready');
  expect(screen.getByRole('heading', { name: 'Your pay, on your phone' })).toBeTruthy();
  expect(screen.queryByRole('alert')).toBeNull();
});

it.each(['error', 'degraded'] as const)('keeps a signed-in form mounted when Clerk status changes to %s', (status) => {
  clerk.status = 'ready';
  clerk.isLoaded = true;
  clerk.isSignedIn = true;
  const brand = brandFrom(null);
  const renderForm = () => (
    <ClerkAuthProvider publishableKey="pk_test_synthetic" brand={brand}>
      <label>Draft<input /></label>
    </ClerkAuthProvider>
  );
  const { rerender } = render(renderForm());
  const input = screen.getByRole('textbox', { name: 'Draft' }) as HTMLInputElement;
  fireEvent.change(input, { target: { value: 'Unfinished draft' } });

  changeClerkStatus(status);
  rerender(renderForm());

  expect(screen.getByRole('textbox', { name: 'Draft' })).toBe(input);
  expect(input.value).toBe('Unfinished draft');
  expect(screen.queryByRole('alert')).toBeNull();
});
