/** @vitest-environment jsdom */
import { ClerkInstanceContext } from '@clerk/shared/react';
import { cleanup, render } from '@testing-library/react';
import { useContext, type ComponentProps, type ContextType, type ReactElement } from 'react';
import type { ClerkProvider, SignIn } from '@clerk/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { StepUpRequiredError } from './api';
import { ClerkAuthBridge, ClerkAuthProvider } from './ClerkAuth';
import { brandFrom } from './brand';
import { EmployeeAuthContext, type EmployeeAuthValue } from './contexts';

const { openUserProfile, providerProps, signInProps, signOut } = vi.hoisted(() => ({
  openUserProfile: vi.fn(),
  providerProps: vi.fn<(props: ComponentProps<typeof ClerkProvider>) => void>(),
  signInProps: vi.fn<(props: ComponentProps<typeof SignIn>) => void>(),
  signOut: vi.fn(),
}));

vi.mock('@clerk/react', async (importOriginal) => ({
  ...await importOriginal<typeof import('@clerk/react')>(),
  ClerkProvider: (props: ComponentProps<typeof ClerkProvider>) => {
    providerProps(props);
    return props.children;
  },
  SignIn: (props: ComponentProps<typeof SignIn>) => { signInProps(props); return null; },
  useAuth: () => ({ isLoaded: true, isSignedIn: true, getToken: vi.fn(async () => 'token'), signOut }),
  useClerk: () => ({ openUserProfile, on: vi.fn(), off: vi.fn() }),
  useUser: () => ({ user: { primaryEmailAddress: { emailAddress: 'employee@example.test' } } }),
}));

type Clerk = NonNullable<ContextType<typeof ClerkInstanceContext>>['value'];
const openReverification = vi.fn<Clerk['__internal_openReverification']>();
const clerk = { __internal_openReverification: openReverification } as unknown as Clerk;

function renderBridge(): { current: EmployeeAuthValue } {
  const auth = {} as { current: EmployeeAuthValue };
  function Capture(): ReactElement | null {
    auth.current = useContext(EmployeeAuthContext) as EmployeeAuthValue;
    return null;
  }
  render(
    <ClerkInstanceContext.Provider value={{ value: clerk }}>
      <ClerkAuthBridge><Capture /></ClerkAuthBridge>
    </ClerkInstanceContext.Provider>,
  );
  return auth;
}

beforeEach(() => {
  openReverification.mockReset();
  openUserProfile.mockReset();
  providerProps.mockClear();
  signInProps.mockClear();
  signOut.mockReset();
});
afterEach(cleanup);

describe('employee ClerkAuthBridge', () => {
  // The API asks for first_factor while REQUIRE_MFA is off (a password or email
  // code, never enrollment) and second_factor once it's on.
  it.each(['first_factor', 'second_factor'])('prompts Clerk at the API\'s %s level and retries the change', async (level) => {
    openReverification.mockImplementation((props) => props?.afterVerification?.({}));
    const attempt = vi.fn<() => Promise<string>>()
      .mockRejectedValueOnce(new StepUpRequiredError({ type: 'forbidden', reason: 'reverification-error', metadata: { reverification: { level, afterMinutes: 10 } } }))
      .mockResolvedValueOnce('saved');
    const auth = renderBridge();

    await expect(auth.current.stepUp(attempt)).resolves.toBe('saved');
    expect(openReverification).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ level }));
    expect(attempt).toHaveBeenCalledTimes(2);
  });

  it('opens Clerk account settings over the screen and offers the embedded panel', () => {
    const auth = renderBridge();
    auth.current.openAccountSettings();
    expect(openUserProfile).toHaveBeenCalledTimes(1);
    expect(auth.current.AccountSecurityPanel).toBeTypeOf('function');
  });

  it('shows the Clerk account email and can sign out back to the claim route', async () => {
    const auth = renderBridge();
    expect(auth.current.email).toBe('employee@example.test');
    await auth.current.signOut('/claim');
    expect(signOut).toHaveBeenCalledExactlyOnceWith({ redirectUrl: '/claim' });
  });
});

it('allows Clerk to show alternative factors while keeping sign-up invitation-only', () => {
  const brand = brandFrom({ name: 'Example Kitchen', logo_url: null, primary_color: null, accent_color: null });
  function SignInScreen(): ReactElement {
    const { SignInForm } = useContext(EmployeeAuthContext)!;
    return <SignInForm redirectTo="/claim" />;
  }
  render(
    <ClerkInstanceContext.Provider value={{ value: clerk }}>
      <ClerkAuthProvider publishableKey="test-key" brand={brand}><SignInScreen /></ClerkAuthProvider>
    </ClerkInstanceContext.Provider>,
  );

  const provider = providerProps.mock.lastCall?.[0];
  const signIn = signInProps.mock.lastCall?.[0];
  expect(provider?.appearance?.elements).not.toHaveProperty('footerAction');
  expect(provider?.appearance?.elements).toMatchObject({
    formFieldInputShowPasswordButton: { minWidth: '44px', minHeight: '44px' },
  });
  expect(provider?.localization?.signIn?.emailCodeMfa?.subtitle).toBe('to continue to Example Kitchen');
  expect(signIn).toMatchObject({ withSignUp: false, forceRedirectUrl: '/claim' });
  expect(signIn?.appearance?.elements).toEqual({ footerAction__signIn: { display: 'none' } });
});
