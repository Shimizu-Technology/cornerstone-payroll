import { useContext, useEffect, useRef } from 'react';
import { PAYROLL_SCOPE_CHANGE_EVENT } from '@/lib/payroll-scope-change';
import { UNSAFE_DataRouterContext, useBeforeUnload, useBlocker } from 'react-router';

export const UNSAVED_PAYROLL_MESSAGE = 'You have unsaved payroll changes. Stay here and calculate payroll to save them. Leave without saving?';

function PayrollRouteBlocker({ dirty }: { dirty: boolean }) {
  const acceptedScopeChange = useRef(false);
  const blocker = useBlocker(({ currentLocation, nextLocation }) => {
    const scopeAccepted = acceptedScopeChange.current;
    acceptedScopeChange.current = false;
    return dirty && currentLocation.pathname !== nextLocation.pathname
      && !scopeAccepted && !window.confirm(UNSAVED_PAYROLL_MESSAGE);
  });
  useEffect(() => {
    const onScopeChange = (event: Event) => {
      if (dirty && !window.confirm(UNSAVED_PAYROLL_MESSAGE)) {
        event.preventDefault();
        return;
      }
      // Scope switching navigates synchronously after the event. Reuse this
      // answer only for that operation, including when the worksheet survives.
      acceptedScopeChange.current = true;
      queueMicrotask(() => { acceptedScopeChange.current = false; });
    };
    window.addEventListener(PAYROLL_SCOPE_CHANGE_EVENT, onScopeChange);
    return () => window.removeEventListener(PAYROLL_SCOPE_CHANGE_EVENT, onScopeChange);
  });
  useEffect(() => {
    if (blocker.state === 'blocked') blocker.reset();
  }, [blocker]);
  useBeforeUnload((event) => {
    if (!dirty) return;
    event.preventDefault();
    event.returnValue = '';
  });
  return null;
}

export function UnsavedPayrollChangesGuard({ dirty }: { dirty: boolean }) {
  const router = useContext(UNSAFE_DataRouterContext);
  // The application uses a data router. Isolated declarative-router embeds
  // can render the worksheet without registering a second navigation owner.
  return router ? <PayrollRouteBlocker dirty={dirty} /> : null;
}
