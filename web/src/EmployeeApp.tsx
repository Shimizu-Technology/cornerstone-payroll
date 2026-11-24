// Employee surface entry (VITE_APP_SURFACE=employee). Vite resolves `./App`
// to this file, so none of the staff app is in this bundle.
import { useEffect, useState, type CSSProperties, type ReactElement, type ReactNode } from 'react';
import { BrowserRouter, Navigate, Route, Routes, useLocation } from 'react-router';
import { brandFrom, brandStyle, fetchTenantBranding, type EmployeeBrand } from './employee/brand';
import { ClerkAuthProvider } from './employee/ClerkAuth';
import { API_BASE_URL, CLERK_PUBLISHABLE_KEY, TENANT_HOST } from './employee/config';
import { BrandContext, useEmployeeAuth, useEmployeeSession } from './employee/contexts';
import { DevPreviewAuthProvider } from './employee/DevPreviewAuth';
import { HideAmountsProvider } from './employee/HideAmounts';
import { useSignOut } from './employee/hooks';
import { isSigningOut, redirectTarget } from './employee/routing';
import { EmployeeSessionProvider } from './employee/SessionProvider';
import { EmployeeShell } from './employee/Shell';
import { SignOutProvider } from './employee/SignOut';
import {
  AccessEndedScreen, BootScreen, ErrorState, LoadingState, OfflineState, RateLimitedState, UnavailableScreen,
} from './employee/StateScreens';
import { HelpTab, HomeTab, MyInfoTab, PayTab, SignInScreen, TaxesTab, WelcomeScreen } from './employee/screens';
import type { ViewOnlyGrant } from './employee/ViewOnlyBanner';
import './employee/employee.css';

const BRANDING_TIMEOUT_MS = 6000;

function useTenantBrand(): EmployeeBrand | null {
  const [brand, setBrand] = useState<EmployeeBrand | null>(() => (TENANT_HOST ? null : brandFrom(null)));
  useEffect(() => {
    if (!TENANT_HOST) return;
    // A cleanup abort (unmount, or StrictMode's second mount) must never set
    // the fallback brand. The timeout's abort still does, so the app opens.
    let cancelled = false;
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), BRANDING_TIMEOUT_MS);
    void fetchTenantBranding(TENANT_HOST, { baseUrl: API_BASE_URL, signal: controller.signal })
      .then((branding) => {
        if (!cancelled) setBrand(brandFrom(branding));
      })
      .finally(() => window.clearTimeout(timer));
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      controller.abort();
    };
  }, []);
  return brand;
}

function SignedInApp({ viewAs }: { viewAs?: ViewOnlyGrant | null }): ReactElement {
  const { state, retry } = useEmployeeSession();
  const signOutAsync = useSignOut();
  const signOut = (): void => { void signOutAsync(); };

  if (state.status === 'problem' && state.problem === 'unavailable') return <UnavailableScreen onRetry={retry} onSignOut={signOut} />;
  if (state.status === 'problem' && state.problem === 'ended') return <AccessEndedScreen onSignOut={signOut} />;
  if (state.status === 'problem' && state.problem === 'signed_out') return <BootScreen />;

  if (state.status === 'problem') {
    const actions = { onRetry: retry, onSignOut: signOut };
    const content = state.problem === 'offline' ? <OfflineState {...actions} />
      : state.problem === 'rate_limited' ? <RateLimitedState {...actions} />
        : <ErrorState {...actions} />;
    // No tabs here: they would change the address without changing the screen.
    return <EmployeeShell viewAs={viewAs} showNav={false}>{content}</EmployeeShell>;
  }

  return (
    <EmployeeShell viewAs={viewAs}>
      {state.status === 'loading' ? <LoadingState /> : (
        <Routes>
          <Route index element={<HomeTab />} />
          <Route path="pay" element={<PayTab />} />
          <Route path="taxes" element={<TaxesTab />} />
          <Route path="my-info" element={<MyInfoTab />} />
          <Route path="help" element={<HelpTab />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      )}
    </EmployeeShell>
  );
}

function AppRoutes({ viewAs }: { viewAs?: ViewOnlyGrant | null }): ReactElement {
  const { isLoaded, isSignedIn } = useEmployeeAuth();
  const location = useLocation();
  if (!isLoaded) return <BootScreen />;

  if (!isSignedIn) {
    if (location.pathname === '/sign-in') return <SignInScreen />;
    if (location.pathname === '/') return <WelcomeScreen />;
    if (isSigningOut()) return <Navigate to="/" replace />;
    // A deep link (for example from a "pay stub ready" email) signs in first, then opens.
    return <Navigate to="/sign-in" replace state={{ from: `${location.pathname}${location.search}` }} />;
  }
  if (location.pathname === '/sign-in') return <Navigate to={redirectTarget(location.state)} replace />;
  return (
    <EmployeeSessionProvider>
      <SignedInApp viewAs={viewAs} />
    </EmployeeSessionProvider>
  );
}

function AuthProvider({ brand, children }: { brand: EmployeeBrand; children: ReactNode }): ReactElement {
  if (CLERK_PUBLISHABLE_KEY) return <ClerkAuthProvider publishableKey={CLERK_PUBLISHABLE_KEY} brand={brand}>{children}</ClerkAuthProvider>;
  if (import.meta.env.DEV) return <DevPreviewAuthProvider>{children}</DevPreviewAuthProvider>;
  return <UnavailableScreen />;
}

// Development only: `?previewViewAs=Name` shows the view-only banner until
// M4-9 wires it to a real grant.
const PREVIEW_VIEW_AS = import.meta.env.DEV && typeof window !== 'undefined'
  ? new URLSearchParams(window.location.search).get('previewViewAs') : null;

export default function EmployeeApp({ viewAs }: { viewAs?: ViewOnlyGrant | null }): ReactElement {
  const brand = useTenantBrand();
  const grant = viewAs ?? (PREVIEW_VIEW_AS ? { name: PREVIEW_VIEW_AS, minutesLeft: 27, onEnd: () => window.location.assign('/') } : null);
  if (!brand) return <BootScreen />;
  const style = brandStyle(brand) as CSSProperties;
  return (
    <BrandContext.Provider value={brand}>
      <div className="employee-app" style={style}>
        <BrowserRouter>
          <AuthProvider brand={brand}>
            <SignOutProvider>
              <HideAmountsProvider>
                <AppRoutes viewAs={grant} />
              </HideAmountsProvider>
            </SignOutProvider>
          </AuthProvider>
        </BrowserRouter>
      </div>
    </BrandContext.Provider>
  );
}
