// Employee surface entry (VITE_APP_SURFACE=employee). Vite resolves `./App`
// to this file, so none of the staff app is in this bundle.
import { useEffect, useMemo, useState, type CSSProperties, type ReactElement, type ReactNode } from 'react';
import { BrowserRouter, Navigate, Route, Routes, useLocation } from 'react-router';
import { brandFrom, brandStyle, employerBrand, fetchTenantBranding, type EmployeeBrand } from './employee/brand';
import { ClerkAuthProvider } from './employee/ClerkAuth';
import { API_BASE_URL, CLERK_PUBLISHABLE_KEY, TENANT_HOST } from './employee/config';
import { BrandContext, useBrand, useEmployeeAuth, useEmployeeSession } from './employee/contexts';
import { DevPreviewAuthProvider } from './employee/DevPreviewAuth';
import { HideAmountsProvider } from './employee/HideAmounts';
import { useSignOut } from './employee/hooks';
import { isSigningOut, redirectTarget } from './employee/routing';
import { EmployeeSessionProvider } from './employee/SessionProvider';
import { EmployeeShell } from './employee/Shell';
import { SignOutProvider } from './employee/SignOut';
import {
  AccessEndedScreen, BootScreen, ErrorState, LoadingState, OfflineState, RateLimitedState, TenantUnavailableScreen, TwoStepScreen, UnavailableScreen,
} from './employee/StateScreens';
import { HelpTab } from './employee/help';
import { MyInfoTab } from './employee/myinfo';
import { HomeTab, PayTab } from './employee/pay';
import { EmployerPicker } from './employee/picker';
import { SignInScreen, WelcomeScreen } from './employee/screens';
import { ActivateScreen, FinishSignUpScreen, LinkCheckScreen, SignedInInvite, SignInFirst, SignUpAccountScreen } from './employee/signup';
import { SECURITY_PATH, SecurityScreen } from './employee/security';
import { TaxesTab } from './employee/taxes';
import type { ViewOnlyGrant } from './employee/ViewOnlyBanner';
import { parseLinks } from './employee/api';
import { PostHogPageView } from './providers/PostHogProvider';
import { supportToken } from './support/grant';
import { useSupportView } from './support/useSupportView';
import './employee/employee.css';

const BRANDING_TIMEOUT_MS = 6000;

function useTenantBrand(): EmployeeBrand | null | undefined {
  const [brand, setBrand] = useState<EmployeeBrand | null | undefined>(() => TENANT_HOST ? undefined : brandFrom(null));
  useEffect(() => {
    if (!TENANT_HOST) return;
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      controller.abort();
      setBrand(null);
    }, BRANDING_TIMEOUT_MS);
    void fetchTenantBranding(TENANT_HOST, { baseUrl: API_BASE_URL, signal: controller.signal })
      .then((branding) => {
        if (!controller.signal.aborted) setBrand(branding ? brandFrom(branding) : null);
      })
      .finally(() => window.clearTimeout(timer));
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, []);
  return brand;
}

function SignedInApp({ viewAs }: { viewAs?: ViewOnlyGrant | null }): ReactElement {
  const { state } = useEmployeeSession();
  const brand = useBrand();
  // On the shared host, the chosen employer's name stands in for client branding.
  const shown = state.status === 'ready' ? employerBrand(brand, state.link.companyName) : brand;
  return (
    <BrandContext.Provider value={shown}>
      <SignedInScreens viewAs={viewAs} />
    </BrandContext.Provider>
  );
}

function SignedInScreens({ viewAs }: { viewAs?: ViewOnlyGrant | null }): ReactElement {
  const { state, retry, chooseLink } = useEmployeeSession();
  const signOutAsync = useSignOut();
  const signOut = (): void => { void signOutAsync(); };

  if (viewAs && state.status === 'problem') return (
    <EmployeeShell viewAs={viewAs} showNav={false}>
      {state.problem === 'ended' || state.problem === 'unavailable'
        ? <p role="status" className="p-4">This support view is unavailable or has ended.</p>
        : <ErrorState onRetry={retry} onSignOut={signOut} />}
    </EmployeeShell>
  );
  if (state.status === 'problem' && state.problem === 'unavailable') return <UnavailableScreen onRetry={retry} onSignOut={signOut} />;
  if (state.status === 'problem' && state.problem === 'ended') return <AccessEndedScreen onSignOut={signOut} />;
  if (state.status === 'problem' && state.problem === 'signed_out') return <BootScreen />;
  if (state.status === 'problem' && state.problem === 'mfa_setup') return <TwoStepScreen kind="setup" onRetry={retry} onSignOut={signOut} />;
  if (state.status === 'problem' && state.problem === 'mfa_required') return <TwoStepScreen kind="verify" onRetry={retry} onSignOut={signOut} />;
  if (state.status === 'choose') return <EmployerPicker links={state.links} onChoose={chooseLink} onSignOut={signOut} />;

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
          <Route path="pay/all" element={<PayTab />} />
          <Route path="pay/:statementId" element={<PayTab />} />
          <Route path="taxes" element={<TaxesTab />} />
          <Route path="my-info" element={<MyInfoTab />} />
          <Route path="help" element={<HelpTab />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      )}
    </EmployeeShell>
  );
}

const SIGN_UP_PATHS = new Set(['/activate', '/sign-up', '/sign-up/done', '/claim', '/add-access', '/reactivate']);

function AppRoutes({ viewAs }: { viewAs?: ViewOnlyGrant | null }): ReactElement {
  const { isSignedIn } = useEmployeeAuth();
  const location = useLocation();

  const path = location.pathname.replace(/\/+$/, '') || '/';
  if (supportToken) return isSignedIn ? <EmployeeSupportView token={supportToken} /> : <SupportSignIn />;

  // The invite links (EmployeeLinks::AppUrl) are /activate, /claim and
  // /reactivate, each with #token=…; Clerk's invitation lands on /sign-up.
  if (!isSignedIn) {
    if (path === '/sign-in') return <SignInScreen />;
    if (path === '/') return <WelcomeScreen />;
    if (path === '/activate') return <ActivateScreen />;
    if (path === '/sign-up') return <SignUpAccountScreen />;
    // Both need the person's existing login: keep the token, sign in, come back.
    if (path === '/claim' || path === '/add-access') return <SignInFirst to="/claim" />;
    if (path === '/reactivate') return <SignInFirst to="/reactivate" />;
    if (isSigningOut()) return <Navigate to="/" replace />;
    // A deep link (for example from a "pay stub ready" email) signs in first, then opens.
    return <Navigate to="/sign-in" replace state={{ from: `${location.pathname}${location.search}` }} />;
  }
  if (path === '/sign-in') return <Navigate to={redirectTarget(location.state)} replace />;
  // A view-only "Sign in as" never signs anyone up or adds access to a login.
  if (viewAs && SIGN_UP_PATHS.has(path)) return <Navigate to="/" replace />;
  // Before the employee session, which the API refuses until two-step sign-in
  // is set up once REQUIRE_MFA is on. Never in a view-only support view: those
  // would be the staff member's own account settings.
  if (path === SECURITY_PATH) return viewAs ? <Navigate to="/" replace /> : <SecurityScreen />;
  // Signed in, before the employee session: sign-up's last step, and invites for a login that already exists.
  if (path === '/activate') return <SignedInInvite />;
  if (path === '/sign-up') return <Navigate to="/sign-up/done" replace />;
  if (path === '/sign-up/done') return <FinishSignUpScreen />;
  if (path === '/claim' || path === '/add-access') return <LinkCheckScreen mode="claim" />;
  if (path === '/reactivate') return <LinkCheckScreen mode="reactivate" />;
  return (
    <EmployeeSessionProvider viewOnly={Boolean(viewAs)}>
      <SignedInApp viewAs={viewAs} />
    </EmployeeSessionProvider>
  );
}

function SupportSignIn(): ReactElement {
  const { SignInForm } = useEmployeeAuth();
  return (
    <main className="emp-auth emp-auth-top">
      <p className="mb-4 font-semibold">Sign in with your staff account to open the support view.</p>
      <SignInForm redirectTo="/" />
    </main>
  );
}

function EmployeeSupportView({ token }: { token: string }): ReactElement {
  const { getToken } = useEmployeeAuth();
  const { grant, loadError, endError, ending, end, retry, leave } = useSupportView(API_BASE_URL, getToken, '/');
  const support = useMemo(() => {
    const link = parseLinks([grant?.link])[0];
    return link ? { token, link } : null;
  }, [grant, token]);

  if (grant && support) return (
    <EmployeeSessionProvider support={support}>
      <SignedInApp viewAs={{ name: grant.name, onEnd: () => { void end(); }, ending, error: endError }} />
    </EmployeeSessionProvider>
  );
  return (
    <main className="emp-auth emp-auth-top space-y-4">
      <p role="status">{loadError || (grant ? 'This support view is unavailable.' : 'Loading support view…')}</p>
      {(loadError || grant) && (
        <div className="flex flex-wrap gap-2">
          <button type="button" className="emp-btn" onClick={retry}>Try again</button>
          <button type="button" className="emp-btn" onClick={leave}>Leave support view</button>
        </div>
      )}
    </main>
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
  if (brand === undefined) return <BootScreen />;
  if (brand === null) {
    return <div className="employee-app"><TenantUnavailableScreen /></div>;
  }
  const style = brandStyle(brand) as CSSProperties;
  return (
    <BrandContext.Provider value={brand}>
      <div className="employee-app" style={style}>
        <BrowserRouter>
          {!supportToken && !grant && <PostHogPageView surface="employee" />}
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
