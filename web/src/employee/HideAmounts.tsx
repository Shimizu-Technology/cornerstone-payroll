import { useCallback, useMemo, useState, type ReactNode } from 'react';
import { Eye, EyeOff } from 'lucide-react';
import { HideAmountsContext, useHideAmounts } from './contexts';
import { readHideAmounts, writeHideAmounts } from './preferences';

export function HideAmountsProvider({ children }: { children: ReactNode }) {
  // Off by default: it would add a tap to the one thing people open the app for.
  const [hidden, setHiddenState] = useState(() => readHideAmounts());
  const setHidden = useCallback((next: boolean) => {
    writeHideAmounts(next);
    setHiddenState(next);
  }, []);
  const value = useMemo(() => ({ hidden, setHidden }), [hidden, setHidden]);
  return <HideAmountsContext.Provider value={value}>{children}</HideAmountsContext.Provider>;
}

/** The eye button. Its label says what tapping it will do. */
export function HideAmountsToggle() {
  const { hidden, setHidden } = useHideAmounts();
  const Icon = hidden ? EyeOff : Eye;
  return (
    <button type="button" className="emp-eye" onClick={() => setHidden(!hidden)}>
      <Icon aria-hidden="true" className="size-5" />
      {hidden ? 'Show amounts' : 'Hide amounts'}
    </button>
  );
}

/** Any amount on screen. Shows "$•••" while amounts are hidden, and says so to screen readers. */
export function Amount({ children }: { children: ReactNode }) {
  const { hidden } = useHideAmounts();
  if (!hidden) return <span className="tabular-nums">{children}</span>;
  return (
    <span className="tabular-nums">
      <span aria-hidden="true">$•••</span>
      <span className="sr-only">Amount hidden</span>
    </span>
  );
}
