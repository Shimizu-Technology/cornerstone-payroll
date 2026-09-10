import { useCallback, useId, useLayoutEffect, useRef, useState } from 'react';
import { Braces, ChevronDown, Download, FileCheck2, FileSpreadsheet, FileText, Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';

export interface ReportDownloadFormat {
  key: string;
  label: string;
  description?: string;
  kind: 'pdf' | 'spreadsheet' | 'data' | 'filing';
  loading?: boolean;
  onSelect: () => void | Promise<void>;
}

interface ReportDownloadMenuProps {
  formats: ReportDownloadFormat[];
  disabled?: boolean;
  buttonLabel?: string;
  className?: string;
  ariaLabel?: string;
}

export function ReportDownloadMenu({
  formats,
  disabled = false,
  buttonLabel = 'Export',
  className,
  ariaLabel,
}: ReportDownloadMenuProps) {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);
  const initialFocus = useRef<'first' | 'last'>('first');
  const menuId = useId();
  const triggerId = useId();
  const busy = formats.some((format) => format.loading);

  const closeMenu = useCallback((restoreFocus = false) => {
    // Hide synchronously so a containing Dialog's Tab trap sees the closed menu.
    if (menuRef.current?.matches(':popover-open')) menuRef.current.hidePopover();
    setOpen(false);
    if (restoreFocus) triggerRef.current?.focus({ preventScroll: true });
  }, []);

  useLayoutEffect(() => {
    if (!open) return;
    if (disabled || busy || formats.length < 2) {
      closeMenu();
      return;
    }
    const menu = menuRef.current;
    const trigger = triggerRef.current;
    if (!menu || !trigger) return;

    // The top layer escapes Card stacking contexts and preview overflow, while
    // retaining DOM ancestry for modal inertness, focus traps, and accessible names.
    menu.showPopover();
    const positionMenu = () => {
      const viewport = window.visualViewport;
      const leftEdge = (viewport?.offsetLeft ?? 0) + 8;
      const topEdge = (viewport?.offsetTop ?? 0) + 8;
      const rightEdge = leftEdge + (viewport?.width ?? window.innerWidth) - 16;
      const bottomEdge = topEdge + (viewport?.height ?? window.innerHeight) - 16;
      const anchor = trigger.getBoundingClientRect();
      const width = Math.min(256, Math.max(0, rightEdge - leftEdge));
      menu.style.width = `${width}px`;
      menu.style.maxHeight = 'none';
      const height = menu.getBoundingClientRect().height;
      const below = Math.max(0, bottomEdge - anchor.bottom - 8);
      const above = Math.max(0, anchor.top - topEdge - 8);
      const placeAbove = below < height && above > below;
      const availableHeight = placeAbove ? above : below;
      menu.style.maxHeight = `${availableHeight}px`;
      menu.style.left = `${Math.max(leftEdge, Math.min(anchor.right - width, rightEdge - width))}px`;
      menu.style.top = `${Math.max(topEdge, Math.min(
        placeAbove ? anchor.top - 8 - Math.min(height, availableHeight) : anchor.bottom + 8,
        bottomEdge - Math.min(height, availableHeight),
      ))}px`;
    };
    positionMenu();

    const items = () => Array.from(menu.querySelectorAll<HTMLButtonElement>('[role="menuitem"]'));
    const focusItem = (index: number) => {
      const buttons = items();
      const item = buttons[(index + buttons.length) % buttons.length];
      item?.focus({ preventScroll: true });
      if (item) {
        const itemBounds = item.getBoundingClientRect();
        const menuBounds = menu.getBoundingClientRect();
        if (itemBounds.top < menuBounds.top) menu.scrollTop -= menuBounds.top - itemBounds.top;
        else if (itemBounds.bottom > menuBounds.bottom) menu.scrollTop += itemBounds.bottom - menuBounds.bottom;
      }
    };
    focusItem(initialFocus.current === 'last' ? formats.length - 1 : 0);

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!menu.contains(target) && !trigger.contains(target)) closeMenu();
    };
    const handleFocusIn = (event: FocusEvent) => {
      const target = event.target as Node;
      if (!menu.contains(target) && !trigger.contains(target)) closeMenu();
    };
    const handleKeyDown = (event: KeyboardEvent) => {
      if (!menu.contains(event.target as Node) && !trigger.contains(event.target as Node)) return;
      if (event.key === 'Escape') {
        event.preventDefault();
        // Run before Dialog's document capture listener: Escape closes this menu first.
        event.stopPropagation();
        closeMenu(true);
      } else if (event.key === 'Tab') {
        // Resume normal tab order at the trigger, including the parent Dialog's trap.
        closeMenu(true);
      } else if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
        event.preventDefault();
        event.stopPropagation();
        const current = items().indexOf(document.activeElement as HTMLButtonElement);
        focusItem(event.key === 'Home' ? 0 : event.key === 'End' ? items().length - 1
          : current + (event.key === 'ArrowDown' ? 1 : -1));
      }
    };
    const handleScroll = (event: Event) => {
      if (!menu.contains(event.target as Node)) positionMenu();
    };
    const observer = new ResizeObserver(positionMenu);
    observer.observe(trigger);
    observer.observe(menu);
    window.addEventListener('resize', positionMenu);
    window.addEventListener('scroll', handleScroll, true);
    window.visualViewport?.addEventListener('resize', positionMenu);
    window.visualViewport?.addEventListener('scroll', positionMenu);
    window.addEventListener('pointerdown', handlePointerDown, true);
    window.addEventListener('focusin', handleFocusIn);
    window.addEventListener('keydown', handleKeyDown, true);
    return () => {
      observer.disconnect();
      window.removeEventListener('resize', positionMenu);
      window.removeEventListener('scroll', handleScroll, true);
      window.visualViewport?.removeEventListener('resize', positionMenu);
      window.visualViewport?.removeEventListener('scroll', positionMenu);
      window.removeEventListener('pointerdown', handlePointerDown, true);
      window.removeEventListener('focusin', handleFocusIn);
      window.removeEventListener('keydown', handleKeyDown, true);
      if (menu.matches(':popover-open')) menu.hidePopover();
    };
  }, [open, disabled, busy, formats.length, closeMenu]);

  if (formats.length === 0) return null;

  const runFormat = async (format: ReportDownloadFormat) => {
    closeMenu(true);
    await format.onSelect();
  };

  if (formats.length === 1) {
    const format = formats[0];
    return (
      <Button
        type="button"
        variant="outline"
        size="sm"
        onClick={() => void runFormat(format)}
        disabled={disabled || busy}
        className={className}
        aria-label={ariaLabel || `${buttonLabel} ${format.label}`}
      >
        {format.loading ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : <Download className="mr-1.5 h-3.5 w-3.5" />}
        {buttonLabel}
      </Button>
    );
  }

  return (
    <div className={className}>
      <Button
        type="button"
        variant="outline"
        size="sm"
        ref={triggerRef}
        id={triggerId}
        onClick={() => {
          initialFocus.current = 'first';
          if (open) closeMenu();
          else setOpen(true);
        }}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            initialFocus.current = event.key === 'ArrowUp' ? 'last' : 'first';
            setOpen(true);
          }
        }}
        disabled={disabled || busy}
        aria-haspopup="menu"
        aria-controls={open ? menuId : undefined}
        aria-expanded={open}
        aria-label={ariaLabel || buttonLabel}
      >
        {busy ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : <Download className="mr-1.5 h-3.5 w-3.5" />}
        {buttonLabel}
        <ChevronDown className="ml-1 h-3.5 w-3.5" />
      </Button>

      {open && (
        <div
          ref={menuRef}
          id={menuId}
          role="menu"
          aria-labelledby={triggerId}
          popover="manual"
          className="fixed m-0 overflow-y-auto overscroll-contain rounded-xl border border-neutral-200 bg-white p-1.5 shadow-xl shadow-neutral-900/10"
          style={{ inset: 'auto' }}
        >
          {formats.map((format) => (
            <button
              key={format.key}
              type="button"
              role="menuitem"
              tabIndex={-1}
              onClick={() => void runFormat(format)}
              className="flex w-full items-start gap-3 rounded-lg px-3 py-2.5 text-left transition-colors hover:bg-primary-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300"
            >
              <span className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-neutral-100 text-neutral-600">
                {format.kind === 'spreadsheet' && <FileSpreadsheet className="h-4 w-4" />}
                {format.kind === 'pdf' && <FileText className="h-4 w-4" />}
                {format.kind === 'data' && <Braces className="h-4 w-4" />}
                {format.kind === 'filing' && <FileCheck2 className="h-4 w-4" />}
              </span>
              <span className="min-w-0">
                <span className="block text-sm font-semibold text-neutral-900">{format.label}</span>
                {format.description && <span className="mt-0.5 block text-xs leading-4 text-neutral-500">{format.description}</span>}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
