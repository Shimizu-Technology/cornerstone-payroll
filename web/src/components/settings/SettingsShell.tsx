import { NavLink, Outlet, useLocation, useNavigate } from 'react-router';
import { ChevronRight } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Select } from '@/components/ui/select';
import { cn } from '@/lib/utils';
import type { SettingsNavigationItem } from './settings-navigation';

interface SettingsShellProps {
  title: string;
  description: string;
  contextLabel: string;
  contextValue?: string;
  items: SettingsNavigationItem[];
}

export function SettingsShell({ title, description, contextLabel, contextValue, items }: SettingsShellProps) {
  const location = useLocation();
  const navigate = useNavigate();
  const selected = items.find((item) => location.pathname === item.href) ?? items[0];

  return (
    <div className="min-h-full bg-neutral-50/50">
      <Header
        title={title}
        description={description}
        contextLabel={contextLabel}
        contextValue={contextValue}
      />

      <div className="mx-auto max-w-[1480px] px-4 py-6 sm:px-6 lg:px-8">
        <div className="mb-5 lg:hidden">
          <label htmlFor="settings-section" className="mb-2 block text-xs font-bold uppercase tracking-[0.14em] text-neutral-500">
            Settings section
          </label>
          <Select
            id="settings-section"
            value={selected.href}
            onChange={(event) => navigate(event.target.value)}
            className="h-12 bg-white"
          >
            {items.map((item) => <option key={item.href} value={item.href}>{item.label}</option>)}
          </Select>
        </div>

        <div className="grid items-start gap-6 lg:grid-cols-[260px_minmax(0,1fr)] xl:gap-8">
          <aside className="sticky top-6 hidden overflow-hidden rounded-[1.35rem] border border-neutral-200 bg-white shadow-[0_18px_45px_-34px_rgba(15,23,42,0.42)] lg:block">
            <div className="border-b border-neutral-100 px-5 py-4">
              <p className="text-xs font-bold uppercase tracking-[0.14em] text-primary-700">Configuration</p>
              <p className="mt-1 text-sm leading-5 text-neutral-500">Choose a section without losing the active workspace context.</p>
            </div>
            <nav className="space-y-1 p-2" aria-label={`${title} sections`}>
              {items.map((item) => (
                <NavLink
                  key={item.href}
                  to={item.href}
                  className={({ isActive }) => cn(
                    'group flex min-h-12 items-center gap-3 rounded-xl px-3 py-2.5 text-sm transition duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300',
                    isActive
                      ? 'bg-primary-50 text-primary-800 ring-1 ring-primary-200'
                      : 'text-neutral-600 hover:bg-neutral-50 hover:text-neutral-950',
                  )}
                >
                  <span className="text-neutral-400 transition group-hover:text-primary-700 group-aria-[current=page]:text-primary-700">{item.icon}</span>
                  <span className="min-w-0 flex-1 font-semibold">{item.label}</span>
                  <ChevronRight className="h-4 w-4 shrink-0 text-neutral-300" />
                </NavLink>
              ))}
            </nav>
          </aside>

          <section className="min-w-0" aria-label={selected.label}>
            <Outlet />
          </section>
        </div>
      </div>
    </div>
  );
}
