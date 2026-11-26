import { useCallback, useMemo, useState, type ReactElement, type ReactNode } from 'react';
import { CircleAlert } from 'lucide-react';
import { SignOutContext, useEmployeeAuth, type SignOutValue } from './contexts';
import { clearSigningOut, markSigningOut } from './routing';
import { forgetInviteToken } from './signupState';
import { EmpButton } from './ui';
import { resetAnalytics } from '@/lib/analytics';

/**
 * One place that signs out, so every Sign out button behaves the same: it
 * lands on Welcome by default, and when sign-out fails (Clerk can reject, for example on
 * a dropped connection) it says so and offers to try again instead of leaving
 * the person stuck or half signed out.
 */
export function SignOutProvider({ children }: { children: ReactNode }): ReactElement {
  const { signOut: authSignOut } = useEmployeeAuth();
  const [failedDestination, setFailedDestination] = useState<'/' | '/claim' | null>(null);

  const signOut = useCallback(async (redirectTo: '/' | '/claim' = '/'): Promise<boolean> => {
    setFailedDestination(null);
    if (redirectTo === '/') {
      markSigningOut();
      forgetInviteToken();
    }
    resetAnalytics();
    try {
      await authSignOut(redirectTo);
      return true;
    } catch {
      // Still signed in: a later deep link must work as usual.
      clearSigningOut();
      setFailedDestination(redirectTo);
      return false;
    }
  }, [authSignOut]);

  const value = useMemo<SignOutValue>(() => ({ signOut }), [signOut]);
  return (
    <SignOutContext.Provider value={value}>
      {children}
      {failedDestination && (
        <div className="emp-notice" role="alert">
          <CircleAlert aria-hidden="true" className="size-6 shrink-0 text-danger-700" />
          <p className="min-w-0 flex-1 font-semibold">Couldn't sign you out. Try again.</p>
          <EmpButton variant="secondary" className="emp-notice-button" onClick={() => { void signOut(failedDestination); }}>Try again</EmpButton>
        </div>
      )}
    </SignOutContext.Provider>
  );
}
