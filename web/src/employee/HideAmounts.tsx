import { useCallback, useMemo, useState, type ReactNode, type ReactElement } from 'react';
import { Eye, EyeOff } from 'lucide-react';
import { HideAmountsContext, useHideAmounts } from './contexts';
import { readHideAmounts, writeHideAmounts } from './preferences';

export function HideAmountsProvider({ children }: { children: ReactNode }): ReactElement {
  // Off by default: it would add a tap to the one thing people open the app for.
  const [hidden, setHiddenState] = useState(() => readHideAmounts());
  const setHidden = useCallback((next: boolean) => {
    writeHideAmounts(next);
    setHiddenState(next);
  }, []);
  const value = useMemo(() => ({ hidden, setHidden }), [hidden, setHidden]);
  return <HideAmountsContext.Provider value={value}>{children}</HideAmountsContext.Provider>;
}

// Once per page load, the first time someone hides amounts, one line says what it does (§8a).
let explained = false;

/** The eye button. Its label says what tapping it will do. */
export function HideAmountsToggle(): ReactElement {
  const { hidden, setHidden } = useHideAmounts();
  const [note, setNote] = useState(false);
  const Icon = hidden ? EyeOff : Eye;
  const toggle = (): void => {
    if (!hidden && !explained) {
      explained = true;
      setNote(true);
    } else {
      setNote(false);
    }
    setHidden(!hidden);
  };
  return (
    <span className="emp-eye-wrap">
      <button type="button" className="emp-eye" onClick={toggle}>
        <Icon aria-hidden="true" className="size-5" />
        {hidden ? 'Show amounts' : 'Hide amounts'}
      </button>
      {note && hidden && <span className="emp-eye-note" role="status">Amounts stay hidden on this device until you tap Show amounts.</span>}
    </span>
  );
}

/** Any amount on screen. Shows "$•••" while amounts are hidden, and says so to screen readers. */
export function Amount({ children }: { children: ReactNode }): ReactElement {
  const { hidden } = useHideAmounts();
  if (!hidden) return <span className="tabular-nums">{children}</span>;
  return (
    <span className="tabular-nums">
      <span aria-hidden="true">$•••</span>
      <span className="sr-only">Amount hidden</span>
    </span>
  );
}
