import { useContext, useEffect } from 'react';
import { pageTitle } from './brand';
import { SignOutContext, useBrand, type SignOutValue } from './contexts';

/** Sets the browser tab title, e.g. "Pay stubs · MoSa's employee app". */
export function useDocumentTitle(title: string): void {
  const brand = useBrand();
  useEffect(() => {
    document.title = pageTitle(title, brand);
  }, [title, brand]);
}

/**
 * Signs out and returns to Welcome or to the invite when switching accounts. Resolves
 * false, with a message and a retry on screen, when sign-out fails.
 */
export function useSignOut(): SignOutValue['signOut'] {
  const value = useContext(SignOutContext);
  if (!value) throw new Error('useSignOut needs SignOutProvider');
  return value.signOut;
}
