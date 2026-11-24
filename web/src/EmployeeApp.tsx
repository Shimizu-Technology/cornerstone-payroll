// Employee surface entry (VITE_APP_SURFACE=employee). Vite resolves `./App`
// to this file, so none of the staff app is in this bundle.
import { useEffect, useState, type CSSProperties, type ReactNode } from 'react';
import { BrowserRouter, Navigate, Route, Routes, useLocation } from 'react-router';
import { brandFrom, brandStyle, fetchTenantBranding, type EmployeeBrand } from './employee/brand';
import { ClerkAuthProvider } from './employee/ClerkAuth';
import { API_BASE_URL, CLERK_PUBLISHABLE_KEY, TENANT_HOST } from './employee/config';
import { BrandContext, useEmployeeAuth, useEmployeeSession } from './employee/contexts';
import { DevPreviewAuthProvider } from './employee/DevPreviewAuth';
import { HideAmountsProvider } from './employee/HideAmounts';
import { redirectTarget } from './employee/routing';
import { EmployeeSessionProvider } from './employee/SessionProvider';
import { EmployeeShell } from './employee/Shell';
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
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), BRANDING_TIMEOUT_MS);
    void fetchTenantBranding(TENANT_HOST, { baseUrl: API_BASE_URL, signal: controller.signal })
      .then((branding) => setBrand(brandFrom(branding)))
      .finally(() => window.clearTimeout(timer));
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, []);
  return brand;
}

function SignedInApp({ viewAs }: { viewAs?: ViewOnlyGrant | null }) {
  const { state, retry } = useEmployeeSession();
  const { signOut } = useEmployeeAuth();
  const leave = () => { void signOut(); };

  if (state.status === 'problem' && state.problem === 'unavailable') return <UnavailableScreen onRetry={retry} onSignOut={leave} />;
  if (state.status === 'problem' && state.problem === 'ended') return <AccessEndedScreen onSignOut={leave} />;
  if (state.status === 'problem' && state.problem === 'signed_out') return <BootScreen />;

  let content: ReactNode;
  if (state.status === 'loading') content = <LoadingState />;
  else if (state.status === 'problem') {
    content = state.problem === 'offline' ? <OfflineState onRetry={retry} />
      : state.problem === 'rate_limited' ? <RateLimitedState onRetry={retry} />
        : <ErrorState onRetry={retry} />;
  } else {
    content = (
      <Routes>
        <Route index element={<HomeTab />} />
        <Route path="pay" element={<PayTab />} />
        <Route path="taxes" element={<TaxesTab />} />
        <Route path="my-info" element={<MyInfoTab />} />
        <Route path="help" element={<HelpTab />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    );
  }
  return <EmployeeShell viewAs={viewAs}>{content}</EmployeeShell>;
}

function AppRoutes({ viewAs }: { viewAs?: ViewOnlyGrant | null }) {
  const { isLoaded, isSignedIn } = useEmployeeAuth();
  const location = useLocation();
  if (!isLoaded) return <BootScreen />;

  if (!isSignedIn) {
    if (location.pathname === '/sign-in') return <SignInScreen />;
    if (location.pathname === '/') return <WelcomeScreen />;
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

function AuthProvider({ brand, children }: { brand: EmployeeBrand; children: ReactNode }) {
  if (CLERK_PUBLISHABLE_KEY) return <ClerkAuthProvider publishableKey={CLERK_PUBLISHABLE_KEY} brand={brand}>{children}</ClerkAuthProvider>;
  if (import.meta.env.DEV) return <DevPreviewAuthProvider>{children}</DevPreviewAuthProvider>;
  return <UnavailableScreen />;
}

// Development only: `?previewViewAs=Name` shows the view-only banner until
// M4-9 wires it to a real grant.
const PREVIEW_VIEW_AS = import.meta.env.DEV && typeof window !== 'undefined'
  ? new URLSearchParams(window.location.search).get('previewViewAs') : null;

export default function EmployeeApp({ viewAs }: { viewAs?: ViewOnlyGrant | null }) {
  const brand = useTenantBrand();
  const grant = viewAs ?? (PREVIEW_VIEW_AS ? { name: PREVIEW_VIEW_AS, minutesLeft: 27, onEnd: () => window.location.assign('/') } : null);
  if (!brand) return <BootScreen />;
  const style = brandStyle(brand) as CSSProperties;
  return (
    <BrandContext.Provider value={brand}>
      <div className="employee-app" style={style}>
        <BrowserRouter>
          <AuthProvider brand={brand}>
            <HideAmountsProvider>
              <AppRoutes viewAs={grant} />
            </HideAmountsProvider>
          </AuthProvider>
        </BrowserRouter>
      </div>
    </BrandContext.Provider>
  );
}
