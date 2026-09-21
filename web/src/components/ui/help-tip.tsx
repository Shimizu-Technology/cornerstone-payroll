import { useEffect, useId, useRef, useState, type ReactElement, type ReactNode } from 'react';
import { CircleHelp } from 'lucide-react';

import { cn } from '@/lib/utils';

interface HelpTipProps {
  label: string;
  children: ReactNode;
  className?: string;
}

export function HelpTip({ label, children, className }: HelpTipProps): ReactElement {
  const tooltipId = useId();
  const rootRef = useRef<HTMLSpanElement>(null);
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  const [pinned, setPinned] = useState(false);
  const open = hovered || focused || pinned;

  useEffect(() => {
    if (!open) return;

    const closeOnOutsidePointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setPinned(false);
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setPinned(false);
        setHovered(false);
        setFocused(false);
      }
    };

    if (pinned) document.addEventListener('pointerdown', closeOnOutsidePointer);
    document.addEventListener('keydown', closeOnEscape);
    return () => {
      if (pinned) document.removeEventListener('pointerdown', closeOnOutsidePointer);
      document.removeEventListener('keydown', closeOnEscape);
    };
  }, [open, pinned]);

  return (
    <span
      ref={rootRef}
      className={cn('relative inline-flex align-middle', className)}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onFocus={() => setFocused(true)}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setFocused(false);
      }}
    >
      <button
        type="button"
        aria-label={`About ${label}`}
        aria-expanded={open}
        aria-describedby={open ? tooltipId : undefined}
        onClick={(event) => {
          if (pinned) {
            setPinned(false);
            setHovered(false);
            setFocused(false);
            event.currentTarget.blur();
          } else {
            setPinned(true);
          }
        }}
        onKeyDown={(event) => {
          if (event.key === 'Escape') {
            setPinned(false);
            setHovered(false);
            setFocused(false);
            event.currentTarget.blur();
          }
        }}
        className="inline-flex h-6 w-6 items-center justify-center rounded-full text-neutral-400 transition-colors hover:bg-neutral-100 hover:text-primary-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2"
      >
        <CircleHelp aria-hidden="true" className="h-4 w-4" />
      </button>
      {open && (
        <span
          id={tooltipId}
          role="tooltip"
          className="absolute bottom-full left-1/2 z-50 mb-2 w-72 max-w-[calc(100vw-2rem)] -translate-x-1/2 rounded-xl bg-neutral-950 px-4 py-2 text-left text-xs font-normal leading-5 text-white shadow-xl"
        >
          {children}
        </span>
      )}
    </span>
  );
}
