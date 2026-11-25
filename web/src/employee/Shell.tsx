import { useEffect, useRef, useState, type ReactElement, type ReactNode } from 'react';
import { Link, NavLink, useLocation } from 'react-router';
import { Banknote, Building2, CircleHelp, FileText, House, LogOut, ShieldCheck, UserRound, WifiOff, type LucideIcon } from 'lucide-react';
import { useBrand, useEmployeeSession } from './contexts';
import { focusHeadingOnNextScreen } from './focus';
import { useSignOut } from './hooks';
import { SECURITY_PATH } from './security';
import { useOnline } from './useOnline';
import { BrandMark } from './ui';
import { ViewOnlyBanner, type ViewOnlyGrant } from './ViewOnlyBanner';

const TABS: ReadonlyArray<{ to: string; label: string; icon: LucideIcon }> = [
  { to: '/', label: 'Home', icon: House },
  { to: '/pay', label: 'Pay', icon: Banknote },
  { to: '/taxes', label: 'Tax forms', icon: FileText },
  { to: '/my-info', label: 'My info', icon: UserRound },
  { to: '/help', label: 'Help', icon: CircleHelp },
];

function MainNav(): ReactElement {
  return (
    <nav className="emp-nav" aria-label="Main">
      {TABS.map(({ to, label, icon: Icon }) => (
        <NavLink key={to} to={to} end={to === '/'} className="emp-tab" onClick={focusHeadingOnNextScreen}>
          <Icon aria-hidden="true" className="emp-tab-icon" />
          <span>{label}</span>
        </NavLink>
      ))}
    </nav>
  );
}

/** Compact phone header menu so Sign out and Switch employer are reachable from any screen. */
function PhoneAccountMenu(): ReactElement {
  const { state, chooseLink, isViewOnly } = useEmployeeSession();
  const signOut = useSignOut();
  const location = useLocation();
  const [open, setOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    setOpen(false);
  }, [location.pathname]);

  useEffect(() => {
    if (!open) return undefined;
    const onPointerDown = (event: PointerEvent): void => {
      if (wrapRef.current && !wrapRef.current.contains(event.target as Node)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        setOpen(false);
        buttonRef.current?.focus();
      }
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);

  const ready = state.status === 'ready' ? state : null;
  const firstName = ready?.info.firstName ?? null;
  const canSwitchEmployer = Boolean(ready && ready.links.length > 1);
  const showSecurityLink = Boolean(ready && !isViewOnly);

  return (
    <div ref={wrapRef} className="emp-header-account-wrap">
      <button
        ref={buttonRef}
        type="button"
        className="emp-btn emp-btn-quiet emp-header-account"
        aria-expanded={open}
        aria-haspopup="menu"
        aria-controls="emp-account-menu"
        aria-label={firstName ? `Account, ${firstName}` : 'Account'}
        onClick={() => setOpen((current) => !current)}
      >
        <UserRound aria-hidden="true" className="size-5 shrink-0" />
        <span>Account</span>
      </button>
      {open && (
        <div id="emp-account-menu" className="emp-account-menu" role="menu" aria-label="Account">
          {firstName && <p className="emp-account-name">{firstName}</p>}
          {canSwitchEmployer && (
            <button
              type="button"
              role="menuitem"
              className="emp-account-item"
              onClick={() => {
                setOpen(false);
                chooseLink(null);
              }}
            >
              <Building2 aria-hidden="true" className="size-5 shrink-0 text-neutral-600" />
              Switch employer
            </button>
          )}
          {showSecurityLink && (
            <Link
              to={SECURITY_PATH}
              role="menuitem"
              className="emp-account-item"
              onClick={() => setOpen(false)}
            >
              <ShieldCheck aria-hidden="true" className="size-5 shrink-0 text-neutral-600" />
              Sign-in &amp; security
            </Link>
          )}
          <button
            type="button"
            role="menuitem"
            className="emp-account-item"
            onClick={() => {
              setOpen(false);
              void signOut();
            }}
          >
            <LogOut aria-hidden="true" className="size-5 shrink-0 text-neutral-600" />
            Sign out
          </button>
        </div>
      )}
    </div>
  );
}

interface EmployeeShellProps {
  viewAs?: ViewOnlyGrant | null;
  /** False while the whole app can't load (error, offline, too many tries): the tabs would lead nowhere. */
  showNav?: boolean;
  children: ReactNode;
}

/**
 * The signed-in frame. Phone: header with Account menu, content, and five tabs at the bottom.
 * From 600px: a top bar with the tabs and Sign out, and centered content.
 */
export function EmployeeShell({ viewAs, showNav = true, children }: EmployeeShellProps): ReactElement {
  const brand = useBrand();
  const online = useOnline();
  const signOut = useSignOut();
  return (
    <div className="emp-shell" data-banner={viewAs ? 'true' : undefined} data-nav={showNav ? undefined : 'hidden'}>
      {viewAs && <ViewOnlyBanner {...viewAs} />}
      <header className="emp-header">
        <div className="emp-header-inner">
          <span className="emp-brand">
            <BrandMark />
            <span className="emp-brand-text">
              <span className="emp-brand-name">{brand.name}</span>
              <span className="emp-brand-sub">{brand.appName ?? 'Employee pay'}</span>
            </span>
          </span>
          {showNav && <MainNav />}
          <PhoneAccountMenu />
          <button type="button" className="emp-btn emp-btn-quiet emp-header-signout" onClick={() => { void signOut(); }}>
            Sign out
          </button>
        </div>
      </header>
      {!online && (
        <div className="emp-offline-bar" role="status">
          <WifiOff aria-hidden="true" className="size-5 shrink-0" />
          You're offline
        </div>
      )}
      <main id="emp-main" className="emp-main">
        <div className="emp-container">{children}</div>
      </main>
    </div>
  );
}
