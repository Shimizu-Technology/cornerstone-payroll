import { useCallback, useMemo, useState, type ReactElement, type ReactNode } from 'react';
import { CircleAlert } from 'lucide-react';
import { SignOutContext, useEmployeeAuth, type SignOutValue } from './contexts';
import { clearSigningOut, markSigningOut } from './routing';
import { EmpButton } from './ui';

/**
 * One place that signs out, so every Sign out button behaves the same: it
 * lands on Welcome, and when sign-out fails (Clerk can reject, for example on
 * a dropped connection) it says so and offers to try again instead of leaving
 * the person stuck or half signed out.
 */
export function SignOutProvider({ children }: { children: ReactNode }): ReactElement {
  const { signOut: authSignOut } = useEmployeeAuth();
  const [failed, setFailed] = useState(false);

  const signOut = useCallback(async (): Promise<boolean> => {
    setFailed(false);
    markSigningOut();
    try {
      await authSignOut();
      return true;
    } catch {
      // Still signed in: a later deep link must work as usual.
      clearSigningOut();
      setFailed(true);
      return false;
    }
  }, [authSignOut]);

  const value = useMemo<SignOutValue>(() => ({ signOut }), [signOut]);
  return (
    <SignOutContext.Provider value={value}>
      {children}
      {failed && (
        <div className="emp-notice" role="alert">
          <CircleAlert aria-hidden="true" className="size-6 shrink-0 text-danger-700" />
          <p className="min-w-0 flex-1 font-semibold">Couldn't sign you out. Try again.</p>
          <EmpButton variant="secondary" className="emp-notice-button" onClick={() => { void signOut(); }}>Try again</EmpButton>
        </div>
      )}
    </SignOutContext.Provider>
  );
}
