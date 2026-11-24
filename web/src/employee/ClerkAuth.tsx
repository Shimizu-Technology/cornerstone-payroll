import { useCallback, useMemo, type ComponentProps, type ReactNode, type ReactElement } from 'react';
import { ClerkProvider, SignIn, SignUp, useAuth, useReverification } from '@clerk/react';
import { isReverificationCancelledError } from '@clerk/react/errors';
// Pinned so a Clerk CDN update can't change the sign-in markup our styles target.
import { ui as clerkUi } from '@clerk/ui';
import type { EmployeeBrand } from './brand';
import { EmployeeApiError, StepUpCancelledError, StepUpRequiredError } from './api';
import { EmployeeAuthContext, type EmployeeAuthValue } from './contexts';

type ClerkProviderProps = ComponentProps<typeof ClerkProvider>;

const DISPLAY_FONT = '"Plus Jakarta Sans", "Source Sans 3", system-ui, sans-serif';
const BODY_FONT = '"Source Sans 3", system-ui, -apple-system, "Segoe UI", sans-serif';

// Style objects rather than utility classes: Clerk's own styles sit outside
// Tailwind's layers, so only these reliably win.
function appearanceFor(brand: EmployeeBrand): ClerkProviderProps['appearance'] {
  return {
    variables: {
      colorPrimary: brand.action,
      colorForeground: '#0f172a',
      colorMutedForeground: '#475569',
      colorDanger: '#b91c1c',
      fontFamily: BODY_FONT,
      fontFamilyButtons: BODY_FONT,
      fontSize: '1rem',
      borderRadius: '0.875rem',
    },
    elements: {
      rootBox: { width: '100%' },
      // Visible overflow and a little side padding keep field borders and focus rings from being clipped.
      cardBox: { width: '100%', maxWidth: '100%', overflow: 'visible', boxShadow: 'none', border: 'none', borderRadius: 0, background: 'transparent' },
      card: { boxShadow: 'none', border: 'none', background: 'transparent', padding: '8px 4px 16px' },
      header: { alignItems: 'flex-start', textAlign: 'left' },
      headerTitle: { fontFamily: DISPLAY_FONT, fontSize: '1.65rem', fontWeight: 800, lineHeight: 1.2, letterSpacing: '-0.01em' },
      headerSubtitle: { fontSize: '1.06rem', color: '#1e293b' },
      formFieldLabel: { fontSize: '1rem', fontWeight: 700 },
      // 16px or larger so iOS doesn't zoom into the field.
      formFieldInput: { minHeight: '52px', borderRadius: '14px', fontSize: 'max(16px, 1rem)' },
      formButtonPrimary: { minHeight: '52px', borderRadius: '999px', fontSize: '1.06rem', fontWeight: 700, boxShadow: 'none', backgroundImage: 'none' },
      socialButtonsBlockButton: { minHeight: '52px', borderRadius: '999px' },
      socialButtonsBlockButtonText: { fontSize: '1.06rem', fontWeight: 700, color: '#0f172a' },
      footer: { background: 'transparent' },
      // Employees can't create an account here; sign-up starts from the link
      // or code their employer sends (M4-2).
      footerAction: { display: 'none' },
    },
  };
}

function ClerkSignInForm({ redirectTo }: { redirectTo: string }): ReactElement {
  return <SignIn routing="hash" withSignUp={false} forceRedirectUrl={redirectTo} fallbackRedirectUrl="/" />;
}

// Opened from the Clerk invitation the API returns (M4-2); Clerk reads the
// ticket from the address, so the email can't be changed here.
function ClerkSignUpForm({ redirectTo }: { redirectTo: string }): ReactElement {
  return <SignUp routing="hash" forceRedirectUrl={redirectTo} fallbackRedirectUrl={redirectTo} signInUrl="/sign-in" />;
}

type Attempt = () => Promise<unknown>;

function ClerkAuthBridge({ children }: { children: ReactNode }): ReactElement {
  const { isLoaded, isSignedIn, getToken, signOut } = useAuth();
  // Clerk shows its "confirm it's you" prompt when the fetcher returns the
  // API's reverification hint, then runs the same attempt again.
  const reverify = useReverification(async (attempt: Attempt) => {
    try {
      return { result: await attempt() };
    } catch (error) {
      if (error instanceof StepUpRequiredError) return { clerk_error: error.hint };
      throw error;
    }
  });
  const stepUp = useCallback(async <T,>(attempt: () => Promise<T>): Promise<T> => {
    try {
      const outcome = await reverify(attempt as Attempt) as { result?: unknown; clerk_error?: unknown };
      // A hint that comes back again after reverifying means the API still refused.
      if ('clerk_error' in outcome) throw new EmployeeApiError('server', 403);
      return outcome.result as T;
    } catch (error) {
      if (isReverificationCancelledError(error)) throw new StepUpCancelledError();
      throw error;
    }
  }, [reverify]);
  const value = useMemo<EmployeeAuthValue>(() => ({
    isLoaded,
    isSignedIn: Boolean(isSignedIn),
    getToken: (options) => getToken(options?.fresh ? { skipCache: true } : undefined),
    signOut: () => signOut({ redirectUrl: '/' }),
    SignInForm: ClerkSignInForm,
    SignUpForm: ClerkSignUpForm,
    stepUp,
  }), [isLoaded, isSignedIn, getToken, signOut, stepUp]);
  return <EmployeeAuthContext.Provider value={value}>{children}</EmployeeAuthContext.Provider>;
}

export function ClerkAuthProvider({ publishableKey, brand, children }: { publishableKey: string; brand: EmployeeBrand; children: ReactNode }): ReactElement {
  const appearance = useMemo(() => appearanceFor(brand), [brand]);
  const localization = useMemo<ClerkProviderProps['localization']>(() => ({
    signIn: {
      start: {
        title: 'Sign in',
        titleCombined: 'Sign in',
        subtitle: brand.isFallback ? 'See your pay stubs and tax forms.' : `See your pay from ${brand.name}.`,
        subtitleCombined: brand.isFallback ? 'See your pay stubs and tax forms.' : `See your pay from ${brand.name}.`,
      },
    },
    signUp: {
      start: {
        title: 'Create your account',
        subtitle: 'Choose how you want to sign in.',
      },
    },
  }), [brand]);
  return (
    <ClerkProvider
      publishableKey={publishableKey}
      ui={clerkUi}
      appearance={appearance}
      localization={localization}
      signInUrl="/sign-in"
      signUpUrl="/sign-up/account"
      afterSignOutUrl="/"
    >
      <ClerkAuthBridge>{children}</ClerkAuthBridge>
    </ClerkProvider>
  );
}
