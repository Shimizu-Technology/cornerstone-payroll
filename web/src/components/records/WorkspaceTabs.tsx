import { useEffect, useRef, type ReactElement } from 'react';
import type { LucideIcon } from 'lucide-react';
import { NavLink, useLocation } from 'react-router';

export interface WorkspaceTab {
  id: string;
  label: string;
  href: string;
  icon: LucideIcon;
  count?: number;
}

interface WorkspaceTabsProps {
  label: string;
  tabs: WorkspaceTab[];
}

export function WorkspaceTabs({ label, tabs }: WorkspaceTabsProps): ReactElement {
  const navRef = useRef<HTMLElement>(null);
  const location = useLocation();

  useEffect(() => {
    const activeTab = navRef.current?.querySelector<HTMLElement>('[aria-current="page"]');
    if (typeof activeTab?.scrollIntoView === 'function') {
      activeTab.scrollIntoView({ block: 'nearest', inline: 'center' });
    }
  }, [location.pathname]);

  return (
    <nav ref={navRef} aria-label={label} className="overflow-x-auto border-b border-neutral-200 bg-white px-4 sm:px-6 lg:px-8">
      <div className="flex min-w-max gap-2">
        {tabs.map(({ id, label: tabLabel, href, icon: Icon, count }): ReactElement => (
          <NavLink
            key={id}
            to={href}
            preventScrollReset
            className={({ isActive }) => [
              'inline-flex min-h-11 items-center gap-2 border-b-2 px-4 text-sm font-bold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2',
              isActive
                ? 'border-primary-700 text-primary-800'
                : 'border-transparent text-neutral-500 hover:border-neutral-300 hover:text-neutral-950',
            ].join(' ')}
          >
            <Icon className="h-4 w-4" />
            {tabLabel}
            {typeof count === 'number' && count > 0 && (
              <span className="inline-flex h-6 min-w-6 items-center justify-center rounded-full bg-primary-50 px-2 text-[11px] font-extrabold tabular-nums text-primary-800">
                {count}
              </span>
            )}
          </NavLink>
        ))}
      </div>
    </nav>
  );
}
