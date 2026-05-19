import { useEffect, useRef, useState } from 'react';
import { Outlet, useOutlet } from 'react-router-dom';
import { Menu, X } from 'lucide-react';
import { Sidebar } from './Sidebar';
import { CommandPalette } from './CommandPalette';
import { useCompany } from '@/contexts/CompanyContext';

const SIDEBAR_COLLAPSED_KEY = 'sidebar-collapsed';

function isEditableShortcutTarget(target: EventTarget | null) {
  if (!(target instanceof HTMLElement)) return false;
  const tagName = target.tagName.toLowerCase();
  return target.isContentEditable || tagName === 'input' || tagName === 'textarea' || tagName === 'select';
}

export function Layout() {
  const { activeCompany, activeCompanyId } = useCompany();
  const outlet = useOutlet();
  const [mobileNavOpen, setMobileNavOpen] = useState(false);
  const [commandPaletteOpen, setCommandPaletteOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(() => {
    try { return localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === 'true'; } catch { return false; }
  });
  const [displayedCompanyId, setDisplayedCompanyId] = useState(activeCompanyId);
  const [isSwitchingCompany, setIsSwitchingCompany] = useState(false);
  const isFirstCompanyRender = useRef(true);
  const displayedCompanyIdRef = useRef(activeCompanyId);

  const toggleCollapse = () => {
    setCollapsed((prev) => {
      const next = !prev;
      try { localStorage.setItem(SIDEBAR_COLLAPSED_KEY, String(next)); } catch { /* ignore */ }
      return next;
    });
  };

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setMobileNavOpen(false);
        setCommandPaletteOpen(false);
        return;
      }

      const usesCommandModifier = event.metaKey || event.ctrlKey;
      if (!usesCommandModifier || event.altKey || event.shiftKey || isEditableShortcutTarget(event.target)) return;

      const key = event.key.toLowerCase();
      if (key === 'b') {
        event.preventDefault();
        if (window.matchMedia('(min-width: 1024px)').matches) {
          toggleCollapse();
        } else {
          setMobileNavOpen((current) => !current);
        }
      }

      if (key === 'k') {
        event.preventDefault();
        setCommandPaletteOpen((current) => !current);
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  useEffect(() => {
    displayedCompanyIdRef.current = displayedCompanyId;
  }, [displayedCompanyId]);

  useEffect(() => {
    if (isFirstCompanyRender.current) {
      isFirstCompanyRender.current = false;
      displayedCompanyIdRef.current = activeCompanyId;
      return;
    }

    const currentDisplayedCompanyId = displayedCompanyIdRef.current;

    if (activeCompanyId == null || currentDisplayedCompanyId == null) {
      const resetTimer = window.setTimeout(() => {
        setDisplayedCompanyId(activeCompanyId);
        displayedCompanyIdRef.current = activeCompanyId;
        setIsSwitchingCompany(false);
      }, 0);

      return () => {
        window.clearTimeout(resetTimer);
      };
    }

    if (activeCompanyId === currentDisplayedCompanyId) {
      const settleTimer = window.setTimeout(() => {
        setIsSwitchingCompany(false);
      }, 0);

      return () => {
        window.clearTimeout(settleTimer);
      };
    }

    const startTimer = window.setTimeout(() => {
      setIsSwitchingCompany(true);
    }, 0);

    const swapTimer = window.setTimeout(() => {
      setDisplayedCompanyId(activeCompanyId);
      displayedCompanyIdRef.current = activeCompanyId;
    }, 140);

    const settleTimer = window.setTimeout(() => {
      setIsSwitchingCompany(false);
    }, 520);

    return () => {
      window.clearTimeout(startTimer);
      window.clearTimeout(swapTimer);
      window.clearTimeout(settleTimer);
    };
  }, [activeCompanyId]);

  return (
    <div className="flex h-screen bg-transparent text-neutral-950">
      <Sidebar className="hidden lg:flex" collapsed={collapsed} onToggleCollapse={toggleCollapse} />

      <div className="relative flex flex-1 flex-col overflow-hidden">
        <div className="sticky top-0 z-20 flex items-center justify-between border-b border-neutral-200/80 bg-white/90 px-4 py-3 backdrop-blur-sm lg:hidden">
          <button
            type="button"
            className="inline-flex items-center justify-center rounded-xl border border-neutral-300 bg-white p-2 text-neutral-700 shadow-sm transition hover:bg-neutral-50"
            onClick={() => setMobileNavOpen(true)}
            aria-label="Open navigation"
          >
            <Menu className="h-5 w-5" />
          </button>
          <p className="text-sm font-semibold tracking-tight text-neutral-900">Cornerstone Payroll</p>
          <div className="h-9 w-9" />
        </div>

        <main className="relative flex-1 overflow-y-auto bg-[linear-gradient(180deg,rgba(255,255,255,0.42),rgba(248,250,252,0.74))]" aria-live="polite">
          <div
            className={`min-h-full transition-opacity duration-200 ease-out ${
              isSwitchingCompany ? 'opacity-55' : 'opacity-100'
            }`}
          >
            <div key={displayedCompanyId ?? 'no-company'} className="min-h-full">
              {outlet ?? <Outlet />}
            </div>
          </div>

          <div
            className={`pointer-events-none absolute inset-0 z-10 transition-opacity duration-300 ${
              isSwitchingCompany ? 'opacity-100' : 'opacity-0'
            }`}
            aria-hidden={!isSwitchingCompany}
          >
            <div className="absolute inset-0 bg-white/38 backdrop-blur-[1.5px]" />
            <div className="absolute left-1/2 top-8 -translate-x-1/2">
              <div className="inline-flex items-center gap-3 rounded-full border border-white/80 bg-white/92 px-4 py-2 text-sm text-neutral-700 shadow-lg shadow-primary-100/40">
                <span className="h-2.5 w-2.5 animate-pulse rounded-full bg-primary-600" />
                <span>
                  Switching to <span className="font-semibold text-neutral-900">{activeCompany?.name ?? 'client'}</span>
                </span>
              </div>
            </div>
          </div>
        </main>
      </div>

      <CommandPalette open={commandPaletteOpen} onOpenChange={setCommandPaletteOpen} />

      {mobileNavOpen && (
        <div className="fixed inset-0 z-40 lg:hidden" role="dialog" aria-modal="true">
          <button
            type="button"
            className="absolute inset-0 bg-neutral-950/35"
            aria-label="Close navigation"
            onClick={() => setMobileNavOpen(false)}
          />
          <div className="absolute inset-y-0 left-0 flex w-[86vw] max-w-[320px]">
            <Sidebar className="w-full" onNavigate={() => setMobileNavOpen(false)} />
            <button
              type="button"
              className="ml-2 mt-3 inline-flex h-9 w-9 items-center justify-center rounded-full border border-white/30 bg-white/10 text-white backdrop-blur-sm"
              onClick={() => setMobileNavOpen(false)}
              aria-label="Close navigation"
            >
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
