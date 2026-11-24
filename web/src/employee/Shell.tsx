import type { ReactElement, ReactNode } from 'react';
import { NavLink } from 'react-router';
import { Banknote, CircleHelp, FileText, House, UserRound, WifiOff, type LucideIcon } from 'lucide-react';
import { useBrand } from './contexts';
import { focusHeadingOnNextScreen } from './focus';
import { useSignOut } from './hooks';
import { useMediaQuery } from './useMediaQuery';
import { useOnline } from './useOnline';
import { BrandMark } from './ui';
import { ViewOnlyBanner, type ViewOnlyGrant } from './ViewOnlyBanner';

// The top bar starts at this width; below it the tabs sit at the bottom like a phone app.
const TOP_NAV_QUERY = '(min-width: 600px)';

const TABS: ReadonlyArray<{ to: string; label: string; wideLabel?: string; icon: LucideIcon }> = [
  { to: '/', label: 'Home', icon: House },
  { to: '/pay', label: 'Pay', icon: Banknote },
  { to: '/taxes', label: 'Taxes', wideLabel: 'Tax forms', icon: FileText },
  { to: '/my-info', label: 'My info', icon: UserRound },
  { to: '/help', label: 'Help', icon: CircleHelp },
];

function MainNav(): ReactElement {
  const wide = useMediaQuery(TOP_NAV_QUERY);
  return (
    <nav className="emp-nav" aria-label="Main">
      {TABS.map(({ to, label, wideLabel, icon: Icon }) => (
        <NavLink key={to} to={to} end={to === '/'} className="emp-tab" onClick={focusHeadingOnNextScreen}>
          <Icon aria-hidden="true" className="emp-tab-icon" />
          <span>{wide && wideLabel ? wideLabel : label}</span>
        </NavLink>
      ))}
    </nav>
  );
}

interface EmployeeShellProps {
  viewAs?: ViewOnlyGrant | null;
  /** False while the whole app can't load (error, offline, too many tries): the tabs would lead nowhere. */
  showNav?: boolean;
  children: ReactNode;
}

/**
 * The signed-in frame. Phone: header, content, and five tabs at the bottom.
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
              <span className="emp-brand-sub">Employee pay</span>
            </span>
          </span>
          {showNav && <MainNav />}
          <button type="button" className="emp-btn emp-btn-quiet emp-header-signout" onClick={signOut}>
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
