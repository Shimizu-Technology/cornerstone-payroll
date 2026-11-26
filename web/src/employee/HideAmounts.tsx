import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode, type ReactElement } from 'react';
import { Eye, EyeOff } from 'lucide-react';
import { useInRouterContext, useLocation } from 'react-router';
import { HideAmountsContext, useHideAmounts } from './contexts';
import {
  HIDE_AMOUNTS_EXPLAINED_KEY,
  HIDE_AMOUNTS_KEY,
  readHideAmounts,
  readHideAmountsExplained,
  writeHideAmounts,
  writeHideAmountsExplained,
} from './preferences';

function DismissExplainerOnRouteChange({ active, onRouteChange }: { active: boolean; onRouteChange: () => void }): null {
  const { pathname } = useLocation();
  const shownAtPath = useRef<string | null>(null);

  useEffect(() => {
    if (!active) {
      shownAtPath.current = null;
      return;
    }
    if (shownAtPath.current === null) {
      shownAtPath.current = pathname;
    } else if (shownAtPath.current !== pathname) {
      shownAtPath.current = null;
      onRouteChange();
    }
  }, [active, pathname, onRouteChange]);

  return null;
}

export function HideAmountsProvider({ children }: { children: ReactNode }): ReactElement {
  // Masked by default on every device until someone taps "Show amounts".
  const [hidden, setHiddenState] = useState(() => readHideAmounts());
  const [explainerPersisted, setExplainerPersisted] = useState(() => readHideAmountsExplained());
  const [explainerVisible, setExplainerVisible] = useState(() => hidden && !explainerPersisted);
  const [explainerRendered, setExplainerRendered] = useState(false);
  const [announcement, setAnnouncement] = useState('');
  const inRouter = useInRouterContext();

  const markExplainerShown = useCallback(() => {
    writeHideAmountsExplained();
    setExplainerPersisted(true);
    setExplainerRendered(true);
  }, []);

  const dismissExplainer = useCallback(() => {
    setExplainerVisible(false);
    setExplainerRendered(false);
  }, []);

  const setHidden = useCallback((next: boolean) => {
    writeHideAmounts(next);
    setHiddenState(next);
    setAnnouncement(next ? 'Amounts hidden' : 'Amounts shown');
    if (next && !explainerPersisted) {
      writeHideAmountsExplained();
      setExplainerPersisted(true);
      setExplainerVisible(true);
      setExplainerRendered(true);
    } else {
      setExplainerVisible(false);
      setExplainerRendered(false);
    }
  }, [explainerPersisted]);

  // Keep open tabs in sync when another tab toggles amount visibility or clears storage.
  useEffect(() => {
    const onStorage = (event: StorageEvent): void => {
      if (event.key === HIDE_AMOUNTS_KEY) {
        const next = event.newValue !== 'false';
        setHiddenState(next);
        if (!next) {
          setExplainerVisible(false);
          setExplainerRendered(false);
        }
      } else if (event.key === null) {
        const next = readHideAmounts();
        setHiddenState(next);
        if (!next) {
          setExplainerVisible(false);
          setExplainerRendered(false);
        }
      }
      if (event.key === HIDE_AMOUNTS_EXPLAINED_KEY || event.key === null) {
        if (event.newValue === 'true' || readHideAmountsExplained()) {
          setExplainerPersisted(true);
          setExplainerVisible(false);
          setExplainerRendered(false);
        }
      }
    };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, []);

  const value = useMemo(
    () => ({ hidden, setHidden, explainerVisible, markExplainerShown, dismissExplainer }),
    [hidden, setHidden, explainerVisible, markExplainerShown, dismissExplainer],
  );
  return (
    <HideAmountsContext.Provider value={value}>
      {inRouter && (
        <DismissExplainerOnRouteChange
          active={explainerVisible && explainerRendered}
          onRouteChange={dismissExplainer}
        />
      )}
      {children}
      {/* Persistent, initially empty live region for screen-reader toggle announcements. */}
      <span className="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {announcement}
      </span>
    </HideAmountsContext.Provider>
  );
}

/**
 * The eye button. Uses a dynamic action label ("Show amounts" / "Hide amounts")
 * without aria-pressed so screen readers never announce a conflicting state.
 */
export function HideAmountsToggle(): ReactElement {
  const { hidden, setHidden, explainerVisible, markExplainerShown, dismissExplainer } = useHideAmounts();
  const Icon = hidden ? EyeOff : Eye;
  const mountedRef = useRef(false);
  const showedExplainerRef = useRef(false);

  useEffect(() => {
    if (hidden && explainerVisible) {
      showedExplainerRef.current = true;
      markExplainerShown();
    }
  }, [hidden, explainerVisible, markExplainerShown]);

  // Dismiss the one-time explainer on real unmount (ignoring StrictMode's synchronous double-invoke).
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      if (showedExplainerRef.current) {
        queueMicrotask(() => {
          if (!mountedRef.current) dismissExplainer();
        });
      }
    };
  }, [dismissExplainer]);

  return (
    <span className="emp-eye-wrap">
      <button type="button" className="emp-eye" onClick={() => setHidden(!hidden)}>
        <Icon aria-hidden="true" className="size-5" />
        {hidden ? 'Show amounts' : 'Hide amounts'}
      </button>
      {explainerVisible && hidden && (
        <span className="emp-eye-note">
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
