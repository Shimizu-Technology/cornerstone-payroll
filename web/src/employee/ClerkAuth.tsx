import { useMemo, type ComponentProps, type ReactNode } from 'react';
import { ClerkProvider, SignIn, useAuth } from '@clerk/react';
// Pinned so a Clerk CDN update can't change the sign-in markup our styles target.
import { ui as clerkUi } from '@clerk/ui';
import type { EmployeeBrand } from './brand';
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

function ClerkSignInForm({ redirectTo }: { redirectTo: string }) {
  return <SignIn routing="hash" withSignUp={false} forceRedirectUrl={redirectTo} fallbackRedirectUrl="/" />;
}

function ClerkAuthBridge({ children }: { children: ReactNode }) {
  const { isLoaded, isSignedIn, getToken, signOut } = useAuth();
  const value = useMemo<EmployeeAuthValue>(() => ({
    isLoaded,
    isSignedIn: Boolean(isSignedIn),
    getToken: () => getToken(),
    signOut: () => signOut({ redirectUrl: '/' }),
    SignInForm: ClerkSignInForm,
  }), [isLoaded, isSignedIn, getToken, signOut]);
  return <EmployeeAuthContext.Provider value={value}>{children}</EmployeeAuthContext.Provider>;
}

export function ClerkAuthProvider({ publishableKey, brand, children }: { publishableKey: string; brand: EmployeeBrand; children: ReactNode }) {
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
  }), [brand]);
  return (
    <ClerkProvider
      publishableKey={publishableKey}
      ui={clerkUi}
      appearance={appearance}
      localization={localization}
      signInUrl="/sign-in"
      afterSignOutUrl="/"
    >
      <ClerkAuthBridge>{children}</ClerkAuthBridge>
    </ClerkProvider>
  );
}
