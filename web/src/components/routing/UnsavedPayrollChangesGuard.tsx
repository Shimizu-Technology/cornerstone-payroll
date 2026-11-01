import { useContext, useEffect } from 'react';
import { UNSAFE_DataRouterContext, useBeforeUnload, useBlocker } from 'react-router';

export const UNSAVED_PAYROLL_MESSAGE = 'You have unsaved payroll changes. Stay here and calculate payroll to save them. Leave without saving?';

function PayrollRouteBlocker({ dirty }: { dirty: boolean }) {
  const blocker = useBlocker(({ currentLocation, nextLocation }) => dirty
    && currentLocation.pathname !== nextLocation.pathname
    && !window.confirm(UNSAVED_PAYROLL_MESSAGE));
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
