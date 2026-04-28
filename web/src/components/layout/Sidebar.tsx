import { createPortal } from 'react-dom';
import { useEffect, useRef, useState } from 'react';
import { NavLink } from 'react-router-dom';
import {
  UserCog,
  ClipboardList,
  Shield,
  Building2,
  LayoutDashboard,
  Users,
  Building,
  CalendarDays,
  FileBarChart2,
  FileSpreadsheet,
  FolderOpen,
  HandCoins,
  SlidersHorizontal,
  Printer,
  Bell,
  Settings,
  Wrench,
  ScanLine,
  PanelLeftClose,
  PanelLeftOpen,
  Files,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { useAuth } from '@/contexts/AuthContext';
import { CompanySwitcher } from './CompanySwitcher';

interface NavItem {
  name: string;
  href: string;
  icon: React.ReactNode;
}

interface SidebarProps {
  className?: string;
  onNavigate?: () => void;
  collapsed?: boolean;
  onToggleCollapse?: () => void;
}

const clientNavigation: NavItem[] = [
  { name: 'Dashboard', href: '/', icon: <LayoutDashboard className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Employees', href: '/employees', icon: <Users className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Departments', href: '/departments', icon: <Building className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Pay Periods', href: '/pay-periods', icon: <CalendarDays className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Reports', href: '/reports', icon: <FileBarChart2 className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Employee Loans', href: '/employee-loans', icon: <HandCoins className="h-[18px] w-[18px] shrink-0" /> },
];

const portalNavigation: NavItem[] = [
  { name: 'Dashboard', href: '/', icon: <LayoutDashboard className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Employees', href: '/employees', icon: <Users className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Departments', href: '/departments', icon: <Building className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Pay Periods', href: '/pay-periods', icon: <CalendarDays className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Reports', href: '/reports', icon: <FileBarChart2 className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Documents', href: '/documents', icon: <FolderOpen className="h-[18px] w-[18px] shrink-0" /> },
];

const toolsNavigation: NavItem[] = [
  { name: 'Timecard OCR', href: '/tools/timecard-ocr', icon: <ScanLine className="h-[18px] w-[18px] shrink-0" /> },
];

const clientSettingsNavigation: NavItem[] = [
  { name: 'Check Settings', href: '/check-settings', icon: <Printer className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Payroll Reminders', href: '/payroll-reminders', icon: <Bell className="h-[18px] w-[18px] shrink-0" /> },
];

const adminNavigation: NavItem[] = [
  { name: 'Client Management', href: '/settings/clients', icon: <Building2 className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Tax Configuration', href: '/settings/tax-config', icon: <SlidersHorizontal className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'User Management', href: '/settings/users', icon: <UserCog className="h-[18px] w-[18px] shrink-0" /> },
  { name: 'Audit Logs', href: '/settings/audit-logs', icon: <ClipboardList className="h-[18px] w-[18px] shrink-0" /> },
];

const portalAdminNavigation: NavItem[] = [
  { name: 'Client Documents', href: '/settings/client-documents', icon: <Files className="h-[18px] w-[18px] shrink-0" /> },
];

function FloatingTooltip({ anchorRef, label, visible }: { anchorRef: React.RefObject<HTMLElement | null>; label: string; visible: boolean }) {
  const [position, setPosition] = useState<{ top: number; left: number } | null>(null);

  useEffect(() => {
    if (!visible) return;

    const updatePosition = () => {
      const anchor = anchorRef.current;
      if (!anchor) return;
      const rect = anchor.getBoundingClientRect();
      setPosition({
        top: rect.top + rect.height / 2,
        left: rect.right + 18,
      });
    };

    updatePosition();
    window.addEventListener('resize', updatePosition);
    window.addEventListener('scroll', updatePosition, true);

    return () => {
      window.removeEventListener('resize', updatePosition);
      window.removeEventListener('scroll', updatePosition, true);
    };
  }, [anchorRef, visible]);

  if (!visible || !position || typeof document === 'undefined') return null;

  return createPortal(
    <div
      className="pointer-events-none fixed z-[120] flex -translate-y-1/2 items-center"
      style={{ top: position.top, left: position.left }}
    >
      <span className="h-3 w-3 translate-x-[7px] rotate-45 rounded-[3px] bg-neutral-950 shadow-lg shadow-neutral-900/25" />
      <span className="whitespace-nowrap rounded-xl bg-neutral-950 px-3.5 py-2 text-sm font-semibold text-white shadow-2xl shadow-neutral-900/30">
        {label}
      </span>
    </div>,
    document.body
  );
}

function CollapsedNavLink({
  item,
  collapsed,
  onNavigate,
}: {
  item: NavItem;
  collapsed?: boolean;
  onNavigate?: () => void;
}) {
  const anchorRef = useRef<HTMLAnchorElement | null>(null);
  const [tooltipVisible, setTooltipVisible] = useState(false);

  return (
    <>
      <NavLink
        ref={anchorRef}
        to={item.href}
        onClick={onNavigate}
        aria-label={item.name}
        onMouseEnter={() => setTooltipVisible(true)}
        onMouseLeave={() => setTooltipVisible(false)}
        onFocus={() => setTooltipVisible(true)}
        onBlur={() => setTooltipVisible(false)}
        className={({ isActive }) =>
          cn(
            'group relative flex items-center rounded-xl text-sm font-medium transition-all duration-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2',
            collapsed ? 'justify-center px-2 py-2.5' : 'gap-3 px-3 py-2.5',
            isActive
              ? collapsed
                ? 'bg-primary-100 text-primary-800 shadow-sm ring-1 ring-primary-300'
                : 'bg-primary-50 text-primary-700 shadow-sm ring-1 ring-primary-200'
              : collapsed
                ? 'text-neutral-600 hover:bg-primary-50 hover:text-primary-700 hover:ring-1 hover:ring-primary-200'
                : 'text-neutral-600 hover:bg-neutral-100 hover:text-neutral-900'
          )
        }
      >
        {item.icon}
        {!collapsed && <span>{item.name}</span>}
      </NavLink>
      {collapsed && <FloatingTooltip anchorRef={anchorRef} label={item.name} visible={tooltipVisible} />}
    </>
  );
}

function NavSection({ items, collapsed, onNavigate }: { items: NavItem[]; collapsed?: boolean; onNavigate?: () => void }) {
  return (
    <>
      {items.map((item) => (
        <CollapsedNavLink key={item.name} item={item} collapsed={collapsed} onNavigate={onNavigate} />
      ))}
    </>
  );
}

function SectionDivider({ icon, label, collapsed }: { icon: React.ReactNode; label: string; collapsed?: boolean }) {
  return (
    <div className={cn('my-5', collapsed ? 'px-1' : 'px-2')}>
      <div className={cn(
        'flex items-center border-t border-neutral-200 pt-4',
        collapsed ? 'justify-center' : 'gap-2'
      )}>
        {icon}
        {!collapsed && (
          <span className="text-[11px] font-semibold uppercase tracking-[0.12em] text-neutral-400">
            {label}
          </span>
        )}
      </div>
    </div>
  );
}

export function Sidebar({ className, onNavigate, collapsed = false, onToggleCollapse }: SidebarProps) {
  const { user } = useAuth();
  const isAdmin = user?.role === 'admin';
  const isClient = user?.role === 'client';
  const collapseButtonRef = useRef<HTMLButtonElement | null>(null);
  const [collapseTooltipVisible, setCollapseTooltipVisible] = useState(false);
  const primaryNavigation = isClient ? portalNavigation : clientNavigation;

  return (
    <aside className={cn(
      'relative z-30 flex flex-col border-r border-neutral-200/80 bg-white/90 backdrop-blur-sm transition-[width] duration-150 ease-in-out overflow-visible',
      collapsed ? 'w-16' : 'w-72',
      className
    )}>
      {/* Logo */}
      <div className="border-b border-neutral-200/70 px-3 py-5">
        <div className={cn('flex items-center', collapsed ? 'justify-center' : 'gap-3 px-3')}>
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-gradient-to-br from-primary-600 to-primary-800 text-white shadow-md shadow-primary-700/25">
            <span className="text-sm font-bold tracking-tight">CP</span>
          </div>
          {!collapsed && (
            <div>
              <p className="text-sm font-semibold tracking-tight text-neutral-900">Cornerstone Payroll</p>
              <p className="text-xs text-neutral-500">Payroll workspace</p>
            </div>
          )}
        </div>
      </div>

      {/* Company switcher — hide when collapsed */}
      {!collapsed && <CompanySwitcher />}

      {/* Nav */}
      <nav className={cn('flex-1 overflow-y-auto py-4', collapsed ? 'px-2' : 'px-4')}>
        <div className="space-y-1.5">
          <NavSection items={primaryNavigation} collapsed={collapsed} onNavigate={onNavigate} />
        </div>

        {!isClient && (
          <>
            <SectionDivider icon={<Wrench className="h-3.5 w-3.5 text-neutral-400 shrink-0" />} label="Tools" collapsed={collapsed} />
            <div className="space-y-1.5">
              <NavSection items={toolsNavigation} collapsed={collapsed} onNavigate={onNavigate} />
            </div>
          </>
        )}

        {!isClient && (
          <>
            <SectionDivider icon={<Settings className="h-3.5 w-3.5 text-neutral-400 shrink-0" />} label="Settings" collapsed={collapsed} />
            <div className="space-y-1.5">
              <NavSection items={clientSettingsNavigation} collapsed={collapsed} onNavigate={onNavigate} />
            </div>
          </>
        )}

        {!isClient && (
          <>
            <SectionDivider icon={<FileSpreadsheet className="h-3.5 w-3.5 text-neutral-400 shrink-0" />} label="Client Portal" collapsed={collapsed} />
            <div className="space-y-1.5">
              <NavSection items={portalAdminNavigation} collapsed={collapsed} onNavigate={onNavigate} />
            </div>
          </>
        )}

        {isAdmin && (
          <>
            <SectionDivider icon={<Shield className="h-3.5 w-3.5 text-neutral-400 shrink-0" />} label="Administration" collapsed={collapsed} />
            <div className="space-y-1.5">
              <NavSection items={adminNavigation} collapsed={collapsed} onNavigate={onNavigate} />
            </div>
          </>
        )}
      </nav>

      {/* Collapse toggle + user */}
      <div className="border-t border-neutral-200/70 p-3 space-y-2">
        {onToggleCollapse && (
          <button
            ref={collapseButtonRef}
            onClick={onToggleCollapse}
            onMouseEnter={() => setCollapseTooltipVisible(true)}
            onMouseLeave={() => setCollapseTooltipVisible(false)}
            onFocus={() => setCollapseTooltipVisible(true)}
            onBlur={() => setCollapseTooltipVisible(false)}
            className={cn(
              'group relative flex w-full items-center rounded-lg px-2 py-2 text-neutral-500 hover:bg-neutral-100 hover:text-neutral-700 transition-colors',
              collapsed ? 'justify-center' : 'gap-2'
            )}
            aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          >
            {collapsed
              ? <PanelLeftOpen className="h-4 w-4" />
              : <><PanelLeftClose className="h-4 w-4" /><span className="text-xs">Collapse</span></>
            }
          </button>
        )}
        {collapsed && <FloatingTooltip anchorRef={collapseButtonRef} label="Expand sidebar" visible={collapseTooltipVisible} />}
        <div className={cn(
          'flex items-center rounded-xl border border-neutral-200/80 bg-neutral-50/70',
          collapsed ? 'justify-center px-1.5 py-2' : 'gap-3 px-3 py-2.5'
        )}>
          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary-100 text-sm font-semibold text-primary-700">
            {(user?.name || 'User').charAt(0).toUpperCase()}
          </div>
          {!collapsed && (
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium text-neutral-900">{user?.name || 'User'}</p>
              <p className="truncate text-xs text-neutral-500">
                {user?.role ? user.role.charAt(0).toUpperCase() + user.role.slice(1) : 'User'}
              </p>
            </div>
          )}
        </div>
      </div>
    </aside>
  );
}
