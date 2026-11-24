import { useCallback, useEffect } from 'react';
import { pageTitle } from './brand';
import { useBrand, useEmployeeAuth } from './contexts';
import { markSigningOut } from './routing';

/** Sets the browser tab title, e.g. "Pay stubs · MoSa's employee app". */
export function useDocumentTitle(title: string): void {
  const brand = useBrand();
  useEffect(() => {
    document.title = pageTitle(title, brand);
  }, [title, brand]);
}

/**
 * Signs out and lands on the Welcome screen. The page the person signed out
 * from never becomes the "return here after sign-in" target (AppRoutes).
 */
export function useSignOut(): () => void {
  const { signOut } = useEmployeeAuth();
  return useCallback((): void => {
    markSigningOut();
    void signOut();
  }, [signOut]);
}
