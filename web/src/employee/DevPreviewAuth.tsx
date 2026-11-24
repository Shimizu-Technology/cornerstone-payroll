// Local development without a Clerk key, and the public Playwright suite.
// EmployeeApp only mounts this when import.meta.env.DEV is true, so it is
// tree-shaken out of every production build (appSurfaceBuild.test.ts checks).
import { useCallback, useMemo, useRef, useState, type ReactNode, type ReactElement } from 'react';
import { useNavigate } from 'react-router';
import { StepUpCancelledError, StepUpRequiredError } from './api';
import { EmployeeAuthContext, useEmployeeAuth, type EmployeeAuthValue } from './contexts';
import { EmpButton } from './ui';

const STORAGE_KEY = 'employee-dev-preview-signed-in';

// `?previewSignOutFails=N` makes the next N sign-outs fail, to exercise the
// "Couldn't sign you out" path the way a Clerk rejection would. Read when the
// provider mounts (the router later drops the query string), not when this
// module loads: load-time code would keep the module in production bundles.
function readSignOutFailures(): number {
  return Number(new URLSearchParams(window.location.search).get('previewSignOutFails')) || 0;
}

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
function DevPreviewSignInForm(): ReactElement {
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

// Clerk's sign-up opens here from the invitation URL. Finishing signs in and
// opens `redirectTo`, as Clerk's forceRedirectUrl does.
function DevPreviewSignUpForm({ redirectTo }: { redirectTo: string }): ReactElement {
  const { previewSignIn } = useEmployeeAuth();
  const navigate = useNavigate();
  return (
    <div className="space-y-4 rounded-[18px] border border-dashed border-neutral-300 bg-neutral-50 p-4" data-testid="dev-preview-sign-up">
      <h1 className="emp-h1">Create your account</h1>
      <p className="text-neutral-600">Clerk's sign-up shows here. This local preview has no Clerk key.</p>
      <EmpButton block onClick={() => { previewSignIn?.(); navigate(redirectTo, { replace: true }); }}>
        Finish preview sign-up
      </EmpButton>
    </div>
  );
}

/** Stands in for Clerk's "confirm it's you" prompt. Any code works. */
function DevPreviewStepUp({ onConfirm, onCancel }: { onConfirm: () => void; onCancel: () => void }): ReactElement {
  return (
    <div className="emp-dialog-backdrop">
      <div role="dialog" aria-modal="true" aria-labelledby="dev-step-up-title" className="emp-dialog" data-testid="dev-preview-step-up">
        <h2 id="dev-step-up-title" className="emp-h1 text-[1.4rem]">Confirm it's you</h2>
        <p className="text-neutral-600">Clerk asks for your password or an emailed code here. This local preview has no Clerk key.</p>
        <label className="emp-label" htmlFor="dev-step-up-code">Code</label>
        <input id="dev-step-up-code" className="emp-input" inputMode="numeric" autoComplete="one-time-code" autoFocus />
        <div className="emp-form-buttons">
          <EmpButton onClick={onConfirm}>Confirm</EmpButton>
          <EmpButton variant="quiet" onClick={onCancel}>Cancel</EmpButton>
        </div>
      </div>
    </div>
  );
}

export function DevPreviewAuthProvider({ children }: { children: ReactNode }): ReactElement {
  const [signedIn, setSignedIn] = useState(readSignedIn);
  const signOutFailuresLeft = useRef<number | null>(null);
  signOutFailuresLeft.current ??= readSignOutFailures();
  // After the preview prompt, tokens say so, the way a fresh Clerk token carries fva.
  const verified = useRef(false);
  const [prompt, setPrompt] = useState<{ confirm: () => void; cancel: () => void } | null>(null);

  const stepUp = useCallback(async <T,>(attempt: () => Promise<T>): Promise<T> => {
    try {
      return await attempt();
    } catch (error) {
      if (!(error instanceof StepUpRequiredError)) throw error;
    }
    await new Promise<void>((resolve, reject) => {
      setPrompt({
        confirm: () => { verified.current = true; setPrompt(null); resolve(); },
        cancel: () => { setPrompt(null); reject(new StepUpCancelledError()); },
      });
    });
    return attempt();
  }, []);

  const value = useMemo<EmployeeAuthValue>(() => ({
    isLoaded: true,
    isSignedIn: signedIn,
    getToken: async () => (signedIn ? (verified.current ? 'dev-preview-token-verified' : 'dev-preview-token') : null),
    signOut: async (): Promise<void> => {
      if ((signOutFailuresLeft.current ?? 0) > 0) {
        signOutFailuresLeft.current = (signOutFailuresLeft.current ?? 0) - 1;
        throw new Error('Preview sign-out failed');
      }
      writeSignedIn(false);
      verified.current = false;
      setSignedIn(false);
    },
    SignInForm: DevPreviewSignInForm,
    SignUpForm: DevPreviewSignUpForm,
    stepUp,
    previewSignIn: () => {
      writeSignedIn(true);
      setSignedIn(true);
    },
  }), [signedIn, stepUp]);
  return (
    <EmployeeAuthContext.Provider value={value}>
      {children}
      {prompt && <DevPreviewStepUp onConfirm={prompt.confirm} onCancel={prompt.cancel} />}
    </EmployeeAuthContext.Provider>
  );
}
