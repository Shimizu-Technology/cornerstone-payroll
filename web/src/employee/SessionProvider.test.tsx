// @vitest-environment jsdom
import { act, cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactElement, ReactNode } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { EmployeeAuthContext, useEmployeeSession, type EmployeeAuthValue } from './contexts';
import { useSignOut } from './hooks';
import { isSigningOut } from './routing';
import { EmployeeSessionProvider, SESSION_LOAD_TIMEOUT_MS } from './SessionProvider';
import { SignOutProvider } from './SignOut';

function auth(overrides: Partial<EmployeeAuthValue> = {}): EmployeeAuthValue {
  return {
    isSignedIn: true,
    getToken: async () => 'tok',
    signOut: async () => undefined,
    SignInForm: () => null,
    SignUpForm: () => null,
    stepUp: (attempt) => attempt(),
    openAccountSettings: () => undefined,
    AccountSecurityPanel: () => null,
    ...overrides,
  };
}

function Providers({ value, children }: { value: EmployeeAuthValue; children: ReactNode }): ReactElement {
  return (
    <EmployeeAuthContext.Provider value={value}>
      <SignOutProvider>{children}</SignOutProvider>
    </EmployeeAuthContext.Provider>
  );
}

function SessionState(): ReactElement {
  const { state, retry } = useEmployeeSession();
  return (
    <>
      <output data-testid="state">{state.status === 'problem' ? `problem:${state.problem}` : state.status}</output>
      <button type="button" onClick={retry}>Retry</button>
    </>
  );
}

function SignOutButton(): ReactElement {
  const signOut = useSignOut();
  return <button type="button" onClick={() => { void signOut(); }}>Sign out</button>;
}

const stateText = (): string | null => screen.getByTestId('state').textContent;

function respond(routes: Record<string, () => Response | Promise<Response>>): ReturnType<typeof vi.fn<typeof fetch>> {
  return vi.fn<typeof fetch>(async (input, init) => {
    const path = new URL(String(input), 'http://localhost').pathname.replace(/^\/api\/v1/, '');
    const handler = routes[path];
    if (!handler) return new Response(null, { status: 404 });
    return new Promise<Response>((resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')));
      void Promise.resolve(handler()).then(resolve, reject);
    });
  });
}

const never = (): Promise<Response> => new Promise<Response>(() => undefined);

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('sign-out failures', () => {
  it('says sign-out failed, clears the signing-out flag, and signs out on Try again', async () => {
    const signOut = vi.fn<() => Promise<void>>()
      .mockRejectedValueOnce(new Error('ClerkOfflineError'))
      .mockResolvedValueOnce(undefined);
    render(<Providers value={auth({ signOut })}><SignOutButton /></Providers>);

    await userEvent.click(screen.getByRole('button', { name: 'Sign out' }));
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', "Couldn't sign you out. Try again.Try again");
    expect(isSigningOut()).toBe(false);

    await userEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(signOut).toHaveBeenCalledTimes(2);
    expect(screen.queryByRole('alert')).toBeNull();
    expect(isSigningOut()).toBe(true);
  });

  it('after a 401, a failed sign-out shows the error screen, not endless loading', async () => {
    vi.stubGlobal('fetch', respond({ '/employee/links': () => new Response(null, { status: 401 }) }));
    const signOut = vi.fn<() => Promise<void>>().mockRejectedValue(new Error('ClerkOfflineError'));
    render(<Providers value={auth({ signOut })}><EmployeeSessionProvider><SessionState /></EmployeeSessionProvider></Providers>);

    expect(await screen.findByText('problem:error')).toBeTruthy();
    expect(signOut).toHaveBeenCalled();
    expect(screen.getByRole('alert').textContent).toContain("Couldn't sign you out. Try again.");
  });

  it('after a 401, a successful sign-out leaves the session signed out', async () => {
    vi.stubGlobal('fetch', respond({ '/employee/links': () => new Response(null, { status: 401 }) }));
    const signOut = vi.fn<() => Promise<void>>().mockResolvedValue(undefined);
    render(<Providers value={auth({ signOut })}><EmployeeSessionProvider><SessionState /></EmployeeSessionProvider></Providers>);

    expect(await screen.findByText('problem:signed_out')).toBeTruthy();
    // Sign-out starts in an effect after that state renders, so it can land a moment later under load.
    await waitFor(() => expect(signOut).toHaveBeenCalled());
    expect(screen.queryByRole('alert')).toBeNull();
    expect(stateText()).toBe('problem:signed_out');
  });
});

describe('session loading deadline', () => {
  it('shows the error screen when links never answer', async () => {
    vi.useFakeTimers();
    vi.stubGlobal('fetch', respond({ '/employee/links': never }));
    render(<Providers value={auth()}><EmployeeSessionProvider><SessionState /></EmployeeSessionProvider></Providers>);
    expect(stateText()).toBe('loading');

    await act(async () => { await vi.advanceTimersByTimeAsync(SESSION_LOAD_TIMEOUT_MS - 1); });
    expect(stateText()).toBe('loading');
    await act(async () => { await vi.advanceTimersByTimeAsync(1); });
    expect(stateText()).toBe('problem:error');
  });

  it('also bounds the context check and a token that never arrives', async () => {
    vi.useFakeTimers();
    vi.stubGlobal('fetch', respond({ '/employee/links': () => Response.json([{ id: 4 }]), '/employee/context': never }));
    render(<Providers value={auth()}><EmployeeSessionProvider><SessionState /></EmployeeSessionProvider></Providers>);
    await act(async () => { await vi.advanceTimersByTimeAsync(SESSION_LOAD_TIMEOUT_MS); });
    expect(stateText()).toBe('problem:error');
    cleanup();

    vi.stubGlobal('fetch', respond({ '/employee/links': () => Response.json([{ id: 4 }]) }));
    render(<Providers value={auth({ getToken: () => new Promise<string>(() => undefined) })}><EmployeeSessionProvider><SessionState /></EmployeeSessionProvider></Providers>);
    await act(async () => { await vi.advanceTimersByTimeAsync(SESSION_LOAD_TIMEOUT_MS); });
    expect(stateText()).toBe('problem:error');
  });

  it('a superseded attempt never reports a timeout over the newer one', async () => {
    vi.useFakeTimers();
    let first = true;
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => {
        if (first) { first = false; return never(); }
        return Response.json([{ id: 4 }]);
      },
      '/employee/context': () => new Response(null, { status: 204 }),
    }));
    render(<Providers value={auth()}><EmployeeSessionProvider><SessionState /></EmployeeSessionProvider></Providers>);
    await act(async () => { await vi.advanceTimersByTimeAsync(SESSION_LOAD_TIMEOUT_MS - 1000); });
    await act(async () => { screen.getByRole('button', { name: 'Retry' }).click(); await vi.advanceTimersByTimeAsync(0); });
    expect(stateText()).toBe('ready');

    await act(async () => { await vi.advanceTimersByTimeAsync(SESSION_LOAD_TIMEOUT_MS * 2); });
    expect(stateText()).toBe('ready');
  });

  it('unmounting mid-load sets no state and leaves no timer', async () => {
    vi.useFakeTimers();
    const errors = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    vi.stubGlobal('fetch', respond({ '/employee/links': never }));
    const view = render(<Providers value={auth()}><EmployeeSessionProvider><SessionState /></EmployeeSessionProvider></Providers>);
    view.unmount();
    expect(vi.getTimerCount()).toBe(0);
    await act(async () => { await vi.advanceTimersByTimeAsync(SESSION_LOAD_TIMEOUT_MS * 2); });
    expect(errors).not.toHaveBeenCalled();
    errors.mockRestore();
  });
});
