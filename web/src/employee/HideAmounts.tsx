import { useCallback, useEffect, useMemo, useState, type ReactNode, type ReactElement } from 'react';
import { Eye, EyeOff } from 'lucide-react';
import { HideAmountsContext, useHideAmounts } from './contexts';
import {
  readHideAmounts,
  readHideAmountsExplained,
  writeHideAmounts,
  writeHideAmountsExplained,
} from './preferences';

export function HideAmountsProvider({ children }: { children: ReactNode }): ReactElement {
  // Masked by default on every device until someone taps "Show amounts".
  const [hidden, setHiddenState] = useState(() => readHideAmounts());
  const [explainerPersisted, setExplainerPersisted] = useState(() => readHideAmountsExplained());
  const [explainerVisible, setExplainerVisible] = useState(() => hidden && !explainerPersisted);

  const markExplainerShown = useCallback(() => {
    writeHideAmountsExplained();
    setExplainerPersisted(true);
  }, []);

  const setHidden = useCallback((next: boolean) => {
    writeHideAmounts(next);
    setHiddenState(next);
    if (next && !explainerPersisted) {
      writeHideAmountsExplained();
      setExplainerPersisted(true);
      setExplainerVisible(true);
    } else {
      setExplainerVisible(false);
    }
  }, [explainerPersisted]);

  const value = useMemo(
    () => ({ hidden, setHidden, explainerVisible, markExplainerShown }),
    [hidden, setHidden, explainerVisible, markExplainerShown],
  );
  return <HideAmountsContext.Provider value={value}>{children}</HideAmountsContext.Provider>;
}

/**
 * The eye button. Uses a dynamic action label ("Show amounts" / "Hide amounts")
 * without aria-pressed so screen readers never announce a conflicting state.
 */
export function HideAmountsToggle(): ReactElement {
  const { hidden, setHidden, explainerVisible, markExplainerShown } = useHideAmounts();
  const Icon = hidden ? EyeOff : Eye;

  useEffect(() => {
    if (hidden && explainerVisible) {
      markExplainerShown();
    }
  }, [hidden, explainerVisible, markExplainerShown]);

  return (
    <span className="emp-eye-wrap">
      <button type="button" className="emp-eye" onClick={() => setHidden(!hidden)}>
        <Icon aria-hidden="true" className="size-5" />
        {hidden ? 'Show amounts' : 'Hide amounts'}
      </button>
      {explainerVisible && hidden && (
        <span className="emp-eye-note" role="status">
          Amounts stay hidden on this device until you tap Show amounts.
        </span>
      )}
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
