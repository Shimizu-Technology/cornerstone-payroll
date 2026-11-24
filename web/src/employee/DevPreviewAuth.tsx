// Local development without a Clerk key, and the public Playwright suite.
// EmployeeApp only mounts this when import.meta.env.DEV is true, so it is
// tree-shaken out of every production build (appSurfaceBuild.test.ts checks).
import { useMemo, useState, type ReactNode } from 'react';
import { EmployeeAuthContext, useEmployeeAuth, type EmployeeAuthValue } from './contexts';
import { EmpButton } from './ui';

const STORAGE_KEY = 'employee-dev-preview-signed-in';

function readSignedIn(): boolean {
  try {
    return sessionStorage.getItem(STORAGE_KEY) === 'true';
  } catch {
    return false;
  }
}

function writeSignedIn(signedIn: boolean): void {
  try {
    if (signedIn) sessionStorage.setItem(STORAGE_KEY, 'true');
    else sessionStorage.removeItem(STORAGE_KEY);
  } catch {
    // Private mode: the preview session lasts until reload.
  }
}

// Signing in re-renders the routes, which then open `redirectTo` (see AppRoutes).
function DevPreviewSignInForm() {
  const { previewSignIn } = useEmployeeAuth();
  return (
    <div className="space-y-4 rounded-[18px] border border-dashed border-neutral-300 bg-neutral-50 p-4" data-testid="dev-preview-sign-in">
      <h1 className="emp-h1">Sign in</h1>
      <p className="text-neutral-600">Clerk's sign-in shows here. This local preview has no Clerk key.</p>
      <EmpButton block onClick={() => previewSignIn?.()}>
        Continue as preview employee
      </EmpButton>
    </div>
  );
}

export function DevPreviewAuthProvider({ children }: { children: ReactNode }) {
  const [signedIn, setSignedIn] = useState(readSignedIn);
  const value = useMemo<EmployeeAuthValue>(() => ({
    isLoaded: true,
    isSignedIn: signedIn,
    getToken: async () => (signedIn ? 'dev-preview-token' : null),
    signOut: async () => {
      writeSignedIn(false);
      setSignedIn(false);
    },
    SignInForm: DevPreviewSignInForm,
    previewSignIn: () => {
      writeSignedIn(true);
      setSignedIn(true);
    },
  }), [signedIn]);
  return <EmployeeAuthContext.Provider value={value}>{children}</EmployeeAuthContext.Provider>;
}
