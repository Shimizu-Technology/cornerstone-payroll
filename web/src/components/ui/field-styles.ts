import { cn } from '@/lib/utils';

/**
 * Shared sizing for single-line form controls (text inputs, date inputs, selects).
 *
 * Browsers size `<select>`, date and text inputs differently from padding alone, so
 * controls placed in one row ended up 40, 42 or 44px tall. A fixed height keeps every
 * control in a row the same height, and matches the medium Button (44px on phones,
 * 40px from the `sm` breakpoint) so a button beside an input lines up too.
 */
export const CONTROL_HEIGHT = 'h-11 sm:h-10';

const CONTROL_SURFACE =
  'block rounded-xl border bg-white px-3.5 py-2 text-base sm:text-sm text-neutral-900 shadow-sm transition-[border-color,background-color,color,box-shadow] duration-150 ease-out placeholder:text-neutral-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200 focus-visible:border-primary-400 disabled:cursor-not-allowed disabled:bg-neutral-50 disabled:text-neutral-500';

const EXPLICIT_HEIGHT = /(?:^|\s)(?:[a-z0-9-]+:)*h-/;
const BASE_WIDTH = /(?:^|\s)w-/;

/** True when the caller already chose a height (for example a compact table control). */
export function hasExplicitHeight(className?: string) {
  return EXPLICIT_HEIGHT.test(className ?? '');
}

/**
 * Classes for a single-line control. Pass `invalid` to use the error border.
 * A caller-supplied `h-*` class replaces the shared height, and an unprefixed `w-*` class
 * replaces the default full width, instead of competing with them.
 */
export function controlClassName(className?: string, { invalid = false }: { invalid?: boolean } = {}) {
  return cn(
    CONTROL_SURFACE,
    !BASE_WIDTH.test(className ?? '') && 'w-full',
    !hasExplicitHeight(className) && CONTROL_HEIGHT,
    invalid
      ? 'border-danger-300 focus-visible:border-danger-500 focus-visible:ring-danger-200'
      : 'border-neutral-300',
    className,
  );
}

/**
 * Label text above a control. Input and Select use it, so a hand-built field placed
 * in the same row should too; a larger label pushes its control below its neighbours.
 */
export const FIELD_LABEL = 'block text-xs font-medium text-neutral-600';
