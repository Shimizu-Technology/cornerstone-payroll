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
  Calculator,
  FileBarChart2,
  HandCoins,
  SlidersHorizontal,
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
}

const clientNavigation: NavItem[] = [
  {
    name: 'Dashboard',
    href: '/',
    icon: <LayoutDashboard className="h-[18px] w-[18px]" />,
  },
  {
    name: 'Employees',
    href: '/employees',
    icon: <Users className="h-[18px] w-[18px]" />,
  },
  {
    name: 'Departments',
    href: '/departments',
    icon: <Building className="h-[18px] w-[18px]" />,
  },
  {
    name: 'Pay Periods',
    href: '/pay-periods',
    icon: <CalendarDays className="h-[18px] w-[18px]" />,
  },
  {
    name: 'Run Payroll',
    href: '/payroll/run',
    icon: <Calculator className="h-[18px] w-[18px]" />,
  },
  {
    name: 'Reports',
    href: '/reports',
    icon: <FileBarChart2 className="h-[18px] w-[18px]" />,
  },
  {
    name: 'Employee Loans',
    href: '/employee-loans',
    icon: <HandCoins className="h-[18px] w-[18px]" />,
  },
];

const adminNavigation: NavItem[] = [
  {
    name: 'Client Management',
    href: '/settings/clients',
    icon: <Building2 className="h-[18px] w-[18px]" />,
  },
  {
    name: 'Tax Configuration',
    href: '/settings/tax-config',
    icon: <SlidersHorizontal className="h-[18px] w-[18px]" />,
  },
  {
    name: 'User Management',
    href: '/settings/users',
    icon: <UserCog className="h-[18px] w-[18px]" />,
  },
  {
    name: 'Audit Logs',
    href: '/settings/audit-logs',
    icon: <ClipboardList className="h-[18px] w-[18px]" />,
  },
];

function NavSection({ items, onNavigate }: { items: NavItem[]; onNavigate?: () => void }) {
  return (
    <>
      {items.map((item) => (
        <NavLink
          key={item.name}
          to={item.href}
          onClick={onNavigate}
          className={({ isActive }) =>
            cn(
              'flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium transition-all duration-200',
              isActive
                ? 'bg-primary-50 text-primary-700 shadow-sm ring-1 ring-primary-200'
                : 'text-neutral-600 hover:bg-neutral-100 hover:text-neutral-900'
            )
          }
        >
          {item.icon}
          {item.name}
        </NavLink>
      ))}
    </>
  );
}

export function Sidebar({ className, onNavigate }: SidebarProps) {
  const { user } = useAuth();
  const isAdmin = user?.role === 'admin';

  return (
    <aside className={cn('flex w-72 flex-col border-r border-neutral-200/80 bg-white/90 backdrop-blur-sm', className)}>
      <div className="border-b border-neutral-200/70 px-6 py-5">
        <div className="flex items-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-gradient-to-br from-primary-600 to-primary-800 text-white shadow-md shadow-primary-700/25">
            <span className="text-sm font-bold tracking-tight">CP</span>
          </div>
          <div>
            <p className="text-sm font-semibold tracking-tight text-neutral-900">Cornerstone Payroll</p>
            <p className="text-xs text-neutral-500">Payroll workspace</p>
          </div>
        </div>
      </div>

      <CompanySwitcher />

      <nav className="flex-1 overflow-y-auto px-4 py-4">
        <div className="space-y-1.5">
          <NavSection items={clientNavigation} onNavigate={onNavigate} />
        </div>

        {isAdmin && (
          <>
            <div className="my-5 px-2">
              <div className="flex items-center gap-2 border-t border-neutral-200 pt-4">
                <Shield className="h-3.5 w-3.5 text-neutral-400" />
                <span className="text-[11px] font-semibold uppercase tracking-[0.12em] text-neutral-400">
                  Administration
                </span>
              </div>
            </div>
            <div className="space-y-1.5">
              <NavSection items={adminNavigation} onNavigate={onNavigate} />
            </div>
          </>
        )}
      </nav>

      <div className="border-t border-neutral-200/70 p-4">
        <div className="flex items-center gap-3 rounded-xl border border-neutral-200/80 bg-neutral-50/70 px-3 py-2.5">
          <div className="flex h-8 w-8 items-center justify-center rounded-full bg-primary-100 text-sm font-semibold text-primary-700">
            {(user?.name || 'User').charAt(0).toUpperCase()}
          </div>
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-medium text-neutral-900">{user?.name || 'User'}</p>
            <p className="truncate text-xs text-neutral-500">
              {user?.role ? user.role.charAt(0).toUpperCase() + user.role.slice(1) : 'User'}
            </p>
          </div>
        </div>
      </div>
    </aside>
  );
}
